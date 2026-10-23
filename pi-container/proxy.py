#!/usr/bin/env python3
"""Allowlist proxy: tunnels GitHub, MITMs openrouter.ai to add the key, refuses the rest."""
from __future__ import annotations

import asyncio
import ipaddress
import os
import socket
import ssl
import struct
import subprocess
import sys
import time

GITHUB = {
    "github.com",
    "api.github.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
    "raw.githubusercontent.com",
    "uploads.github.com",
}
MAX_BODY = 64 * 1024 * 1024
ENV_FILE = os.environ.get("PI_ENV_FILE", "")
CERT = os.environ.get("PI_PROXY_CERT", "/private/openrouter.pem")
KEY = os.environ.get("PI_PROXY_KEY", "/private/openrouter.key")
CA = os.environ.get("PI_PROXY_CA", "/certs/ca.pem")
ADDR = os.environ.get("PI_PROXY_ADDR_FILE", "/private/proxy.addr")


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except ValueError:
        return 0


PORT = env_int("PI_PROXY_PORT", 8888)
UPSTREAM_HOST = os.environ.get("PI_PROXY_OPENROUTER_HOST", "")
UPSTREAM_PORT = env_int("PI_PROXY_OPENROUTER_PORT", 443)
UPSTREAM_TLS = os.environ.get("PI_PROXY_OPENROUTER_TLS", "1") != "0"
LOCKED_CIDR = os.environ.get("PI_PROXY_LOCKED_CIDR", "172.30.240.0/24")


def safe(value: str, limit: int = 200) -> str:
    """Keep client-controlled log fields printable and short."""
    text = "".join(c if 32 <= ord(c) < 127 else "?" for c in value)
    return text[:limit]


def log(msg: str) -> None:
    print(time.strftime("%H:%M:%S"), msg, file=sys.stderr, flush=True)


def file_mode(path: str) -> int:
    return os.stat(path).st_mode & 0o777


def check_key(value: str) -> str:
    if not value or any(c in value for c in "\r\n\x00 "):
        raise RuntimeError("OPENROUTER_API_KEY is missing or not a single token")
    return value


