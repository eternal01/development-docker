# syntax=docker/dockerfile:1.7
#--------------------------------------------------------------------------
# Development Workspace
#--------------------------------------------------------------------------
# 职责：提供 100% 通用的开发"壳"，不含任何语言运行时
# 语言运行时通过 mise 在构建时或启动时按需安装
#--------------------------------------------------------------------------

ARG BASE_IMAGE=debian:bookworm
FROM ${BASE_IMAGE}

# BuildKit provides TARGETARCH for the requested target platform.
ARG TARGETARCH

LABEL maintainer="muxk <361087696@qq.com>"
LABEL description="Development workspace with mise, homebrew, zsh"

ENV DEBIAN_FRONTEND=noninteractive

USER root

###########################################################################
# Build Arguments & Environment
###########################################################################

ARG TZ=UTC
ARG PUID=1000
ARG PGID=1000
ARG WORKSPACE_USER=developer
ARG WORKSPACE_HOME=/home/developer
ARG WORKSPACE_PATH=/workspace
ARG TARGETARCH

ARG WORKSPACE_INSTALL_DNSUTILS=false
ARG WORKSPACE_INSTALL_WORKSPACE_SSH=false
ARG WORKSPACE_INSTALL_BREW=true
ARG WORKSPACE_BREW_PACKAGES="gh jq yq ripgrep fzf tree tmux fd neovim starship"

# mise pre-installed languages at build time (e.g. "go@1.22.4 rust@stable php@8.3.6")
ARG WORKSPACE_PREINSTALL_LANGUAGES=""
# Pin mise to a specific release. Override through the Compose build arg.
ARG MISE_VERSION=v2026.6.1
ARG MISE_RELEASE_BASE_URL=https://github.com/jdx/mise/releases/download

# Docker BuildKit provides HTTP_PROXY/HTTPS_PROXY/NO_PROXY as predefined build
# args for RUN instructions. Do not redeclare or persist them as ENV: they may
# contain credentials. Compose separately injects proxy values at runtime.
ARG DEBIAN_MIRROR=deb.debian.org
ARG DEBIAN_SECURITY_MIRROR=security.debian.org

ENV TZ=${TZ}
ENV WORKSPACE_USER=${WORKSPACE_USER}
ENV WORKSPACE_HOME=${WORKSPACE_HOME}
ENV WORKSPACE_PATH=${WORKSPACE_PATH}
ENV HOME=${WORKSPACE_HOME}
# Pin $SHELL so any process reading it (mise, IDEs that fall
# back to the env var) sees /bin/zsh. Pairs with useradd -s /bin/zsh above
# and the host-side VSCode setting terminal.integrated.defaultProfile.linux.
ENV SHELL=/bin/zsh
# locale-gen above creates en_US.UTF-8; export it so Python / git / locale-
# aware tools don't fall back to POSIX (which breaks `print('中文')` and
# similar). LC_ALL is also exported so gettext-style tools pick the same
# locale without per-tool override.
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# mise paths (shims will be added to PATH by mise activate)
ENV MISE_DATA_DIR=${WORKSPACE_HOME}/.local/share/mise
ENV MISE_CONFIG_DIR=${WORKSPACE_HOME}/.config/mise
ENV MISE_CACHE_DIR=${WORKSPACE_HOME}/.cache/mise
# Keep mise shims available to non-interactive shells as well. Interactive
# zsh still evaluates `mise activate zsh` for project-aware environment setup.
ENV PATH=${MISE_DATA_DIR}/shims:/usr/local/bin:${PATH}
# Project detection is explicit by default. Set WORKSPACE_AUTO_DETECT=true to
# opt into generating .mise.toml on directory changes.
ENV MISE_AUTO_INSTALL=false
ENV WORKSPACE_AUTO_DETECT=false

