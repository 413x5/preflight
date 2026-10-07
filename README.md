# preflight — a deployable, machine-local PR-Agent review setup

[![CI](https://github.com/413x5/preflight/workflows/CI/badge.svg)](https://github.com/413x5/preflight/actions/workflows/ci.yml)

One command deploys a **machine-local** PR-Agent that reviews your **working tree** (no commit, no GitHub round
trip) and hands the findings back to whatever coding agent is editing the code. It works against **any
OpenAI-compatible endpoint**; ClinePass (`openai/cline-pass/deepseek-v4.1-flash`, `https://api.cline.bot/api/v1`)
is just the built-in default.

## What you get

| Command | What it does |
|---|---|
| `preflight review` | Reviews the current branch's **working tree** vs the remote default branch; writes `.preflight/review.md` + `.preflight/review.json` |
| `preflight-gate` | Machine check over `review.json` (exit 0 = pass) |
| `preflight-pr …` | PR-Agent with the global config (hosted/PR mode, needs a token) |

- Reviews include committed **plus uncommitted and untracked** changes — a review never needs a commit.
- Secrets live in `~/.config/preflight/.secrets.toml` (chmod 600), symlinked into the PR-Agent package.
  **Nothing secret ever goes into your shell environment.**

## Docs

- [`AGENTS.md`](AGENTS.md) — instructions for AI agents **changing this repo** (invariants, checks, traps).
- [`CHANGELOG.md`](CHANGELOG.md) — what changed, per version.
- [`ROADMAP.md`](ROADMAP.md) — planned work and open decisions.
- [`docs/DESIGN.md`](docs/DESIGN.md) — how it works and why.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — symptoms and fixes.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — layout, ground rules, how to test changes.
- [`tests/README.md`](tests/README.md) — the integration suite for the commit hook.

## Requirements

- macOS or Linux, and `git`.
- [`uv`](https://astral.sh/uv) — installs PR-Agent in an isolated venv:
  `curl -LsSf https://astral.sh/uv/install.sh | sh`
- Python 3.13 (the installer's default; `PREFLIGHT_PY` overrides it, and uv can fetch one).
- Network access to an OpenAI-compatible endpoint (ClinePass by default, or your own).

## Install

```sh
git clone https://github.com/413x5/preflight ~/preflight
cd ~/preflight
./install.sh
$EDITOR ~/.config/preflight/.secrets.toml      # paste the API key between the quotes
```

Non-interactive:

```sh
PREFLIGHT_KEY=... ./install.sh
```

## Using another provider

Any OpenAI-compatible endpoint works. Point the installer at it and override whichever defaults you need —
all of these are optional, and the defaults (ClinePass) are kept when unset:

```sh
PREFLIGHT_API_BASE=https://api.openai.com/v1 \
PREFLIGHT_KEY=sk-... \
PREFLIGHT_MODEL=gpt-4o \
PREFLIGHT_FALLBACK_MODELS="openai/gpt-4o-mini" \
PREFLIGHT_CUSTOM_MODEL_MAX_TOKENS=0 \
PREFLIGHT_MAX_MODEL_TOKENS=0 \
  ./install.sh
```

| Variable | Meaning |
|---|---|
| `PREFLIGHT_API_BASE` | The endpoint base URL (also written into `.secrets.toml`) |
| `PREFLIGHT_KEY` | The API key (written into `.secrets.toml`) |
| `PREFLIGHT_MODEL` | Primary model id, in the endpoint's own id form |
| `PREFLIGHT_FALLBACK_MODELS` | Comma-separated fallback ids; `none` disables fallback |
| `PREFLIGHT_CUSTOM_MODEL_MAX_TOKENS` | Context window for a model LiteLLM doesn't know; **`0` = ask LiteLLM** |
| `PREFLIGHT_MAX_MODEL_TOKENS` | Packing clamp; **`0` = no clamp** |
| `PREFLIGHT_FORCE_STREAMING_HOST` | Host needing the ClinePass streaming workaround (see below) |

Two of these matter more than they look:

- **Token budgets.** `cline-pass/*` is not in LiteLLM's model table, so nothing declares its context window and
  the packing clamp would cut the diff to 32k — hence the explicit values. For a model LiteLLM *does* know, set
  both to `0` and let it resolve the window itself rather than overriding it with a guess.
- **Force-streaming.** ClinePass returns a wrapped non-streaming envelope (`{"data":…,"success":true}`) that
  LiteLLM cannot parse, so the config forces streaming **for that host only**. The substring is matched against
  your `api_base`, so for any other endpoint it simply never matches and the block stays inert.

## Use

```sh
cd /any/repo
preflight review       # -> .preflight/review.md + .preflight/review.json
preflight-gate         # exit 0 = pass; 1 = changes required/issues; 2 = security concerns; 3 = no review
preflight describe     # or: preflight improve ; preflight ask "<question>"
```

## Teach your coding agents

Paste `AGENTS-review-snippet.md` into the repo's `AGENTS.md` so every agent follows the loop: review → fix all
findings in one pass → re-review → commit once when the gate is green. The snippet also points at this repo, so
an agent can look up current guidance as the bundle evolves.

## Make it enforced (recommended)

Instructions are easy to forget. A committed pre-commit hook makes the repo **refuse** a commit whose content
was never reviewed:

```sh
cp ~/.config/preflight/githooks/* .githooks/     # shipped by install.sh
git add .githooks && git commit -m "chore: enforce preflight before commits"
git config core.hooksPath .githooks              # RELATIVE - required for worktrees
```

- It **verifies** that the content being committed is exactly what `preflight review` reviewed; an edit
  after the review, or a newly staged unreviewed file, blocks the commit and names the paths.
- It is **content-based, not time-based** - a review counts only while it still covers what you commit.
- It **never runs a review** and is **strictly read-only** (index, `HEAD` and working tree untouched).
- Reviewed-but-uncommitted content is ignored, so `git commit -a` still works with untracked scratch files.
- Deleting a reviewed file is blocked too (`git rm` included) - the review must cover the removal. A
  submodule gitlink counts as a reviewed entry like any other, so removing one is blocked as well.
- Renaming a reviewed file (`git mv`) or swapping one for a symlink is blocked as well.
- The first commit in a repo with no history is allowed but not enforced; `preflight review` needs `HEAD`.
- `PREFLIGHT_SCOPE=head` reviews cannot be enforced; use the default worktree scope.
- One-off bypass: `git commit --no-verify` (or `PREFLIGHT_SKIP=1`).
- The verifier's path is overridable with `PREFLIGHT_HOOK` (default `~/.config/preflight/preflight-hook`),
  for a repo that vendors its own copy instead of relying on the installed one.

Use the **relative** hooks path - an absolute one breaks git worktrees. See
[`docs/DESIGN.md`](docs/DESIGN.md) for how the check works and why.

## What install.sh writes

- `~/.local/bin/{preflight,preflight-pr,preflight-gate}` — the helpers.
- `~/.config/preflight/{preflight.toml,ensure-link.sh,AGENTS-review-snippet.md,preflight-hook}` — config + helpers.
- `~/.config/preflight/githooks/{pre-commit,post-commit}` — the example hooks to copy into a repo's `.githooks/`.
- `~/.config/preflight/.secrets.toml` — created only if missing, chmod 600.
- A symlink from that secrets file into the PR-Agent package's `settings/` dir.

## Development

CI runs on every pull request and on pushes to `main`, on Ubuntu and macOS: shell syntax, an installer
dry-run into a throwaway prefix, a TOML check on the generated config, and the commit-hook integration
suite. Everything it runs is available locally:

```sh
./tests/run.sh hook        # the offline hook tests, in seconds
actionlint                 # workflow lint
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full list and
[`tests/README.md`](tests/README.md) for the requirement-to-case mapping.

The CI badge in this README only renders for signed-in viewers, because the repository is private.

## Uninstall

```sh
./uninstall.sh                            # helpers + config (keeps the uv tool)
PREFLIGHT_REMOVE_TOOL=1 ./uninstall.sh    # also removes the uv tool
```

`uninstall.sh` also cleans up a pre-rename install (`pra`/`pral`/`pral-gate` and `~/.config/pr-agent`), so
nothing is left behind. Set `PREFLIGHT_KEEP_OLD_CONFIG=1` to keep the old config (its `.secrets.toml` holds your
key) and migrate it by hand.

## Notes

- `preflight` adds `.preflight/` to each repo's `.git/info/exclude` automatically, so review output is never
  committed.
- The commit hook is opt-in per repo: copy `~/.config/preflight/githooks/*` into the repo's `.githooks/` and
  set the **relative** `core.hooksPath`. See "Make it enforced" above.
- The helpers run the upstream **`pr-agent`** tool (installed by `uv`); "pr-agent" here always means that
  upstream project, not this bundle.
- Upgrading PR-Agent (`uv tool upgrade pr-agent`) recreates the venv; the wrappers re-link the secrets
  automatically.

## Upgrading from the old `pr-agent`-named bundle

The commands and config path were renamed. To migrate without losing the key:

```sh
cd ~/preflight && ./install.sh                          # installs the new commands + ~/.config/preflight
mv ~/.config/pr-agent/.secrets.toml ~/.config/preflight/.secrets.toml
chmod 600 ~/.config/preflight/.secrets.toml
./uninstall.sh                                          # removes old helpers, config dir and stale .toml
```

Then re-paste the updated `AGENTS-review-snippet.md` into any repo that still calls `pral` — that command no
longer exists.
