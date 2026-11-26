# Build targets are capability packs. The last stage is the default full image
# (Pi, gh, enforcer); `full-zig` (pack zig) adds Zig, zigpeek, Neovim and ZLS;
# `min` is Pi without enforcer or gh, so it skips the Zig build. `agent` and
# `agent-gh` are intermediate stages, not packs. images.sh maps pack names to
# targets and tags. Keep the common pins here.
ARG PI_VERSION=1.6.0
ARG ZIG_VERSION=0.17.0
ARG ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG NVIM_VERSION=0.12.6
ARG NVIM_SHA256=8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815
ARG ZLS_VERSION=0.17.0
ARG ZLS_SHA256=0d314f3cab30da770328e1b8c84ab89bb308e56dbc26a85ac82429ff02b44873

FROM node:24-bookworm-slim@sha256:dc26ae92c9fb15cf6b1d63e20f0944b2efe0f115b20e00be48fb23fceb061c54 AS base
ARG PI_VERSION

LABEL pi-container.pi-version="${PI_VERSION}"

RUN [ "$(uname -m)" = aarch64 ] || (echo "this image currently pins aarch64 only" >&2; exit 1)

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl fd-find findutils git iptables jq minisign ripgrep unzip xz-utils \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

ENV PI_SKIP_VERSION_CHECK=1 GH_NO_UPDATE_NOTIFIER=1 GIT_TERMINAL_PROMPT=0
WORKDIR /workspace

FROM base AS zig
ARG ZIG_VERSION
ARG ZIG_PUBKEY

RUN name="zig-$(uname -m)-linux-${ZIG_VERSION}" && cd /tmp \
    && curl -fsSLO "https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz" \
    && curl -fsSLO "https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz.minisig" \
    && minisign -Vm "${name}.tar.xz" -P "${ZIG_PUBKEY}" \
    && mkdir -p /opt/zig \
    && tar -xJf "${name}.tar.xz" -C /opt/zig --strip-components=1 \
    && rm "${name}".tar.xz* \
    && ln -s /opt/zig/zig /usr/local/bin/zig

# Cold `zig init` spends ~50s building compiler_rt and the build runner.
RUN tmp="$(mktemp -d)" \
    && cd "$tmp" \
    && zig init --minimal >/dev/null \
    && zig build >/dev/null \
    && cd / \
    && rm -rf "$tmp"

COPY zigpeek /tmp/zigpeek
RUN cd /tmp/zigpeek \
    && zig build test \
    && zig build --release=small \
    && install -m755 zig-out/bin/zigpeek /usr/local/bin/zigpeek \
    && cd / \
    && rm -rf /tmp/zigpeek
RUN HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
    zigpeek builtins get @intCast >/dev/null \
    && zigpeek get std.Io.Writer.print >/dev/null
COPY zigpeek/skills/zigpeek/SKILL.md /root/.agents/skills/zigpeek/SKILL.md

COPY enforcer /tmp/enforcer
RUN cd /tmp/enforcer \
    && zig build check \
    && zig build -Dtarget=aarch64-linux-musl --release=small \
    && install -m755 zig-out/bin/enforcer /usr/local/bin/enforcer \
    && cd / \
    && rm -rf /tmp/enforcer
RUN test "$(printf '{"prompt":"hello"}' | enforcer hook; echo $?)" = 0 \
    && test "$(printf '{"prompt":"ghp_abc"}' | enforcer hook 2>/dev/null; echo $?)" = 2 \
    && enforcer --help >/dev/null
# Exercise the extension write path in the image, including PI_CODING_AGENT_DIR.
RUN tmp=$(mktemp -d) \
    && mkdir -p "$tmp/agent" \
    && HOME="$tmp" PI_CODING_AGENT_DIR="$tmp/agent" enforcer on >/dev/null \
    && test -f "$tmp/agent/extensions/enforcer.ts" \
    && HOME="$tmp" PI_CODING_AGENT_DIR="$tmp/agent" enforcer off >/dev/null \
    && test ! -e "$tmp/agent/extensions/enforcer.ts" \
    && rm -rf "$tmp"
RUN [ "$(zig version)" = "$ZIG_VERSION" ] \
    || (echo "zig version mismatch: expected ${ZIG_VERSION}, got $(zig version)" >&2; exit 1)

FROM base AS nvim
ARG NVIM_VERSION
ARG NVIM_SHA256

RUN name="nvim-linux-arm64" && cd /tmp \
    && curl -fsSLO "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/${name}.tar.gz" \
    && printf '%s  %s\n' "${NVIM_SHA256}" "${name}.tar.gz" | sha256sum -c - \
    && tar -xzf "${name}.tar.gz" -C /opt \
    && rm "${name}.tar.gz" \
    && ln -s "/opt/${name}/bin/nvim" /usr/local/bin/nvim
RUN got="$(nvim --version | sed -n 's/^NVIM v//p')" \
    && [ "$got" = "$NVIM_VERSION" ] \
    || (echo "nvim version mismatch: expected ${NVIM_VERSION}, got ${got:-nothing}" >&2; exit 1)
