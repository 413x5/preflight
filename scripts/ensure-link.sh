#!/usr/bin/env bash
# Re-create the package .secrets.toml symlink if `uv tool upgrade` removed it. Sourced by the
# preflight helpers.
#
# ${HOME:-} rather than $HOME because those helpers run under `set -u`: an unset HOME must find no
# secrets file rather than abort the caller. PREFLIGHT_HOME names the same dir install.sh writes, so a
# throwaway-prefix install relinks its own secrets.
__preflight_ensure_secrets_link() {
  local tools_root pkg target
  target="${PREFLIGHT_HOME:-${HOME:-}/.config/preflight}/.secrets.toml"
  [ -e "$target" ] || return 0
  tools_root="$(uv tool dir 2>/dev/null)" || return 0
  [ -d "${tools_root}/pr-agent" ] || return 0
  pkg="$(find "${tools_root}/pr-agent/lib" -maxdepth 4 -type d -path '*/pr_agent/settings' 2>/dev/null | head -1)"
  [ -n "$pkg" ] || return 0
  if [ ! -e "${pkg}/.secrets.toml" ]; then
    ln -sf "$target" "${pkg}/.secrets.toml" && echo "preflight: relinked secrets -> ${pkg}/.secrets.toml" >&2
  fi
}
__preflight_ensure_secrets_link
