#!/usr/bin/env bash
# install.sh - deploy the preflight PR-Agent review setup on this machine.
#
#   ./install.sh                              # install/refresh everything (ClinePass defaults)
#   PREFLIGHT_KEY=sk-... ./install.sh         # also write the API key now
#   PREFLIGHT_API_BASE=https://... ./install.sh  # a different OpenAI-compatible endpoint
#   PREFLIGHT_PY=3.12 ./install.sh            # a different interpreter pin
#   PREFLIGHT_SKIP_TOOL_INSTALL=1 ./install.sh   # skip `uv tool install` (assume pr-agent present)
#
# The endpoint is not tied to ClinePass. Any OpenAI-compatible endpoint works; these are applied
# only when set, and override the defaults written into the config:
#
#   PREFLIGHT_PR_AGENT_VERSION          the pr-agent version to install (default: the pin below)
#   PREFLIGHT_MODEL                     the primary model id
#   PREFLIGHT_FALLBACK_MODELS           comma-separated fallback ids ("" or "none" -> [])
#   PREFLIGHT_CUSTOM_MODEL_MAX_TOKENS   context window for a model LiteLLM doesn't know (0 = look it up)
#   PREFLIGHT_MAX_MODEL_TOKENS          packing clamp (0 = no clamp)
#   PREFLIGHT_FORCE_STREAMING_HOST      host whose api_base needs the ClinePass streaming workaround
#
# Idempotent: never overwrites an existing .secrets.toml.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
files="$here/files"
cfg="${PREFLIGHT_HOME:-$HOME/.config/preflight}"
bindir="${PREFLIGHT_BIN_DIR:-$HOME/.local/bin}"
py="${PREFLIGHT_PY:-3.13}"
# Pinned, because `preflight` reads pr-agent's own output structure: the coverage marker matches the
# exact wording of pr-agent's "files were not included" footer, so an unpinned upgrade can stop
# coverage=PARTIAL from printing - a silently partial review, the failure this bundle exists to prevent.
# Override to test a new release; CI asserts this pin (see .github/workflows/ci.yml).
pr_agent_version="${PREFLIGHT_PR_AGENT_VERSION:-0.47.0}"
api_base="${PREFLIGHT_API_BASE:-https://api.cline.bot/api/v1}"
key="${PREFLIGHT_KEY:-}"

# Provider overrides (empty = keep the value baked into files/preflight.toml).
model="${PREFLIGHT_MODEL:-}"
fallbacks="${PREFLIGHT_FALLBACK_MODELS:-}"
custom_max="${PREFLIGHT_CUSTOM_MODEL_MAX_TOKENS:-}"
max_tokens="${PREFLIGHT_MAX_MODEL_TOKENS:-}"
# The streaming workaround is ClinePass-specific, so it defaults to the ClinePass literal and stays
# inert for any other endpoint. Point it at a proxy host if that is how you reach ClinePass.
force_host="${PREFLIGHT_FORCE_STREAMING_HOST:-api.cline.bot}"

say() { printf '%s\n' "$*" >&2; }

command -v git >/dev/null 2>&1 || { say "install: 'git' is required"; exit 1; }

if [ "${PREFLIGHT_SKIP_TOOL_INSTALL:-0}" != "1" ]; then
  command -v uv >/dev/null 2>&1 || { say "install: 'uv' not found - install it first:"; say "  curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
  say "==> uv tool install --python $py pr-agent==$pr_agent_version"
  uv tool install --python "$py" "pr-agent==$pr_agent_version" >/dev/null
else
  say "==> skipping pr-agent install (PREFLIGHT_SKIP_TOOL_INSTALL=1)"
fi

mkdir -p "$cfg" "$bindir"

say "==> writing $cfg/preflight.toml (endpoint: $api_base)"
cp "$files/preflight.toml" "$cfg/preflight.toml"

# Apply provider overrides, if any, to the values just written. Anchored on our own known keys so
# `max_model_tokens` can never match inside `custom_model_max_tokens`.
if [ -n "$model" ]; then
  sed -i.bak "s#^model = .*#model = \"$model\"#" "$cfg/preflight.toml"
fi
if [ -n "$fallbacks" ]; then
  case "$fallbacks" in
    none|NONE|None) list='[]' ;;
    *) list="[$(printf '%s' "$fallbacks" | tr -d ' ' | sed 's/[^,][^,]*/"&"/g')]" ;;
  esac
  sed -i.bak "s#^fallback_models = .*#fallback_models = $list#" "$cfg/preflight.toml"
fi
if [ -n "$custom_max" ]; then
  sed -i.bak "s#^custom_model_max_tokens = [0-9][0-9]*#custom_model_max_tokens = $custom_max#" "$cfg/preflight.toml"
fi
if [ -n "$max_tokens" ]; then
  sed -i.bak "s#^max_model_tokens = [0-9][0-9]*#max_model_tokens = $max_tokens#" "$cfg/preflight.toml"
fi
if [ "$force_host" != "api.cline.bot" ]; then
  sed -i.bak "s#^\(force_streaming_api_base_substrings = \[\)\"[^\"]*\"#\1\"$force_host\"#" "$cfg/preflight.toml"
