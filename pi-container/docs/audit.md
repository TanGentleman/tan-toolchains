# Binary audit workflow

Status: proposal. Not implemented. Scope: aarch64 Linux ELF only.

A workflow that answers two questions about one binary before it runs anywhere
credentials exist:

1. What is statically observable about the artifact?
2. What did it do when executed in a disposable VM with no real secrets, and
   what did it do that a declared expectation does not cover?

It produces two artifact folders and a mechanical verdict. It does not produce a
judgement of intent, and it never reports a binary as safe.

## Non-goals

- Windows PE, Mach-O, firmware, archives, or non-ELF formats.
- Execution of x86_64 or other non-native code (see [Rosetta](#apple-container-constraints)).
- Replacing source review when source is available.
- General malware-lab capability: no accept-and-log payload capture, no memory
  forensics, no signature scoring.
- A security boundary. The VM is the boundary; this workflow is an observer.

## Decisions

| decision | choice |
|---|---|
| architecture scope | aarch64 Linux ELF only |
| backend | `--backend` seam, `apple-container` is the only implementation |
| egress handling | deny-and-log; accept-and-log payload capture is future work |
| verdict enforcement | advisory, surfaced to the human; `enforcer` does not block |
| static engines | pinned in the image with checksums; large image acceptable |

## Trust boundary

The analysis logic must live in the image, not on the host, or report provenance
depends on unversioned host files.

| component | runs | responsibility |
|---|---|---|
| `audit.sh` | host | CLI, mount guard, backend dispatch, network setup, artifact collection |
| `audit/inside/*` baked at `/usr/local/lib/audit/` | in VM | tracing, canaries, profiling, report assembly |
| `audit` stage in `Dockerfile` → `pi-audit:local` | build | pinned tools, shares base digest and pins |

The backend seam takes an image reference, mounts, environment, network, and
argv, and returns an exit status plus an artifact directory. Report generation
sits above it, so another backend changes no schema.

## Artifact contract

```
artifacts/<sha256-of-audited-binary>/
  manifest.json   # sha256, arch, image digest, kernel, tool versions, profile sha256, timings
  static/report.json     + static/artifacts/
  behavior/report.json   + behavior/artifacts/
  verdict.json    # PASS | REVIEW | FAIL, findings[], unknowns[]
```

Both reports are bounded to roughly 64 KiB. Detail beyond the bound is retained
in `artifacts/` and referenced by sha256 and offset.

Rules for anything derived from the audited binary:

- strip ANSI sequences and control characters; cap string length
- place binary-derived text in a field marked as untrusted data, never in prose
- redact canary values before they reach the report

The last rule matters twice: canaries are modelled on real credential formats, so
an unredacted report is itself a fake-secret leak, and it trains the reader to
ignore them.

`PASS` means the run matched the declared profile. `unknowns[]` always names what
the profile did not cover.

## Static folder

Runs with no network and no execution of the target. It still runs in a
disposable VM, because analyzers parsing a hostile file are themselves an attack
surface.

Pinned contents: `binutils`, `elfutils`, `file`, `yara`, `capa` with pinned
`capa-rules`, `checksec.sh`, `rizin`, and a `std.elf` section reader so header
facts survive a missing binutils.

`capa` is preferred over a decompiler here: on a stripped aarch64 ELF it names
capabilities from rules, which is closer to the question being asked than
pseudocode. A decompiler is deferred; see [Open items](#open-items).

The report must be deterministic: the same binary produces an identical
`static/report.json`. A test asserts this by digesting two runs.

## Behavior folder

- Two runs by default: `sterile` (empty HOME) and `bait` (HOME seeded with canary
  `id_ed25519`, `.aws/credentials`, `.netrc`, `.git-credentials`, kubeconfig, and
  marker environment variables). A binary that behaves differently when
  credentials exist is the case this workflow exists for.
- `strace -f -e trace=file,network,process,execve -s 256`, plus `fanotify` on the
  bait tree as an independent witness. If only one mechanism observes an event,
  it is reported as single-source rather than confirmed.
- The target binary is bind-mounted read-only as a single file, hashed on the
  host before the run and inside the VM after mount.
- Environment is an explicit allowlist. `PI_*`, `GITHUB_TOKEN`, and
  `OPENROUTER_API_KEY` are never inherited.
- Runs repeat a configurable number of times to expose counters and gated
  payloads.

Profiles declare the expected surface, so the report is deviations rather than a
syscall wall:

```json
{
  "binary": "./enforcer",
  "runs": [
    {"cmd": ["on"], "env": {"PI_CODING_AGENT_DIR": "$TMP/agent"}},
    {"cmd": ["off"]},
    {"cmd": ["hook"], "stdin": "{\"prompt\":\"hello\"}"}
  ],
  "repeat": 100,
  "allow": {"paths_write": ["$PI_CODING_AGENT_DIR/**"], "net": "none", "exec": "none"}
}
```

## apple/container constraints

Verified against `apple/container` and `apple/containerization` sources and docs.

| constraint | evidence | consequence |
|---|---|---|
| One lightweight VM per container. | `README.md`; `docs/resource-usage.md` | "fresh VM" is structural. `--rm` leaves no state to clean. |
| Default capability set omits `CAP_SYS_PTRACE`. | `docs/runtime-configuration.md` | `strace` requires `--cap-add SYS_PTRACE`. |
| `--cap-add` / `--cap-drop` accept names or `ALL`. | `docs/runtime-configuration.md` | Full capability set is available without `--privileged`. |
| No `--privileged` flag. | `docs/command-reference.md` | Per-capability grants only. |
| Stock kernel: `BPF`, `BPF_SYSCALL`, `FANOTIFY`, `AUDIT`, `SECCOMP_FILTER`, `USER_NS`, `OVERLAY_FS` enabled; `FTRACE`, `KPROBES`, `UPROBE_EVENTS`, `BPF_JIT`, `DEBUG_INFO_BTF` not set. | `containerization/0.5.0/kernel/config-arm64` | `bpftrace` cannot run on the stock kernel. Fanotify and audit can. |
| `--kernel`, `--kernel-arg`, `--init-image` supported; docs name eBPF filters as an init-image use. | `docs/command-reference.md` | A custom kernel is the documented path to eBPF tracing. |
| `--virtualization` exposes nested KVM, M3 or newer, kernel support required. | `docs/runtime-configuration.md` | Future route to other architectures through a nested guest. |
| `--rosetta` runs amd64 containers. | `docs/command-reference.md`; `containerization/README.md` | Future route for x86_64 ELF. Translated code issues syscalls into the same kernel, unlike full-system emulation; unverified here. |
| `--mount ... readonly` and `-v host:container:ro`. | `docs/command-reference.md`; `docs/volumes.md` | Read-only single-file bind of the target. |
| `--internal` networks are host-only; no documented "no network" mode. | `pi-container/run.sh`; `docs/networking.md` | Airgap is an internal network whose only peer is the sinkhole. |
| Host-only network can reach the Mac, and the internet if the Mac forwards IP. | `pi-container/README.md` (Limits) | The sinkhole must be the only peer, and forwarding must be checked, not assumed. |
| `--masked-path` / `--read-only-path` are experimental. | `docs/command-reference.md` | Usable, but not load-bearing. |
| Container images are aarch64-only in this project. | `pi-container/README.md` | Matches the scope decision. |
| Guest-level seccomp policy for container processes is not documented. | absence in `apple/container` docs | Treat `ptrace` availability as unverified until milestone M0. |

## What this can and cannot assert

### Assertions with their support

| # | assertion | mechanism | confidence |
|---|---|---|---|
| A1 | Files created, modified, or deleted inside the VM, with paths. | filesystem snapshot diff | high |
| A2 | Child processes executed, with argv and cwd. | `strace` `%process` | high |
| A3 | Files opened for reading, including canary paths. | `strace` plus `fanotify` | high when both agree; single-source otherwise |
| A4 | Network destinations attempted: DNS names, IP and port. | sinkhole log | high for attempts |
| A5 | No writes outside the declared allow-list for the sampled runs. | A1 against profile | high, sampled |
| A6 | Format, architecture, linkage, hardening, embedded literals, capability indicators, linked-dependency advisories. | static folder | high |
| A7 | Deviation from declared expectations. | A1-A5 against profile | mechanical |

### What it cannot assert

| # | limit | why |
|---|---|---|
| C1 | That no data left the VM. | Deny-and-log proves attempts, not payloads. A blocked connection is not a harmless one. |
| C2 | That dormant behavior does not exist. | Behavior gated on input, environment, time, or invocation count is only covered as far as the profile samples it. |
| C3 | That no file was read. | A read can be consumed without an observable sink: encoded into an exit status, a hash, or timing. Canaries narrow this to the paths seeded. |
| C4 | Anything about kernel or hypervisor escape. | Out of scope. The VM is the boundary, not the detector. |
| C5 | That the binary is not evading analysis. | VM and tracer detection, deliberate delays, and environment checks are only partly mitigated. Fanotify survives tracer detection; nothing here survives VM detection. |
| C6 | Memory-only behavior, timing channels, CPU-feature-dependent paths. | No memory introspection in scope. |
| C7 | Behavior of formats or architectures outside scope. | Non-ELF, non-aarch64. A staged payload fetched over the network is denied rather than observed. |
| C8 | That the audited bytes are the bytes later executed. | Hash pinning plus a before/after check narrows the gap; it does not close it. |
| C9 | Maliciousness. | No verifier of intent. The output is observed behavior and declared-expectation deviations. |

Consequence worth stating plainly: a `PASS` on a hostile binary that detects the
audit environment is indistinguishable from a `PASS` on a benign one. The
workflow raises the cost of the cheap attacks and makes the expensive ones
visible; it does not settle the question.

## Milestones

| | deliverable | exit condition |
|---|---|---|
| M0 | spike | `strace true` works under `--cap-add SYS_PTRACE` in the built image; artifacts reach the host; the sinkhole logs a denied connection |
| M1 | static folder | deterministic `static/report.json` for `enforcer` |
| M2 | behavior, sterile | trace, filesystem diff, and network log for an `on`/`off`/`hook` profile |
| M3 | bait and verdict | canary read detected and redacted correctly |
| M4 | tests and docs | hermetic `jq` tests, `bash -n`, refusal cases, docs updated |

M0 is a gate rather than a formality: the design depends on `strace` because the
stock kernel has no `FTRACE`, so ptrace availability inside the VM decides
whether the behavior folder is viable as specified.

## Open items

- Accept-and-log sinkhole: capture request payloads instead of refusing them.
- Custom kernel with `FTRACE`/`KPROBES`/`BTF` for `bpftrace`, via `--kernel`.
- x86_64 via `--rosetta`, or nested KVM via `--virtualization`.
- Decompiler engine for static analysis where rules are insufficient.
- Retention policy for `artifacts/`, and whether reports belong in git.
- Whether `PASS` should later gate execution through `enforcer`.
