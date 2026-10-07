# Contributing

This repo is a **portable bundle**: `install.sh` plus the files under `files/` are the source of
truth for the machine-local PR-Agent setup. Keep it portable.

## Layout

| Path | What it is |
|---|---|
| `install.sh` / `uninstall.sh` | Deploy / remove the setup on a machine |
| `files/pr-agent.toml` | The global config (ClinePass model, streaming fix, review caps) |
| `files/pra`, `files/pral`, `files/pral-gate` | The helpers installed into `~/.local/bin` |
| `files/ensure-link.sh` | Re-links the secrets file after `uv tool upgrade` |
| `files/secrets.toml.example` | The secrets template - **never** a real key |
| `AGENTS-review-snippet.md` | The block pasted into a repo's `AGENTS.md` |

## Ground rules

- **No secrets, ever.** Only `files/secrets.toml.example` (with an empty key) is committed.
  `.gitignore` also blocks `.secrets.toml`.
- **No machine-specific paths.** Everything derives from `$HOME` or the documented env vars.
- **Idempotent installs.** `install.sh` must be safe to re-run and must never clobber an existing
  `~/.config/pr-agent/.secrets.toml`.

## Testing changes

`install.sh` is testable without touching your real setup - point it at throwaway dirs and skip the
parts that need `uv` or the network:

```sh
T="$(mktemp -d)"
PRAGENT_HOME="$T/cfg" PRAGENT_BIN_DIR="$T/bin" \
PRAGENT_SKIP_TOOL_INSTALL=1 PRAGENT_SKIP_PACKAGE_LINK=1 \
  ./install.sh
ls "$T/bin"        # pra  pral  pral-gate
rm -rf "$T"
```

Sanity-check the shell:

```sh
for f in install.sh uninstall.sh files/pra files/pral files/pral-gate files/ensure-link.sh; do
  bash -n "$f" || echo "FAIL $f"
done
```

## Commits

[Conventional Commits](https://www.conventionalcommits.org/) (`type(scope): subject`), one logical
change per commit.