def openrouter_key() -> str:
    if not ENV_FILE:
        raise RuntimeError("PI_ENV_FILE is not set")
    if file_mode(ENV_FILE) & 0o077:
        raise RuntimeError("env file is readable by group or other")
    value = ""
    with open(ENV_FILE, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, raw = line.split("=", 1)
            if name.strip() == "OPENROUTER_API_KEY":
                value = raw.strip()
    return check_key(value)


def allowed_github(host: str) -> bool:
    return host.lower().rstrip(".") in GITHUB


def allowed_openrouter(host: str) -> bool:
    host = host.lower().rstrip(".")
    return host == "openrouter.ai" or host.endswith(".openrouter.ai")


async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while chunk := await src.read(65536):
            dst.write(chunk)
            await dst.drain()
    except Exception:
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def read_headers(reader: asyncio.StreamReader) -> list[bytes]:
    lines: list[bytes] = []
    size = 0
    while True:
        line = await asyncio.wait_for(reader.readline(), 30)
        if line in (b"", b"\r\n", b"\n"):
            if not line and not lines:
                raise EOFError
            break
        size += len(line)
        if len(line) > 16384 or size > 65536:
            raise ValueError("headers too large")
        lines.append(line)
    return lines


async def read_body(reader: asyncio.StreamReader, headers: list[bytes]) -> bytes:
    length = None
    chunked = False
    for line in headers:
        name, _, value = line.decode("latin1").partition(":")
        if name.lower() == "content-length":
            length = int(value.strip())
        elif name.lower() == "transfer-encoding" and "chunked" in value.lower():
            chunked = True
    if length is not None:
        if length > MAX_BODY:
            raise ValueError("body too large")
        return await reader.readexactly(length)
    if not chunked:
        return b""
    body = b""
    while True:
        size_line = await reader.readline()
        size = int(size_line.split(b";", 1)[0], 16)
        if size == 0:
            await reader.readline()
            return body
        if len(body) + size > MAX_BODY:
            raise ValueError("body too large")
        body += await reader.readexactly(size)
        await reader.readline()


def header_map(headers: list[bytes]) -> list[tuple[str, str]]:
    pairs = []
    for line in headers:
        name, sep, value = line.decode("latin1").partition(":")
        if sep:
            pairs.append((name.strip(), value.strip()))
    return pairs


async def tunnel(client_r: asyncio.StreamReader, client_w: asyncio.StreamWriter, host: str) -> None:
    try:
        remote_r, remote_w = await asyncio.wait_for(asyncio.open_connection(host, 443), 20)
    except Exception as exc:
        log(f"github connect failed {safe(host)}: {safe(str(exc))}")
        client_w.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        await client_w.drain()
        return
    client_w.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    await client_w.drain()
    await asyncio.gather(pipe(client_r, remote_w), pipe(remote_r, client_w))


_server_ctx: ssl.SSLContext | None = None
_upstream_ctx: ssl.SSLContext | None = None


def server_context() -> ssl.SSLContext:
    global _server_ctx
    if _server_ctx is None:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(CERT, KEY)
        ctx.set_alpn_protocols(["http/1.1"])
        _server_ctx = ctx
    return _server_ctx


def upstream_context() -> ssl.SSLContext | None:
    global _upstream_ctx
    if not UPSTREAM_TLS:
        return None
    if _upstream_ctx is None:
        _upstream_ctx = ssl.create_default_context()
    return _upstream_ctx


async def forward_openrouter(host: str, method: str, target: str, headers: list[bytes], body: bytes, writer: asyncio.StreamWriter) -> None:
    key = openrouter_key()
    upstream = UPSTREAM_HOST or host
    pairs = [(n, v) for n, v in header_map(headers) if n.lower() not in {
        "authorization", "proxy-authorization", "proxy-connection", "connection",
        "transfer-encoding", "content-length", "host",
    }]
    host_header = upstream if UPSTREAM_PORT == 443 else f"{upstream}:{UPSTREAM_PORT}"
    pairs.append(("Host", host_header))
    pairs.append(("Authorization", "Bearer " + key))
    pairs.append(("Content-Length", str(len(body))))
    pairs.append(("Connection", "close"))
    request = (method + " " + target + " HTTP/1.1\r\n").encode()
    request += "".join(f"{n}: {v}\r\n" for n, v in pairs).encode() + b"\r\n" + body
    remote_r, remote_w = await asyncio.wait_for(
        asyncio.open_connection(upstream, UPSTREAM_PORT, ssl=upstream_context()), 20)
    try:
        remote_w.write(request)
        await remote_w.drain()
        while chunk := await asyncio.wait_for(remote_r.read(65536), 600):
            writer.write(chunk)
            await writer.drain()
    finally:
        remote_w.close()


async def mitm(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, host: str) -> None:
    writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    await writer.drain()
    await writer.start_tls(server_context())
    while True:
        try:
            head = await read_headers(reader)
        except (EOFError, asyncio.IncompleteReadError, ConnectionError):
            return
        parts = head[0].decode("latin1").split()
        if len(parts) < 2:
            return
        method, target = parts[0], parts[1]
        path = target.split("?", 1)[0]
        if ".." in path or not path.startswith("/"):
            writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
            return
        body = await asyncio.wait_for(read_body(reader, head[1:]), 120)
        log(f"openrouter {safe(method, 20)} {safe(path)}")
        try:
            await forward_openrouter(host, method, target, head[1:], body, writer)
        except Exception as exc:
            log(f"openrouter failed {type(exc).__name__}")
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
        return


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        head = await read_headers(reader)
        parts = head[0].decode("latin1").split()
        if len(parts) < 2:
            return
        method, target = parts[0], parts[1]
        if method == "CONNECT":
            host, _, port = target.partition(":")
            if port != "443" or not host or any(c in host for c in " /\\"):
                raise PermissionError(target)
            if allowed_github(host):
                log(f"allow {safe(host)}")
                await tunnel(reader, writer, host)
                return
            if allowed_openrouter(host):
                await mitm(reader, writer, host.lower().rstrip("."))
                return
            raise PermissionError(host)
        if method == "GET" and target.split("?", 1)[0] == "/health":
            body = b"pi-container-proxy\n"
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(body), body))
            await writer.drain()
            return
        raise PermissionError(target)
    except PermissionError as exc:
        log(f"deny {safe(str(exc))}")
        writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        await writer.drain()
    except EOFError:
        pass
    except Exception as exc:
        log(f"error {type(exc).__name__}")
        try:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
        except Exception:
            pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


