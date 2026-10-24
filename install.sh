#!/usr/bin/env bash
# install.sh - deploy the preflight PR-Agent review setup on this machine.
#
#   ./install.sh                              # install/refresh everything
#   PREFLIGHT_PY=3.12 ./install.sh            # a different interpreter pin
#   PREFLIGHT_SKIP_TOOL_INSTALL=1 ./install.sh   # skip `uv tool install` (assume pr-agent present)
#
# Nothing about a model or an endpoint is set here, and nothing is guessed: install.sh installs the
# reference files config/*.toml.example into $PREFLIGHT_HOME, and you create settings.toml and
# providers.toml from them. A variable that seeded a value would be a second, invisible place to configure
# the review - and every such value has to be found and corrected by hand.
#
# These configure the INSTALL itself:
#
#   PREFLIGHT_PR_AGENT_VERSION   the pr-agent version to install (default: the pin below)
#   PREFLIGHT_PY                 the interpreter to pin
#   PREFLIGHT_HOME               the config dir
#   PREFLIGHT_BIN_DIR            where the helpers go
#   PREFLIGHT_SKIP_TOOL_INSTALL  skip `uv tool install`
#
# Idempotent: never overwrites an existing settings.toml or providers.toml.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/src"
config="$here/config"
scripts="$here/scripts"
cfg="${PREFLIGHT_HOME:-$HOME/.config/preflight}"
bindir="${PREFLIGHT_BIN_DIR:-$HOME/.local/bin}"
py="${PREFLIGHT_PY:-3.13}"
# Pinned, because `preflight-code` reads pr-agent's own output structure: the coverage marker matches the
# exact wording of pr-agent's "files were not included" footer, so an unpinned upgrade can stop
# coverage=PARTIAL from printing - a silently partial review, the failure this bundle exists to prevent.
# Override to test a new release; the gate asserts this pin (scripts/verify, the `install` stage).
pr_agent_version="${PREFLIGHT_PR_AGENT_VERSION:-0.48.0}"


say() { printf '%s\n' "$*" >&2; }

command -v git >/dev/null 2>&1 || { say "install: 'git' is required"; exit 1; }
# The renderer reads settings.toml and providers.toml with `tomllib`, which entered the standard library in
# 3.11 - and it refuses every command without it. Checking here makes that a failed INSTALL rather than an
# install that succeeds and then refuses every review. A warning, not a hard stop: the bundle's other
# helpers run on an older interpreter, so this only affects the model configuration.
if ! command -v python3 >/dev/null 2>&1; then
  say "!! python3 is not on PATH - 'preflight-code review' needs it (3.11+) to read settings.toml"
elif ! python3 -c 'import tomllib' >/dev/null 2>&1; then
  say "!! this python3 ($(python3 -V 2>&1 | cut -d' ' -f2)) has no tomllib - 'preflight-code review' needs 3.11+"
  # NOT PREFLIGHT_PY: that pins the interpreter uv installs pr-agent into, while the helper invokes
  # whatever `python3` is on PATH - so suggesting it here would send the user down a path that cannot work.
  say "   put a python3 3.11 or newer first on PATH (this is the interpreter 'preflight-code' runs, not PREFLIGHT_PY)"
fi

