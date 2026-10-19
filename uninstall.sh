#!/usr/bin/env bash
# uninstall.sh - remove the preflight PR-Agent review setup from this machine.
#   ./uninstall.sh                            # helpers + config (keeps the uv tool)
#   PREFLIGHT_REMOVE_TOOL=1 ./uninstall.sh    # also `uv tool uninstall pr-agent`
#
# Also cleans up a pre-rename install (pra/pral/pral-gate + ~/.config/pr-agent, and the `preflight`
# command this bundle shipped before it was renamed), so the rename never leaves two installs behind.
# Set PREFLIGHT_KEEP_OLD_CONFIG=1 to migrate the old config by hand instead (it holds the API key you
# will want in providers.toml).
set -euo pipefail
cfg="${PREFLIGHT_HOME:-$HOME/.config/preflight}"
bindir="${PREFLIGHT_BIN_DIR:-$HOME/.local/bin}"
say() { printf '%s\n' "$*" >&2; }

rm -f "$bindir/preflight-code" "$bindir/preflight-pr" "$bindir/preflight-gate"
say "removed helpers from $bindir"
# `preflight` was this bundle's command before the rename, and an unrelated project uses the same name.
# Only OUR old helper is removed: a shell script that describes this bundle. Anything else at that path is
# left alone and named, because this is the one removal that could delete another project's executable.
if [ -e "$bindir/preflight" ]; then
  if [ -f "$bindir/preflight" ] && [ ! -L "$bindir/preflight" ] \
     && head -n1 "$bindir/preflight" 2>/dev/null | grep -q '^#!' \
     && grep -q 'local PR-style review of the pending change' "$bindir/preflight" 2>/dev/null; then
    rm -f "$bindir/preflight"
    say "removed the old-name helper $bindir/preflight"
  else
    say "kept $bindir/preflight: it belongs to another project, not this bundle"
  fi
fi
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