RUN nvim --headless -c 'lua assert(vim.log.levels.INFO ~= nil)' -c q
RUN printf 'const std = @import("std");\n' > /tmp/nvim-filetype.zig \
    && (nvim --headless /tmp/nvim-filetype.zig -c 'set ft?' -c q 2>&1 | grep -q 'filetype=zig') \
    && rm /tmp/nvim-filetype.zig \
    || (rm -f /tmp/nvim-filetype.zig; echo "nvim did not detect filetype=zig" >&2; exit 1)

FROM base AS zls
ARG ZIG_VERSION
ARG ZLS_VERSION
ARG ZLS_SHA256

# A ZLS built for another Zig silently mis-parses the project, so keep the pins together.
RUN [ "${ZLS_VERSION}" = "${ZIG_VERSION}" ] \
    || (echo "ZLS_VERSION (${ZLS_VERSION}) must match ZIG_VERSION (${ZIG_VERSION})" >&2; exit 1)
RUN name="zls-$(uname -m)-linux" && cd /tmp \
    && curl -fsSLO "https://github.com/zigtools/zls/releases/download/${ZLS_VERSION}/${name}.tar.xz" \
    && printf '%s  %s\n' "${ZLS_SHA256}" "${name}.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zls \
    && tar -xJf "${name}.tar.xz" -C /opt/zls \
    && rm "${name}.tar.xz" \
    && ln -s /opt/zls/zls /usr/local/bin/zls
RUN [ "$(zls --version)" = "$ZLS_VERSION" ] \
    || (echo "zls version mismatch: expected ${ZLS_VERSION}, got $(zls --version)" >&2; exit 1)

# enforcer is built with Zig but runs without it, so every pack but min has
# it.
FROM base AS core
COPY --from=zig /usr/local/bin/enforcer /usr/local/bin/enforcer
ENV PI_CONTAINER_CAPABILITIES="enforcer,netlock"

FROM core AS tools
ARG ZIG_VERSION
LABEL pi-container.zig-version="${ZIG_VERSION}"
COPY --from=zig /opt/zig /opt/zig
COPY --from=zig /usr/local/bin/zigpeek /usr/local/bin/zigpeek
COPY --from=zig /root/.agents/skills/zigpeek /root/.agents/skills/zigpeek
RUN ln -s /opt/zig/zig /usr/local/bin/zig
ENV PI_CONTAINER_CAPABILITIES="zig,zigpeek,enforcer,netlock"
CMD ["bash"]

FROM core AS agent
ARG PI_VERSION
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"
ENV PI_CONTAINER_PI_VERSION="${PI_VERSION}" \
    PI_CONTAINER_CAPABILITIES="enforcer,netlock,pi"
CMD ["pi"]

# No enforcer, so nothing here waits for the zig stage. base has iptables, so
# the egress lock still works.
FROM base AS min
ARG PI_VERSION
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"
ENV PI_CONTAINER_PI_VERSION="${PI_VERSION}" \
    PI_CONTAINER_CAPABILITIES="netlock,pi"
CMD ["pi"]

FROM agent AS agent-gh
RUN apt-get update \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*
# gh supplies GITHUB_TOKEN to git; rewrite SSH remotes to HTTPS so it applies.
RUN git config --system credential.https://github.com.helper '!gh auth git-credential' \
    && git config --system url.https://github.com/.insteadOf git@github.com: \
    && git config --system --add url.https://github.com/.insteadOf ssh://git@github.com/ \
    && git config --system safe.directory '*'
ENV PI_CONTAINER_CAPABILITIES="enforcer,netlock,pi,gh"

FROM tools AS editor
ARG NVIM_VERSION
ARG ZLS_VERSION
LABEL pi-container.nvim-version="${NVIM_VERSION}" \
      pi-container.zls-version="${ZLS_VERSION}"
COPY --from=nvim /opt/nvim-linux-arm64 /opt/nvim-linux-arm64
COPY --from=zls /opt/zls /opt/zls
RUN ln -s /opt/nvim-linux-arm64/bin/nvim /usr/local/bin/nvim \
    && ln -s /opt/zls/zls /usr/local/bin/zls
ENV PI_CONTAINER_CAPABILITIES="zig,zigpeek,enforcer,netlock,nvim,zls"

# Opt-in: full plus the Zig toolchain, zigpeek and its Pi skill, Neovim and ZLS.
FROM agent-gh AS full-zig
ARG ZIG_VERSION
ARG NVIM_VERSION
ARG ZLS_VERSION
LABEL pi-container.zig-version="${ZIG_VERSION}" \
      pi-container.nvim-version="${NVIM_VERSION}" \
      pi-container.zls-version="${ZLS_VERSION}"
COPY --from=zig /opt/zig /opt/zig
COPY --from=zig /usr/local/bin/zigpeek /usr/local/bin/zigpeek
COPY --from=zig /root/.agents/skills/zigpeek /root/.agents/skills/zigpeek
COPY --from=nvim /opt/nvim-linux-arm64 /opt/nvim-linux-arm64
COPY --from=zls /opt/zls /opt/zls
RUN ln -s /opt/zig/zig /usr/local/bin/zig \
    && ln -s /opt/nvim-linux-arm64/bin/nvim /usr/local/bin/nvim \
    && ln -s /opt/zls/zls /usr/local/bin/zls
ENV PI_CONTAINER_CAPABILITIES="zig,zigpeek,enforcer,netlock,pi,gh,nvim,zls"
CMD ["pi"]

# The default image, last so a plain `container build` produces it.
FROM agent-gh AS full
CMD ["pi"]