if [ "${PREFLIGHT_SKIP_TOOL_INSTALL:-0}" != "1" ]; then
  command -v uv >/dev/null 2>&1 || { say "install: 'uv' not found - install it first:"; say "  curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
  say "==> uv tool install --python $py pr-agent==$pr_agent_version"
  uv tool install --python "$py" "pr-agent==$pr_agent_version" >/dev/null
else
  say "==> skipping pr-agent install (PREFLIGHT_SKIP_TOOL_INSTALL=1)"
fi

mkdir -p "$cfg" "$bindir"

# The configuration is the USER'S, and install.sh does not create it: it knows no endpoint, no model id
# and no budget, so a file it wrote could only be a guess - and a guess is a value someone has to find and
# correct. What it installs instead is the reference pair, `<name>.toml.example`, to copy and edit.
#
# providers.toml is deliberately not created even empty: it holds the API key, and a file that exists with
# a placeholder endpoint would let a review run against a host the user never chose. The helper refuses a
# missing settings.toml and names both files, so the setup step is a refusal rather than a silent default.
install -m 0600 "$config/providers.toml.example" "$cfg/providers.toml.example"
install -m 0644 "$config/settings.toml.example"  "$cfg/settings.toml.example"
# A providers.toml that already exists is left untouched, but its mode is corrected: restored from a
# backup or copied from the template by hand is exactly when the credential is world-readable, and
# clobbering a file holding a real key is not an option.
# Group/other bits only: a file the operator made STRICTER (0400, a common choice for a key) must be left
# alone, and an exact 600 test would "tighten" it to something more permissive while saying so.
# python3 reads the mode, because `find -perm` is not portable: BSD find (macOS) rejects the GNU `/077`
# form outright, while the `+077` form it wants means something else to GNU find.
if [ -f "$cfg/providers.toml" ]; then
  # Three outcomes, not two: a mode that cannot be read is not "tight". A warning, since python3 is only
  # a warning above - but a silent skip would leave the key readable while this said nothing.
  _mode="$(python3 -c 'import os,sys
try: print(os.stat(sys.argv[1]).st_mode & 0o777)
except OSError: print("unreadable")' "$cfg/providers.toml" 2>/dev/null)" || _mode='unreadable'
  case "$_mode" in
    ''|unreadable)
      say "!! could not read the mode of $cfg/providers.toml - check it is 600 or stricter (it holds the key)" ;;
    *)
      # Group/other bits only, in the shell: an operator who made the file STRICTER (0400, a common choice
      # for a key) is left alone, and an exact 600 test would "tighten" it to something more permissive.
      # `10#` because the value is a decimal rendering of a mode (`644` -> `420`): a leading zero would be
      # read as octal, and `0384` is not a number in any base.
      if [ $(( 10#$_mode & 0077 )) -ne 0 ]; then
        say "!! $cfg/providers.toml is readable by other users - tightening it to 600 (it holds the API key)"
        chmod 600 "$cfg/providers.toml"
      fi ;;
  esac
fi

say "==> installing helpers into $bindir"
install -m 0755 "$src/preflight-pr"   "$bindir/preflight-pr"
install -m 0755 "$src/preflight-code" "$bindir/preflight-code"
install -m 0755 "$src/preflight-gate" "$bindir/preflight-gate"
install -m 0644 "$src/VERSION"        "$cfg/VERSION"
# The model-configuration resolver, sourced by both helpers. Installed unconditionally, unlike the
# templates above: a helper that is missing while settings.toml assigns a model is a refused review, so an
# upgraded install must carry both together.
install -m 0644 "$scripts/settings-render.sh" "$cfg/settings-render.sh"
# The gate's policy is a [gate] table in the settings.toml reference above, not a file of its own: one file
# for everything preflight can be told, and the renderer strips the table before pr-agent sees it. The old
# install created an INERT `gate.toml` (every key commented out), so that one is removed here. A file that
# SETS keys is not: deleting it would throw away a policy the operator wrote, so it is left for the gate to
# report by name until the keys are moved into [gate].
if [ -f "$cfg/gate.toml" ]; then
  # THREE outcomes, not two: 0 = parsed and empty (retire it), 1 = parsed and sets keys (leave it, report
  # it), 2 = could not parse it (no tomllib, or malformed) - which must not read as "it holds a policy",
  # or a machine whose interpreter is older than 3.11 is told to migrate keys the file does not have.
  _retire_rc=0
  python3 - "$cfg/gate.toml" <<'PY' >/dev/null 2>&1 || _retire_rc=$?
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(2)
try:
    with open(sys.argv[1], "rb") as fh:
        empty = tomllib.load(fh) == {}
except Exception:
    sys.exit(2)
sys.exit(0 if empty else 1)
PY
  case "$_retire_rc" in
    0)
      rm -f "$cfg/gate.toml"
      say "==> removed the retired $cfg/gate.toml (it set nothing; gate keys now live under [gate] in settings.toml)" ;;
    1)
      say "!! $cfg/gate.toml is no longer read - move its keys into a [gate] table in settings.toml, then delete it" ;;
    *)
      # The file is not read either way; what matters is not claiming to know what is in it. Left in
      # place, like the keyed case, because deleting a file that could hold a policy loses it.
      say "!! $cfg/gate.toml is no longer read, and this python3 cannot parse it to tell whether it sets keys; move any keys to [gate] in settings.toml, then delete it" ;;
  esac
fi
# preflight-hook is what a repo's committed .githooks/pre-commit calls (via $PREFLIGHT_HOOK or
# ~/.config/preflight/preflight-hook), so it lives with the config rather than on PATH.
install -m 0755 "$src/preflight-hook" "$cfg/preflight-hook"
if [ -d "$src/githooks" ]; then
  mkdir -p "$cfg/githooks"
  install -m 0755 "$src/githooks/pre-commit"  "$cfg/githooks/pre-commit"
  install -m 0755 "$src/githooks/post-commit" "$cfg/githooks/post-commit"
