FROM node:24-bookworm-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205
ARG PI_VERSION=1.4.0
ARG ZIG_VERSION=0.17.0
ARG ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl fd-find git jq minisign ripgrep xz-utils \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"

RUN name="zig-$(uname -m)-linux-${ZIG_VERSION}" && cd /tmp \
    && curl -fsSLO "https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz" \
    && curl -fsSLO "https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz.minisig" \
    && minisign -Vm "${name}.tar.xz" -P "${ZIG_PUBKEY}" \
    && tar -xJf "${name}.tar.xz" -C /opt && rm "${name}".tar.xz* \
    && ln -s "/opt/${name}/zig" /usr/local/bin/zig

# Cold `zig init` spends ~50s building compiler_rt and the build runner.
# Warm the cache so the first Zig command in a fresh container is fast.
RUN tmp="$(mktemp -d)" \
    && cd "$tmp" \
    && zig init --minimal >/dev/null \
    && zig build >/dev/null \
    && cd / \
    && rm -rf "$tmp"

COPY zigpeek /tmp/zigpeek
# zigpeek is pure Zig and reads doc/langref.html + lib/std next to the Zig above,
# so build it here: it cannot drift from the compiler it documents, and it needs
# no network at runtime. The build reuses the warm global cache from above.
RUN cd /tmp/zigpeek \
    && zig build test \
    && zig build --release=small \
    && install -m755 zig-out/bin/zigpeek /usr/local/bin/zigpeek \
    && cd / \
    && rm -rf /tmp/zigpeek
# Smoke test against a dead proxy: builtins must come from /opt, not the network.
RUN HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
    zigpeek builtins get @intCast >/dev/null \
    && zigpeek get std.Io.Writer.print >/dev/null
COPY zigpeek/skills/zigpeek/SKILL.md /root/.agents/skills/zigpeek/SKILL.md

# gh supplies GITHUB_TOKEN to git; rewrite SSH remotes to HTTPS so it applies.
RUN git config --system credential.https://github.com.helper '!gh auth git-credential' \
    && git config --system url.https://github.com/.insteadOf git@github.com: \
    && git config --system --add url.https://github.com/.insteadOf ssh://git@github.com/ \
    && git config --system safe.directory '*'

ENV PI_SKIP_VERSION_CHECK=1 GH_NO_UPDATE_NOTIFIER=1 GIT_TERMINAL_PROMPT=0
WORKDIR /workspace
CMD ["pi"]
