#!/usr/bin/env bash
# Re-create the package .secrets.toml symlink if `uv tool upgrade` removed it.
# Sourced by ~/.local/bin/preflight and ~/.local/bin/preflight-pr.
#
# ${HOME:-} rather than $HOME: this is sourced by helpers that run under `set -u`, so an unset HOME
# must simply find no secrets file (nothing to relink) instead of aborting the caller with
# "HOME: unbound variable". PREFLIGHT_HOME names the same directory install.sh writes to, so a
# throwaway-prefix install relinks its own secrets rather than the user's.
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
