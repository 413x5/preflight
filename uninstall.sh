#!/usr/bin/env bash
# uninstall.sh - remove the preflight PR-Agent review setup from this machine.
#   ./uninstall.sh                            # helpers + config (keeps the uv tool)
#   PREFLIGHT_REMOVE_TOOL=1 ./uninstall.sh    # also `uv tool uninstall pr-agent`
#
# Also cleans up a pre-rename install (pra/pral/pral-gate + ~/.config/pr-agent), so the rename
# never leaves two installs behind. Set PREFLIGHT_KEEP_OLD_CONFIG=1 to migrate the old config by
# hand instead (its .secrets.toml holds your API key).
set -euo pipefail
cfg="${PREFLIGHT_HOME:-$HOME/.config/preflight}"
bindir="${PREFLIGHT_BIN_DIR:-$HOME/.local/bin}"
say() { printf '%s\n' "$*" >&2; }

pkg="$(find "$(uv tool dir 2>/dev/null)/pr-agent/lib" -maxdepth 4 -type d -path '*/pr_agent/settings' 2>/dev/null | head -1 || true)"
if [ -n "${pkg:-}" ] && [ -L "$pkg/.secrets.toml" ]; then rm -f "$pkg/.secrets.toml"; say "removed $pkg/.secrets.toml"; fi

rm -f "$bindir/preflight" "$bindir/preflight-pr" "$bindir/preflight-gate"
say "removed helpers from $bindir"
rm -rf "$cfg"
say "removed $cfg"

# Pre-rename leftovers.
old_cfg="${HOME}/.config/pr-agent"
removed_old=''
for stale in pra pral pral-gate; do
  if [ -e "$bindir/$stale" ]; then rm -f "$bindir/$stale"; removed_old="$removed_old $stale"; fi
done
[ -n "$removed_old" ] && say "removed old-name helpers:$removed_old"
if [ -d "$old_cfg" ] && [ "$old_cfg" != "$cfg" ]; then
  if [ "${PREFLIGHT_KEEP_OLD_CONFIG:-0}" = "1" ]; then
    say "kept old config dir $old_cfg (PREFLIGHT_KEEP_OLD_CONFIG=1)"
  else
    rm -rf "$old_cfg"
    say "removed old config dir $old_cfg"
  fi
fi

if [ "${PREFLIGHT_REMOVE_TOOL:-0}" = "1" ]; then uv tool uninstall pr-agent && say "uninstalled pr-agent"; fi
say "Note: the artifact-dir lines added to repos' .git/info/exclude are left in place (harmless)."
