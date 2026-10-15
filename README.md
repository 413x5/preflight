# preflight — a deployable, machine-local PR-Agent review setup

[![CI](https://github.com/413x5/preflight/workflows/CI/badge.svg)](https://github.com/413x5/preflight/actions/workflows/ci.yml)

One command deploys a **machine-local** PR-Agent that reviews your **working tree** (no commit, no GitHub round
trip) and hands the findings back to whatever coding agent is editing the code. It works against **any
OpenAI-compatible endpoint**; ClinePass (`openai/cline-pass/deepseek-v4.1-flash`, `https://api.cline.bot/api/v1`)
is just the built-in default.

## What you get

| Command | What it does |
|---|---|
| `preflight review` | Reviews the **pending commit** — `HEAD` → working tree, untracked files included; writes `.preflight/review.md` + `.preflight/review.json` |
| `preflight-gate` | Machine check over `review.json` (exit 0 = pass) |
| `preflight-pr …` | PR-Agent with the global config (hosted/PR mode, needs a token) |

Every run that succeeds and produces output is also kept, with its start time, finish time and
`duration`, under `.preflight/runs/<id>/` — nothing is pruned, so the previous review survives the next
one.

- Reviews include committed **plus uncommitted and untracked** changes — a review never needs a commit.
- Secrets live in `~/.config/preflight/.secrets.toml` (chmod 600), symlinked into the PR-Agent package.
  **Nothing secret ever goes into your shell environment.**

## Docs

- [`docs/README.md`](docs/README.md) — **the map**: one line per document.
- [`docs/architecture.md`](docs/architecture.md) — how it works and why; [troubleshooting](docs/runbooks/troubleshooting.md) for a symptom and its fix.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — setup, and how to propose a change.
- [`AGENTS.md`](AGENTS.md) — the operational rules for whoever changes this repo.
- [`CHANGELOG.md`](CHANGELOG.md) — what changed, per version; [`docs/roadmap.md`](docs/roadmap.md) — planned work.
- [`SECURITY.md`](SECURITY.md) — the trust model, and how to report privately. [`LICENSE`](LICENSE) — MIT.

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
| `PREFLIGHT_PR_AGENT_VERSION` | pr-agent version to install; the bundle pins one it has been verified against |

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
preflight --help       # every command and environment variable
preflight --version    # the installed bundle version
```

Those paths always hold the **latest** run. Each run that succeeds and produces output is also archived
under `.preflight/runs/<id>/`, with a `run.json` recording when it started, when it finished and how long
it took; nothing prunes them, so `ls .preflight/runs` is the history of what has been reviewed. A run
that failed, or that finished without writing anything (an empty diff), has no entry: every entry is a
run that produced output you can read.

The default scope is `commit`: the review diffs `HEAD` against the working tree, untracked files included,
and needs no remote, no base and no fetch. `PREFLIGHT_SCOPE=worktree` reviews the
whole branch instead (default branch → working tree); only that scope resolves a base, trying `origin/HEAD`,
then the remote's own `HEAD`, then `origin/main|master`, then `main|master`. Set `PREFLIGHT_BASE=<ref>` to
target something else (a release branch, a fork's trunk); if nothing resolves, `preflight` says so and exits 4
rather than guessing a ref that does not exist.

One review is meant to report **everything** it was shown, so the loop converges instead of re-discovering
one issue at a time. That takes settings in `config/preflight.toml.example`: `num_max_findings` governs what the
model *reports*, and `enable_large_pr_chunking` governs whether it was shown the whole diff at all - without
it an oversized diff is pruned to a slice of the tree, and each round "discovers" more. If
anything still could not be covered, the summary line contains `coverage=PARTIAL` and `review.md` names the
omitted files; treat that as "there may be more here", not as a clean review.

Reporting everything is not the same as converging, though: a reviewer cannot tell a deliberate,
documented trade-off from an oversight, and each round reviews the text the previous round wrote. The
summary line therefore ends with a `new=N/M` count - how many findings were **not** in the previous
review. `new=0` is the stopping signal: judge each finding rather than re-fixing it, since repeating is
not the same as unresolved. Full detail in
[`docs/architecture.md`](docs/architecture.md#why-the-loop-converges-new-findings-not-a-clean-review).

## Teach your coding agents

Paste `AGENTS-review-snippet.md` into the repo's `AGENTS.md` so every agent follows the loop: review → fix all
findings in one pass → re-review → commit once when the gate is green. The snippet also points at this repo, so
an agent can look up current guidance as the bundle evolves.

## Make it enforced (recommended)

Instructions are easy to forget. A committed pre-commit hook makes the repo **refuse** a commit whose content
was never reviewed:

```sh
mkdir -p .githooks
install -m 0755 ~/.config/preflight/githooks/* .githooks/   # -m: git IGNORES a non-executable hook
git add .githooks
git update-index --chmod=+x .githooks/pre-commit .githooks/post-commit   # see the note below
git commit -m "chore: enforce preflight before commits"
git config core.hooksPath .githooks              # RELATIVE - required for worktrees
```

`install -m` sets the mode on disk, and `git update-index --chmod=+x` sets it **in the index**, which is
what a fresh clone checks out. The second step matters on a filesystem or a git configured with
`core.fileMode=false` (some mounted and network filesystems), where `git add` records `100644` however the
file was installed. Git **ignores a hook that is not executable** - it prints a hint and commits anyway -
so a repo whose hooks lost that bit enforces nothing while looking fully installed. Confirm with
`git ls-files -s .githooks/` (both lines must read `100755`).

- It **verifies** that the content being committed is exactly what `preflight review` reviewed; an edit
  after the review, or a newly staged unreviewed file, blocks the commit and names the paths.
- It is **content-based, not time-based** - a review counts only while it still covers what you commit.
- It **never runs a review** and is **strictly read-only** (index, `HEAD` and working tree untouched).
- Reviewed-but-uncommitted content is ignored, so `git commit -a` still works with untracked scratch files.
- Deleting a reviewed file is blocked too (`git rm` included) - the review must cover the removal. A
  submodule gitlink counts as a reviewed entry like any other, so removing one is blocked as well.
- Renaming a reviewed file (`git mv`) or swapping one for a symlink is blocked as well.
- The first commit in a repo with no history is allowed but not enforced; `preflight review` needs `HEAD`.
- `PREFLIGHT_SCOPE=head` reviews cannot be enforced; the default `commit` scope can.
- `post-commit` is advisory and cannot block: it warns when the last review used `head` scope (so no commit
  was actually verified), and when it cannot read the review sidecar at all - a missing `python3`, or a
  malformed/`scope`-less sidecar. Silence is reserved for "verified" and "no review has run yet".
- One-off bypass: `git commit --no-verify` (or `PREFLIGHT_SKIP=1`).
- The verifier's path is overridable with `PREFLIGHT_HOOK` (default `~/.config/preflight/preflight-hook`),
  for a repo that vendors its own copy instead of relying on the installed one.

Use the **relative** hooks path - an absolute one breaks git worktrees. See
[`docs/architecture.md`](docs/architecture.md) for how the check works and why.

## What install.sh writes

- `~/.local/bin/{preflight,preflight-pr,preflight-gate}` — the helpers.
- `~/.config/preflight/VERSION` — the installed bundle version (`preflight --version` reads it).
- `~/.config/preflight/{preflight.toml,gate.toml,ensure-link.sh,AGENTS-review-snippet.md,preflight-hook}` — config + helpers (`gate.toml` is created only if missing).
- `~/.config/preflight/githooks/{pre-commit,post-commit}` — the example hooks to copy into a repo's `.githooks/`.
- `~/.config/preflight/.secrets.toml` — created only if missing, chmod 600.
- A symlink from that secrets file into the PR-Agent package's `settings/` dir.

## Development

CI runs on every pull request and on pushes to `main`, on Ubuntu and macOS, and it runs the same command
you do:

```sh
./scripts/verify          # the gate: every check, cheapest first
./scripts/verify --list   # the stages, to run one while working
```

The gate includes a **selfcheck** - the test suite re-run against a neutered hook - because a green suite
is not proof the hook enforces anything: stubbing the hook out entirely still satisfies the cases that
assert *acceptance* rather than refusal, so "all green" alone would prove nothing.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) to get started and
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
- Runs are append-only under `.preflight/runs/` and nothing deletes them; remove a directory to drop that
  run. The top-level `review.md`/`review.json`/`review.meta.json` stay as they are, because the commit
  hook and `preflight-gate` read them by name.
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