# homebrew paths
ENV HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew
# Put the brew cache under the brew prefix instead of ${HOME}/.cache/Homebrew
# so the installer's non-sudo `mkdir -p ${HOMEBREW_CACHE}` always lands in a
# directory we own, regardless of /home/${WORKSPACE_USER} permissions.
ENV HOMEBREW_CACHE=/home/linuxbrew/.cache/Homebrew
ENV HOMEBREW_NO_ANALYTICS=1
ENV HOMEBREW_NO_AUTO_UPDATE=1
ENV HOMEBREW_NO_INSTALL_CLEANUP=1
# Keep brew usable from VS Code tasks, bash, and non-login shells too. The
# zshrc still runs `brew shellenv` for the remaining Homebrew environment.
ENV PATH=${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin:${MISE_DATA_DIR}/shims:/usr/local/bin:${PATH}

###########################################################################
# Base System Tools
###########################################################################

# Retry wrapper: apt-get returns exit code 100 when "Some files failed to
# download" — a transient network blip against Debian mirrors shouldn't fail
# the whole image build. Both package-list updates and package installs retry.
# Bootstrap over HTTP so ca-certificates can be installed before HTTPS
# verification is enabled. All subsequent apt traffic uses HTTPS.
RUN set -eux; \
    find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec \
      sed -i -E \
        -e "s#https?://deb.debian.org#http://${DEBIAN_MIRROR}#g" \
        -e "s#https?://security.debian.org#http://${DEBIAN_SECURITY_MIRROR}#g" \
      {} +; \
    apt_update() { \
      for attempt in 1 2 3; do \
        if apt-get update -o Acquire::Retries=5; then \
          return 0; \
        fi; \
        echo "apt update failed (attempt ${attempt}/3); clearing apt lists" >&2; \
        rm -rf /var/lib/apt/lists/*; \
        sleep 3; \
      done; \
      echo "apt update failed after 3 attempts" >&2; \
      return 1; \
    }; \
    apt_install() { \
      for attempt in 1 2 3; do \
        if apt-get install -y --no-install-recommends --fix-missing \
          -o Acquire::Retries=5 "$@"; then \
          return 0; \
        fi; \
        echo "apt install failed (attempt ${attempt}/3); refreshing package lists" >&2; \
        apt-get clean; \
        rm -rf /var/lib/apt/lists/*; \
        apt_update; \
      done; \
      echo "apt install failed after 3 attempts: $*" >&2; \
      return 1; \
    }; \
    rm -rf /var/lib/apt/lists/*; \
    apt_update; \
    apt_install ca-certificates; \
    find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec \
      sed -i \
        -e "s#http://${DEBIAN_MIRROR}#https://${DEBIAN_MIRROR}#g" \
        -e "s#http://${DEBIAN_SECURITY_MIRROR}#https://${DEBIAN_SECURITY_MIRROR}#g" \
      {} +; \
    rm -rf /var/lib/apt/lists/*; \
    apt_update; \
    apt_install \
      bash \
      binutils \
      bison \
      build-essential \
      bzip2 \
      curl \
      file \
      git \
      gosu \
      gnupg \
      less \
      locales \
      make \
      mercurial \
      openssl \
      patch \
      pkg-config \
      procps \
      rsync \
      screen \
      socat \
      sudo \
      tar \
      unzip \
      vim \
      wget \
      xz-utils \
      zip \
      zsh \
      zsh-syntax-highlighting; \
    if [ "${WORKSPACE_INSTALL_DNSUTILS}" = "true" ]; then \
      apt_install dnsutils iputils-ping net-tools; \
    fi; \
    if [ "${WORKSPACE_INSTALL_WORKSPACE_SSH}" = "true" ]; then \
      apt_install openssh-server; \
    fi; \
    ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo ${TZ} > /etc/timezone \
    && sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && groupadd -g ${PGID} ${WORKSPACE_USER} \
    && useradd -m -u ${PUID} -g ${PGID} -d ${WORKSPACE_HOME} -s /bin/zsh ${WORKSPACE_USER} \
    && echo "${WORKSPACE_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${WORKSPACE_USER} \
    && chmod 0440 /etc/sudoers.d/${WORKSPACE_USER}

###########################################################################
# mise - Universal Language Version Manager
###########################################################################

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) MISE_ARCH="x64" ;; \
      arm64) MISE_ARCH="arm64" ;; \
      *) echo "Unsupported TARGETARCH for mise: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    MISE_ASSET="mise-${MISE_VERSION}-linux-${MISE_ARCH}"; \
    MISE_URL="${MISE_RELEASE_BASE_URL}/${MISE_VERSION}/${MISE_ASSET}"; \
    MISE_CHECKSUMS_URL="${MISE_RELEASE_BASE_URL}/${MISE_VERSION}/SHASUMS256.txt"; \
    mkdir -p ${MISE_DATA_DIR} ${MISE_CONFIG_DIR} ${MISE_CACHE_DIR} ${WORKSPACE_PATH}; \
    echo "Downloading mise ${MISE_VERSION} for linux-${MISE_ARCH}"; \
    curl --fail --location --show-error --retry 5 --retry-all-errors --retry-delay 3 \
      "${MISE_CHECKSUMS_URL}" -o /tmp/mise-SHASUMS256.txt; \
    curl --fail --location --show-error --retry 5 --retry-all-errors --retry-delay 3 \
      "${MISE_URL}" -o "/tmp/${MISE_ASSET}"; \
    MISE_SHA256="$(awk -v asset="./${MISE_ASSET}" '$2 == asset {print $1; exit}' /tmp/mise-SHASUMS256.txt)"; \
    [ "${#MISE_SHA256}" -eq 64 ]; \
    echo "${MISE_SHA256}  /tmp/${MISE_ASSET}" | sha256sum --check --status; \
    mv "/tmp/${MISE_ASSET}" /usr/local/bin/mise; \
    rm -f /tmp/mise-SHASUMS256.txt; \
    chmod +x /usr/local/bin/mise; \
    /usr/local/bin/mise --version; \
    chown -R ${WORKSPACE_USER}:${WORKSPACE_USER} ${MISE_DATA_DIR} ${MISE_CONFIG_DIR} ${MISE_CACHE_DIR} ${WORKSPACE_PATH}

###########################################################################
# Pre-install languages via mise at build time (optional)
###########################################################################

RUN --mount=type=cache,target=${WORKSPACE_HOME}/.cache/mise,uid=${PUID},gid=${PGID} \
    if [ -n "${WORKSPACE_PREINSTALL_LANGUAGES}" ]; then \
    echo "[workspace] mise: installing and activating ${WORKSPACE_PREINSTALL_LANGUAGES} globally"; \
    gosu ${WORKSPACE_USER} mise use --global ${WORKSPACE_PREINSTALL_LANGUAGES}; \
    fi

###########################################################################
# homebrew
# The installer script URL below is pinned to an immutable upstream commit;
# update it deliberately when refreshing the workspace bootstrap.
###########################################################################

RUN --mount=type=cache,target=/home/linuxbrew/.cache/Homebrew,uid=${PUID},gid=${PGID} \
    if [ "${WORKSPACE_INSTALL_BREW}" = "true" ]; then \
    echo "[workspace] Homebrew: preparing directories"; \
    mkdir -p /home/linuxbrew ${HOMEBREW_CACHE} \
    && chown -R ${WORKSPACE_USER}:${WORKSPACE_USER} /home/linuxbrew \
    # Defensive: in some build environments (Docker Desktop on macOS in
    # particular) ${WORKSPACE_HOME} ends up not writable by
    # ${WORKSPACE_USER} after useradd -m, which then breaks any
    # `su - ${WORKSPACE_USER} -c '... ~/.cache/...'` operation. Force the
    # ownership and mode that useradd -m should have produced.
    && chown -R ${WORKSPACE_USER}:${WORKSPACE_USER} ${WORKSPACE_HOME} \
    && chmod 755 ${WORKSPACE_HOME} \
    && echo "[workspace] Homebrew: configuring Git for unstable proxy links" \
    && gosu ${WORKSPACE_USER} git config --global http.version HTTP/1.1 \
    && gosu ${WORKSPACE_USER} git config --global http.maxRequests 1 \
    && gosu ${WORKSPACE_USER} git config --global http.lowSpeedLimit 1 \
    && gosu ${WORKSPACE_USER} git config --global http.lowSpeedTime 600 \
    && echo "[workspace] Homebrew: downloading installer" \
    && gosu ${WORKSPACE_USER} /bin/bash -c 'set -e; curl --fail --location --show-error --retry 5 --retry-all-errors --retry-delay 3 https://raw.githubusercontent.com/Homebrew/install/09c62fc577ec170172b0a184060f141a2c622dc1/install.sh -o /tmp/homebrew-install.sh; for attempt in 1 2 3; do if NONINTERACTIVE=1 CI=1 /bin/bash /tmp/homebrew-install.sh; then rm -f /tmp/homebrew-install.sh; exit 0; fi; echo "Homebrew installer failed (attempt ${attempt}/3); retrying" >&2; sleep $((attempt * 5)); done; rm -f /tmp/homebrew-install.sh; exit 1' \
    && echo "[workspace] Homebrew: updating metadata" \
    && gosu ${WORKSPACE_USER} /bin/bash -c 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" && HOMEBREW_VERBOSE=1 brew update' \
    && if [ -n "${WORKSPACE_BREW_PACKAGES}" ]; then \
    echo "[workspace] Homebrew: installing ${WORKSPACE_BREW_PACKAGES}"; \
    gosu ${WORKSPACE_USER} /bin/bash -c "eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\" && HOMEBREW_VERBOSE=1 brew install --verbose ${WORKSPACE_BREW_PACKAGES}" \
    && echo "[workspace] Homebrew: packages installed"; \
    fi; \
    fi

###########################################################################
# Lightweight Zsh configuration (native completion, fzf, optional Starship)
###########################################################################

# Keep the default config self-contained. Optional UI tools degrade gracefully
# when Homebrew is disabled or a user overrides the package list.
COPY --chown=${WORKSPACE_USER}:${WORKSPACE_USER} --chmod=644 \
    workspaces/dotfiles/.zshrc ${WORKSPACE_HOME}/.zshrc

###########################################################################
# SSH (optional install handled by the apt block above; /run/sshd and
# ${WORKSPACE_HOME}/.ssh are recreated by docker-entrypoint.sh at runtime
# because /run is tmpfs in Debian and the build-time directory is gone on
# the first container start).
###########################################################################

###########################################################################
# Final Touch & Entrypoint
###########################################################################

COPY --chmod=755 workspaces/docker-entrypoint.sh        /usr/local/bin/workspace-entrypoint
COPY --chmod=755 workspaces/scripts/detect-stack.sh    /usr/local/bin/detect-stack
COPY --chmod=755 workspaces/scripts/init-project.sh    /usr/local/bin/init-project
COPY --chmod=644 workspaces/scripts/languages.defaults /usr/local/bin/languages.defaults
COPY --chmod=644 workspaces/scripts/stack-detection.lib.sh /usr/local/bin/stack-detection.lib.sh

RUN apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && rm -f /var/log/lastlog /var/log/faillog

WORKDIR ${WORKSPACE_PATH}

ENTRYPOINT ["workspace-entrypoint"]
CMD ["sleep", "infinity"]
