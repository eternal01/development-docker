#!/usr/bin/env bash
set -e

if [ "$(id -u)" -eq 0 ] && [ "${WORKSPACE_SSH_ENABLED:-true}" = "true" ] && [ -x /usr/sbin/sshd ]; then
    # /run is tmpfs in Debian — the sshd privsep directory baked into the
    # image layer is gone on every container start. Recreate it before launch,
    # and gate on sshd binary presence (the old check, `[ -d /run/sshd ]`,
    # was the root cause of "sshd down after every restart").
    mkdir -p /run/sshd /etc/ssh/host_keys
    for key_type in ed25519 ecdsa rsa; do
        key_file="/etc/ssh/host_keys/ssh_host_${key_type}_key"
        if [ ! -f "${key_file}" ]; then
            ssh-keygen -q -t "${key_type}" -f "${key_file}" -N ""
        fi
        ln -sf "${key_file}" "/etc/ssh/ssh_host_${key_type}_key"
    done

    mkdir -p "${WORKSPACE_HOME}/.ssh"
    chown -R "${WORKSPACE_USER}:${WORKSPACE_USER}" "${WORKSPACE_HOME}/.ssh"
    chmod 700 "${WORKSPACE_HOME}/.ssh"

    if [ -f "${WORKSPACE_HOME}/.ssh/authorized_keys" ]; then
        chown "${WORKSPACE_USER}:${WORKSPACE_USER}" "${WORKSPACE_HOME}/.ssh/authorized_keys"
        chmod 600 "${WORKSPACE_HOME}/.ssh/authorized_keys"
    fi

    # Host keys are generated at runtime and persisted separately from the image.
    /usr/sbin/sshd -E /proc/1/fd/2
elif [ "${WORKSPACE_SSH_ENABLED:-true}" = "true" ] && [ "$(id -u)" -ne 0 ] && [ -x /usr/sbin/sshd ]; then
    echo "[workspace-entrypoint] SSHD is enabled but the container is not running as root; set WORKSPACE_CONTAINER_USER=root" >&2
fi

if [ "$(id -u)" -eq 0 ]; then
    for volume_dir in \
        "${WORKSPACE_HOME}/.cache/mise" \
        "${WORKSPACE_HOME}/.config/mise" \
        "${WORKSPACE_HOME}/.config/gh" \
        "${WORKSPACE_HOME}/.local/state/shell" \
        "${WORKSPACE_HOME}/go/pkg/mod" \
        "${WORKSPACE_HOME}/.cargo/registry" \
        "${WORKSPACE_HOME}/.cargo/git" \
        "${WORKSPACE_HOME}/.composer" \
        "/home/linuxbrew/.cache/Homebrew"; do
        if [ -d "${volume_dir}" ]; then
            marker="${volume_dir}/.workspace-owner-fixed-$(id -u "${WORKSPACE_USER}")"
            if [ ! -e "${marker}" ]; then
                chown -R "${WORKSPACE_USER}:${WORKSPACE_USER}" "${volume_dir}"
                : > "${marker}"
                chown "${WORKSPACE_USER}:${WORKSPACE_USER}" "${marker}"
            fi
        fi
    done
fi

# Inform the user when a project has a mise configuration. Installation is
# explicit so entering a directory never downloads a toolchain unexpectedly.
if [ -f "${WORKSPACE_HOME}/.tool-versions" ] || [ -f "${WORKSPACE_HOME}/.mise.toml" ] || \
   [ -f "${WORKSPACE_PATH}/.mise.toml" ] || [ -f "${WORKSPACE_PATH}/mise.toml" ] || \
   [ -f "${WORKSPACE_PATH}/.tool-versions" ]; then
    echo "[workspace-entrypoint] mise configuration detected. Consider running 'mise install' inside the container."
fi

if [ "$(id -u)" -eq 0 ]; then
    exec gosu "${WORKSPACE_USER}" "$@"
fi

# This branch is used when an IDE or an explicit `docker compose exec -u
# developer` starts a process directly as the development user.
exec "$@"
