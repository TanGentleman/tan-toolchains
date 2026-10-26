FROM node:24-bookworm-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205
ARG PI_VERSION=1.4.0
ARG ZIG_VERSION=0.17.0
ARG ZIG_PUBKEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG NVIM_VERSION=0.12.6
ARG NVIM_SHA256=8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815
ARG ZLS_VERSION=0.17.0
ARG ZLS_SHA256=0d314f3cab30da770328e1b8c84ab89bb308e56dbc26a85ac82429ff02b44873

LABEL pi-container.pi-version="${PI_VERSION}" \
      pi-container.zig-version="${ZIG_VERSION}" \
      pi-container.zls-version="${ZLS_VERSION}" \
      pi-container.nvim-version="${NVIM_VERSION}"

# Apple container currently exposes image config Env, but not image labels.
ENV PI_CONTAINER_PI_VERSION="${PI_VERSION}"

RUN [ "$(uname -m)" = aarch64 ] || (echo "this image currently pins aarch64 only" >&2; exit 1)

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl fd-find findutils git jq minisign ripgrep unzip xz-utils \
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

RUN name="nvim-linux-arm64" && cd /tmp \
    && curl -fsSLO "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/${name}.tar.gz" \
    && printf '%s  %s\n' "${NVIM_SHA256}" "${name}.tar.gz" | sha256sum -c - \
    && tar -xzf "${name}.tar.gz" -C /opt \
    && rm "${name}.tar.gz" \
    && ln -s "/opt/${name}/bin/nvim" /usr/local/bin/nvim

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

# Version drift fails the build; a mismatched Zig/ZLS pair mis-parses code silently.
RUN [ "$(zig version)" = "$ZIG_VERSION" ] \
    || (echo "zig version mismatch: expected ${ZIG_VERSION}, got $(zig version)" >&2; exit 1)
RUN [ "$(zls --version)" = "$ZLS_VERSION" ] \
    || (echo "zls version mismatch: expected ${ZLS_VERSION}, got $(zls --version)" >&2; exit 1)
RUN got="$(nvim --version | sed -n 's/^NVIM v//p')" \
    && [ "$got" = "$NVIM_VERSION" ] \
    || (echo "nvim version mismatch: expected ${NVIM_VERSION}, got ${got:-nothing}" >&2; exit 1)

# Prove the runtime and builtin Zig filetype work without plugins.
RUN nvim --headless -c 'lua assert(vim.log.levels.INFO ~= nil)' -c q
RUN printf 'const std = @import("std");\n' > /tmp/nvim-filetype.zig \
    && (nvim --headless /tmp/nvim-filetype.zig -c 'set ft?' -c q 2>&1 | grep -q 'filetype=zig') \
    && rm /tmp/nvim-filetype.zig \
    || (rm -f /tmp/nvim-filetype.zig; echo "nvim did not detect filetype=zig" >&2; exit 1)

# gh supplies GITHUB_TOKEN to git; rewrite SSH remotes to HTTPS so it applies.
RUN git config --system credential.https://github.com.helper '!gh auth git-credential' \
    && git config --system url.https://github.com/.insteadOf git@github.com: \
    && git config --system --add url.https://github.com/.insteadOf ssh://git@github.com/ \
    && git config --system safe.directory '*'

ENV PI_SKIP_VERSION_CHECK=1 GH_NO_UPDATE_NOTIFIER=1 GIT_TERMINAL_PROMPT=0
WORKDIR /workspace
CMD ["pi"]
