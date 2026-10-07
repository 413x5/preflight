# Contributing

This repo is a **portable bundle**: `install.sh` plus the files under `files/` are the source of
truth for the machine-local PR-Agent setup. Keep it portable, and keep it provider-agnostic — ClinePass
is a default, not an assumption.

## Layout

| Path | What it is |
|---|---|
| `install.sh` / `uninstall.sh` | Deploy / remove the setup on a machine |
| `files/preflight.toml` | The global config (model, provider/streaming knobs, review caps) |
| `files/preflight`, `files/preflight-pr`, `files/preflight-gate` | The helpers installed into `~/.local/bin` |
| `files/preflight-hook` | The commit-time verifier; a repo's `.githooks/pre-commit` calls it |
| `files/githooks/` | Example hooks a repo copies into its own `.githooks/` |
| `files/ensure-link.sh` | Re-links the secrets file after `uv tool upgrade` |
| `files/secrets.toml.example` | The secrets template - **never** a real key |
| `AGENTS-review-snippet.md` | The block pasted into a repo's `AGENTS.md` |
| `tests/` | Integration tests for the commit hook, plus the sample fixture they build on |

## Ground rules

- **No secrets, ever.** Only `files/secrets.toml.example` (with an empty key) is committed.
  `.gitignore` also blocks `.secrets.toml`.
- **No machine-specific paths.** Everything derives from `$HOME` or the documented env vars.
- **Provider-agnostic.** Do not hard-code a provider into the mechanism. Anything specific to one
  endpoint (a model id, a streaming quirk, a token window) belongs in `files/preflight.toml` as an
  overridable default, documented as provider-specific in both the file and `docs/DESIGN.md`.
- **Idempotent installs.** `install.sh` must be safe to re-run and must never clobber an existing
  `~/.config/preflight/.secrets.toml`.
- **Keep `pr-agent` meaning one thing.** It is the upstream tool; this bundle is `preflight`. Do not
  reintroduce `pra`/`pral`/`pral-gate` or a `pr-agent`-named config file.

## Testing changes

`tests/run.sh` is the integration suite: real repositories, the real hook files, no framework and no
network. Refer to [`tests/README.md`](tests/README.md) for the requirement-to-case mapping.

```sh
./tests/run.sh hook      # offline, seconds
./tests/run.sh           # includes one live-endpoint case (needs a configured key)
```

`install.sh` is also testable without touching your real setup - point it at throwaway dirs and skip the
parts that need `uv` or the network:

```sh
T="$(mktemp -d)"
PREFLIGHT_HOME="$T/cfg" PREFLIGHT_BIN_DIR="$T/bin" \
PREFLIGHT_SKIP_TOOL_INSTALL=1 PREFLIGHT_SKIP_PACKAGE_LINK=1 \
  ./install.sh
ls "$T/bin"        # preflight  preflight-pr  preflight-gate
rm -rf "$T"
```

Check the **default parity** invariant whenever you touch `files/preflight.toml` or the installer:
with no overrides set, the generated config must still parse to the same values it did before.

```sh
python3 -c "import tomllib;print(tomllib.load(open('$T/cfg/preflight.toml','rb'))['config'])"
```

Sanity-check the shell (the hooks are POSIX `sh`, the helpers `bash`):

```sh
for f in install.sh uninstall.sh files/preflight files/preflight-pr files/preflight-gate files/ensure-link.sh; do
  bash -n "$f" || echo "FAIL $f"
done
for f in files/preflight-hook files/githooks/pre-commit files/githooks/post-commit tests/run.sh; do
  sh -n "$f" || echo "FAIL $f"
done
```

Test the commit hook in a **throwaway** repo, never in a working checkout — `core.hooksPath` is
clone-wide, so setting it here would apply to every worktree of this clone:

```sh
R="$(mktemp -d)"; cd "$R"; git init -q -b main .
printf '# x\n' > README.md; git add README.md; git -c commit.gpgsign=false commit -q -m init
mkdir -p .githooks && cp ~/.config/preflight/githooks/* .githooks/
git config core.hooksPath .githooks

git -c commit.gpgsign=false commit --allow-empty -m should-block   # no review -> blocked
preflight review && preflight-gate                                  # must be a pass
git -c commit.gpgsign=false commit -m "feat: ok"                    # now accepted
```

## Commits

[Conventional Commits](https://www.conventionalcommits.org/) (`type(scope): subject`), one logical
change per commit. Call out breaking changes (renamed commands, renamed env vars) explicitly in both
the commit body and `CHANGELOG.md`.
