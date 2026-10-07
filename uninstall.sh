#!/usr/bin/env bash
# uninstall.sh - remove the local PR-Agent review setup from this machine.
#   ./uninstall.sh                            # helpers + config (keeps the uv tool)
#   PRAGENT_REMOVE_TOOL=1 ./uninstall.sh      # also `uv tool uninstall pr-agent`
set -euo pipefail
cfg="${PRAGENT_HOME:-$HOME/.config/pr-agent}"
bindir="${PRAGENT_BIN_DIR:-$HOME/.local/bin}"
say() { printf '%s\n' "$*" >&2; }

pkg="$(find "$(uv tool dir 2>/dev/null)/pr-agent/lib" -maxdepth 4 -type d -path '*/pr_agent/settings' 2>/dev/null | head -1 || true)"
if [ -n "${pkg:-}" ] && [ -L "$pkg/.secrets.toml" ]; then rm -f "$pkg/.secrets.toml"; say "removed $pkg/.secrets.toml"; fi

rm -f "$bindir/pra" "$bindir/pral" "$bindir/pral-gate"
say "removed helpers from $bindir"
rm -rf "$cfg"
say "removed $cfg"

if [ "${PRAGENT_REMOVE_TOOL:-0}" = "1" ]; then uv tool uninstall pr-agent && say "uninstalled pr-agent"; fi
say "Note: the '.pr-agent/' lines added to repos' .git/info/exclude are left in place (harmless)."