def openssl(args: list[str]) -> None:
    # Key generation writes progress to stderr; hide it.
    subprocess.run(args, check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def openssl_ok(args: list[str]) -> bool:
    try:
        return subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


def certs_ok() -> bool:
    if not (os.path.isfile(CERT) and os.path.isfile(KEY) and os.path.isfile(CA)):
        return False
    # Warn before expiry.
    for path in (CA, CERT):
        if not openssl_ok(["openssl", "x509", "-checkend", "2592000", "-noout", "-in", path]):
            return False
    if not openssl_ok(["openssl", "verify", "-CAfile", CA, CERT]):
        return False
    try:
        server_context()
    except Exception:
        return False
    return True


def ensure_certs() -> None:
    global _server_ctx
    if certs_ok():
        return
    log("regenerating TLS certificates")
    _server_ctx = None
    os.makedirs(os.path.dirname(CERT), exist_ok=True)
    os.makedirs(os.path.dirname(CA), exist_ok=True)
    openssl(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
         "-keyout", os.path.join(os.path.dirname(CERT), "ca.key"), "-out", CA, "-subj", "/CN=pi-container proxy"])
    csr = os.path.join(os.path.dirname(CERT), "openrouter.csr")
    ext = os.path.join(os.path.dirname(CERT), "openrouter.ext")
    openssl(
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", KEY, "-out", csr, "-subj", "/CN=openrouter.ai"])
    with open(ext, "w", encoding="utf-8") as fh:
        fh.write("subjectAltName=DNS:openrouter.ai,DNS:*.openrouter.ai,DNS:*.api.openrouter.ai\n"
                 "basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n")
    openssl(
        ["openssl", "x509", "-req", "-in", csr, "-CA", CA,
         "-CAkey", os.path.join(os.path.dirname(CERT), "ca.key"),
         "-CAserial", os.path.join(os.path.dirname(CERT), "ca.srl"), "-CAcreateserial",
         "-out", CERT, "-days", "825", "-sha256", "-extfile", ext])
    os.chmod(CA, 0o644)
    for path in (KEY, CERT, os.path.join(os.path.dirname(CERT), "ca.key")):
        os.chmod(path, 0o600)
    os.remove(csr)
    os.remove(ext)
    if not certs_ok():
        raise RuntimeError("generated TLS certificates do not verify")


def iface_ipv4(name: str) -> str | None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        packed = struct.pack("256s", name.encode()[:15])
        return socket.inet_ntoa(fcntl_ioctl(sock, packed)[20:24])
    except OSError:
        return None
    finally:
        sock.close()


def fcntl_ioctl(sock: socket.socket, packed: bytes) -> bytes:
    import fcntl
    return fcntl.ioctl(sock.fileno(), 0x8915, packed)


def default_iface() -> str | None:
    try:
        lines = open("/proc/net/route", encoding="utf-8").read().splitlines()[1:]
    except OSError:
        return None
    for line in lines:
        iface, dest, *_rest = line.split()
        if dest == "00000000":
            return iface
    return None


def locked_network() -> ipaddress.IPv4Network | None:
    try:
        return ipaddress.ip_network(LOCKED_CIDR, strict=False)
    except ValueError:
        return None


def usable_locked_ip(ip: str | None, default_ip: str | None) -> bool:
    if not ip or ip in {"0.0.0.0", "255.255.255.255"} or ip == default_ip:
        return False
    network = locked_network()
    if network is not None:
        try:
            return ipaddress.ip_address(ip) in network
        except ValueError:
            return False
    return True


def locked_ip() -> str | None:
    """Pick the non-default interface; that is the only one Pi can reach."""
    default = default_iface()
    default_ip = iface_ipv4(default) if default else None
    forced = os.environ.get("PI_PROXY_BIND", "")
    if forced:
        return forced if usable_locked_ip(forced, default_ip) else None
    if not default:
        return None
    try:
        names = sorted(os.listdir("/sys/class/net"))
    except OSError:
        return None
    chosen = None
    for name in names:
        if name == "lo" or name == default:
            continue
        ip = iface_ipv4(name)
        if usable_locked_ip(ip, default_ip):
            chosen = ip
    return chosen


def clear_addr() -> None:
    try:
        os.remove(ADDR)
    except OSError:
        pass


def publish_addr(bind: str) -> None:
    """Publish the bound address for run.sh."""
    directory = os.path.dirname(ADDR)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = ADDR + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(bind + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, ADDR)


def main() -> None:
    if not 1 <= PORT <= 65535:
        raise SystemExit("proxy: PI_PROXY_PORT must be between 1 and 65535")
    clear_addr()
    try:
        openrouter_key()
        ensure_certs()
        server_context()
    except Exception as exc:
        raise SystemExit(f"proxy: {exc}") from exc
    bind = None
    for _ in range(50):
        bind = locked_ip()
        if bind:
            break
        time.sleep(0.1)
    if not bind:
        raise SystemExit(f"proxy: no address on the locked network (expected {LOCKED_CIDR})")

    async def serve() -> None:
        server = await asyncio.start_server(handle, bind, PORT)
        publish_addr(bind)
        log(f"listening {bind}:{PORT}")
        async with server:
            await server.serve_forever()

    asyncio.run(serve())


if __name__ == "__main__":
    main()