fi
rm -f "$cfg/preflight.toml.bak"

if [ -f "$cfg/.secrets.toml" ]; then
  say "==> keeping existing $cfg/.secrets.toml"
else
  say "==> writing $cfg/.secrets.toml (chmod 600)"
  sed "s#__API_BASE__#$api_base#g" "$files/secrets.toml.example" > "$cfg/.secrets.toml"
  chmod 600 "$cfg/.secrets.toml"
fi

if [ -n "$key" ]; then
  python3 - "$cfg/.secrets.toml" "$key" <<'PY'
import re, sys
p, key = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r'(?m)^(\s*key\s*=\s*).*$', lambda m: m.group(1) + '"' + key + '"', s)
open(p, 'w').write(s)
PY
  chmod 600 "$cfg/.secrets.toml"
  say "==> wrote API key into $cfg/.secrets.toml"
fi

say "==> installing helpers into $bindir"
install -m 0755 "$files/preflight-pr"   "$bindir/preflight-pr"
install -m 0755 "$files/preflight"      "$bindir/preflight"
install -m 0755 "$files/preflight-gate" "$bindir/preflight-gate"
install -m 0644 "$files/VERSION"        "$cfg/VERSION"
install -m 0644 "$files/ensure-link.sh" "$cfg/ensure-link.sh"
# The gate's policy template. Installed only if absent, so an edited live file is never overwritten -
# the gate has built-in defaults, so an untouched file and no file behave identically.
if [ -f "$files/gate.toml.example" ] && [ ! -f "$cfg/gate.toml" ]; then
  install -m 0644 "$files/gate.toml.example" "$cfg/gate.toml"
fi
# preflight-hook is what a repo's committed .githooks/pre-commit calls (via $PREFLIGHT_HOOK or
# ~/.config/preflight/preflight-hook), so it lives with the config rather than on PATH.
install -m 0755 "$files/preflight-hook" "$cfg/preflight-hook"
if [ -d "$files/githooks" ]; then
  mkdir -p "$cfg/githooks"
  install -m 0755 "$files/githooks/pre-commit"  "$cfg/githooks/pre-commit"
  install -m 0755 "$files/githooks/post-commit" "$cfg/githooks/post-commit"
fi
if [ -f "$here/AGENTS-review-snippet.md" ]; then
  install -m 0644 "$here/AGENTS-review-snippet.md" "$cfg/AGENTS-review-snippet.md"
fi

# Link the secrets file into the pr-agent package settings dir (skippable for testing).
if [ "${PREFLIGHT_SKIP_PACKAGE_LINK:-0}" != "1" ]; then
  pkg="$(find "$(uv tool dir 2>/dev/null)/pr-agent/lib" -maxdepth 4 -type d -path '*/pr_agent/settings' 2>/dev/null | head -1 || true)"
  if [ -n "${pkg:-}" ]; then
    ln -sf "$cfg/.secrets.toml" "$pkg/.secrets.toml"
    say "==> linked secrets -> $pkg/.secrets.toml"
  else
    say "!! could not locate the pr-agent package settings dir; run 'pr-agent --help' once, then re-run"
  fi
fi

# The old names are gone; warn if a previous install left them behind (uninstall.sh removes them).
for stale in pra pral pral-gate; do
  if [ -e "$bindir/$stale" ]; then
    say "!! stale helper from the old name found: $bindir/$stale (remove it; the new command is 'preflight*')"
  fi
done
if [ -d "$HOME/.config/pr-agent" ]; then
  say "!! old config dir $HOME/.config/pr-agent still exists - migrate it (move .secrets.toml) then remove it"
fi

case ":$PATH:" in *":$bindir:"*) : ;; *) say "!! $bindir is not on your PATH - add it, e.g. export PATH=\"\$PATH:$bindir\"" ;; esac

say ""
say "Done. Installed bundle version: $(head -n1 "$files/VERSION" 2>/dev/null || printf 'unknown')"
# Only ask for a key that is actually missing. On a refresh install the file is usually already
# configured, and telling that user to paste a key they set months ago trains them to ignore the
# line - which is the line they need to read on a genuinely new machine.
if [ -z "$key" ] && ! grep -qE '^[[:space:]]*key[[:space:]]*=[[:space:]]*"[^"]' "$cfg/.secrets.toml" 2>/dev/null; then
  say "NEXT: paste your API key into $cfg/.secrets.toml (it is chmod 600)"
fi
say "TRY:  cd <repo> && preflight review"
say ""
say "To make a repo REFUSE a commit that was not reviewed, commit the hooks and point git at them:"
say "  mkdir -p .githooks && install -m 0755 $cfg/githooks/* .githooks/ && git add .githooks"
say "  git update-index --chmod=+x .githooks/pre-commit .githooks/post-commit   # git IGNORES a non-executable hook"
say "  git config core.hooksPath .githooks      # relative, so it also works in every worktree"
say "See the 'enforce it' section of AGENTS-review-snippet.md."
