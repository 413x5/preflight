#!/usr/bin/env bash
# install.sh - deploy the local PR-Agent (ClinePass) review setup on this machine.
#
#   ./install.sh                              # install/refresh everything
#   PR_AGENT_KEY=sk-... ./install.sh          # also write the API key now
#   PR_AGENT_API_BASE=https://... ./install.sh  # a different OpenAI-compatible endpoint
#   PRAGENT_PY=3.12 ./install.sh              # a different interpreter pin
#   PRAGENT_SKIP_TOOL_INSTALL=1 ./install.sh  # skip `uv tool install` (assume pr-agent present)
#
# Idempotent: never overwrites an existing .secrets.toml.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
files="$here/files"
cfg="${PRAGENT_HOME:-$HOME/.config/pr-agent}"
bindir="${PRAGENT_BIN_DIR:-$HOME/.local/bin}"
py="${PRAGENT_PY:-3.13}"
api_base="${PR_AGENT_API_BASE:-https://api.cline.bot/api/v1}"
api_host="$(printf '%s' "$api_base" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+).*#\1#')"
key="${PR_AGENT_KEY:-}"

say() { printf '%s\n' "$*" >&2; }

command -v git >/dev/null 2>&1 || { say "install: 'git' is required"; exit 1; }

if [ "${PRAGENT_SKIP_TOOL_INSTALL:-0}" != "1" ]; then
  command -v uv >/dev/null 2>&1 || { say "install: 'uv' not found - install it first:"; say "  curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
  say "==> uv tool install --python $py pr-agent"
  uv tool install --python "$py" pr-agent >/dev/null
else
  say "==> skipping pr-agent install (PRAGENT_SKIP_TOOL_INSTALL=1)"
fi

mkdir -p "$cfg" "$bindir"

say "==> writing $cfg/pr-agent.toml (streaming endpoint: $api_host)"
sed "s#__API_HOST__#$api_host#g" "$files/pr-agent.toml" > "$cfg/pr-agent.toml"

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
install -m 0755 "$files/pra"       "$bindir/pra"
install -m 0755 "$files/pral"      "$bindir/pral"
install -m 0755 "$files/pral-gate" "$bindir/pral-gate"
install -m 0644 "$files/ensure-link.sh" "$cfg/ensure-link.sh"
if [ -f "$here/AGENTS-review-snippet.md" ]; then
  install -m 0644 "$here/AGENTS-review-snippet.md" "$cfg/AGENTS-review-snippet.md"
fi

# Link the secrets file into the pr-agent package settings dir (skippable for testing).
if [ "${PRAGENT_SKIP_PACKAGE_LINK:-0}" != "1" ]; then
  pkg="$(find "$(uv tool dir 2>/dev/null)/pr-agent/lib" -maxdepth 4 -type d -path '*/pr_agent/settings' 2>/dev/null | head -1 || true)"
  if [ -n "${pkg:-}" ]; then
    ln -sf "$cfg/.secrets.toml" "$pkg/.secrets.toml"
    say "==> linked secrets -> $pkg/.secrets.toml"
  else
    say "!! could not locate the pr-agent package settings dir; run 'pra --help' once, then re-run"
  fi
fi

case ":$PATH:" in *":$bindir:"*) : ;; *) say "!! $bindir is not on your PATH - add it, e.g. export PATH=\"\$PATH:$bindir\"" ;; esac

say ""
say "Done."
if [ -z "$key" ]; then say "NEXT: paste your API key into $cfg/.secrets.toml (it is chmod 600)"; fi
say "TRY:  cd <repo> && pral review"
