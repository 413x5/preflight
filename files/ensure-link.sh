#!/usr/bin/env bash
# Re-create the package .secrets.toml symlink if `uv tool upgrade` removed it.
# Sourced by ~/.local/bin/pra and ~/.local/bin/pral.
__pra_ensure_secrets_link() {
  local tools_root pkg target
  target="${HOME}/.config/pr-agent/.secrets.toml"
  [ -e "$target" ] || return 0
  tools_root="$(uv tool dir 2>/dev/null)" || return 0
  [ -d "${tools_root}/pr-agent" ] || return 0
  pkg="$(find "${tools_root}/pr-agent/lib" -maxdepth 4 -type d -path '*/pr_agent/settings' 2>/dev/null | head -1)"
  [ -n "$pkg" ] || return 0
  if [ ! -e "${pkg}/.secrets.toml" ]; then
    ln -sf "$target" "${pkg}/.secrets.toml" && echo "pra: relinked secrets -> ${pkg}/.secrets.toml" >&2
  fi
}
__pra_ensure_secrets_link