fi
if [ -f "$here/AGENTS-review-snippet.md" ]; then
  install -m 0644 "$here/AGENTS-review-snippet.md" "$cfg/AGENTS-review-snippet.md"
fi

# The old names are gone; warn if a previous install left them behind (uninstall.sh removes them).
for stale in pra pral pral-gate; do
  if [ -e "$bindir/$stale" ]; then
    say "!! stale helper from the old name found: $bindir/$stale (remove it; the commands are 'preflight-code', 'preflight-gate' and 'preflight-pr')"
  fi
done
# `preflight` was this bundle's command until it was renamed, and that name is also used by an unrelated
# project (a Rust secret-inspection proxy). Only OUR old helper is reported as stale; anything else at
# that path is left alone and named, because deleting another project's executable would be worse than
# the collision the rename exists to avoid. Ours is a shell script whose second line describes this bundle.
if [ -e "$bindir/preflight" ]; then
  if [ -f "$bindir/preflight" ] && [ ! -L "$bindir/preflight" ] \
     && head -n1 "$bindir/preflight" 2>/dev/null | grep -q '^#!' \
     && grep -q 'local PR-style review of the pending change' "$bindir/preflight" 2>/dev/null; then
    say "!! stale helper from the old name found: $bindir/preflight (remove that one file; the command is now 'preflight-code')"
  else
    say "!! $bindir/preflight belongs to another project, not this bundle; left untouched"
  fi
fi
if [ -d "$HOME/.config/pr-agent" ]; then
  say "!! old config dir $HOME/.config/pr-agent still exists - migrate its key by hand, then remove it"
fi
# The pre-0.6 config lived in the SAME directory under these two names, so the directory check above does
# not fire for it: the endpoint, model and key stay in files nothing reads any more, and the run just
# refuses. Named individually because each needs a different line moved into the new files.
if [ -f "$cfg/preflight.toml" ]; then
  say "!! $cfg/preflight.toml is the old single-file config and is no longer read - move its endpoint, model id and token budget into providers.toml, then delete it"
fi
if [ -e "$cfg/.secrets.toml" ]; then
  say "!! $cfg/.secrets.toml is the old credentials file and is no longer read - move its key into the provider entry in providers.toml, then delete it"
fi
case ":$PATH:" in *":$bindir:"*) : ;; *) say "!! $bindir is not on your PATH - add it, e.g. export PATH=\"\$PATH:$bindir\"" ;; esac

say ""
say "Done. Installed bundle version: $(head -n1 "$src/VERSION" 2>/dev/null || printf 'unknown')"
# The setup step is stated for a NEW install only. Telling a configured user to repeat it trains them to
# ignore the line - which is the line they need to read on a genuinely new machine. Both files are tested
# because the block below tells the reader to create both: someone who copied only settings.toml is not
# configured, and skipping the reminder would send them straight to a review that refuses to render.
if [ ! -f "$cfg/settings.toml" ] || [ ! -f "$cfg/providers.toml" ]; then
  say "NEXT: create the config file(s) below from the examples this install wrote, then edit them:"
  # Each copy is offered only while its target is ABSENT. A half-configured dir is a real state (the key
  # is typed before the profile name is), and copying the empty-key template over a keyed providers.toml
  # would destroy the credential - the same rule the resolver's own refusals follow.
  [ -f "$cfg/settings.toml" ] \
    || say "        cp \"$cfg/settings.toml.example\"  \"$cfg/settings.toml\""
  [ -f "$cfg/providers.toml" ] \
    || say "        ( umask 077; cp \"$cfg/providers.toml.example\" \"$cfg/providers.toml\" )   # 600: it holds the key"
  say "      In providers.toml set the endpoint, the API key and the model id; copy its table name into"
  say "      [selection] main in settings.toml. Nothing runs until both files exist."
fi
say "TRY:  cd <repo> && preflight-code review"
say ""
say "To make a repo REFUSE a commit that was not reviewed, commit the hooks and point git at them:"
say "  mkdir -p .githooks && install -m 0755 $cfg/githooks/* .githooks/ && git add .githooks"
say "  git update-index --chmod=+x .githooks/pre-commit .githooks/post-commit   # git IGNORES a non-executable hook"
say "  git config core.hooksPath .githooks      # relative, so it also works in every worktree"
say "See 'Make it enforced' in AGENTS-review-snippet.md."
