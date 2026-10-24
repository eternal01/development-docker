# Lightweight interactive configuration; no framework or network access at startup.

# Persistent history lives outside the image and survives container recreation.
HISTFILE="${HOME}/.local/state/shell/zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS
mkdir -p "${HISTFILE:h}" 2>/dev/null

# Native completion with cached initialization.
autoload -Uz compinit
compinit -i

# mise activation is available in interactive shells; non-interactive commands
# should use `mise exec -- ...` instead of relying on this file.
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi

# Homebrew shell environment, when installed.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# fzf key bindings and completion are optional and do not block shell startup.
if [[ -o interactive && -t 0 ]] && [ -r /home/linuxbrew/.linuxbrew/opt/fzf/shell/key-bindings.zsh ]; then
  source /home/linuxbrew/.linuxbrew/opt/fzf/shell/key-bindings.zsh
  source /home/linuxbrew/.linuxbrew/opt/fzf/shell/completion.zsh
fi

# Starship is an optional prompt; use a small native prompt when unavailable.
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
else
  PROMPT='%n@%m:%~%# '
fi

# Optional project detection on cd. Disabled by default; use init-project for
# explicit initialization, or set WORKSPACE_AUTO_DETECT=true for opt-in mode.
detect_stack_on_cd() {
  [ "${WORKSPACE_AUTO_DETECT:-false}" = "true" ] || return
  [ "${MISED_SKIP_DETECT:-0}" = "1" ] && return
  if [ -f .mise.toml ] || [ -f mise.toml ] || [ -f .tool-versions ]; then return; fi
  command -v detect-stack >/dev/null 2>&1 || return
  detect-stack . >/dev/null 2>&1
}
chpwd_functions+=(detect_stack_on_cd)

# Debian package is installed with the base shell tools.
if [ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi
