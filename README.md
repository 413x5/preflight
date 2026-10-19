# preflight — a deployable, machine-local PR-Agent review setup

[![CI](https://github.com/413x5/preflight/workflows/CI/badge.svg)](https://github.com/413x5/preflight/actions/workflows/ci.yml)

One command deploys a **machine-local** PR-Agent that reviews your **working tree** (no commit, no GitHub round
trip) and hands the findings back to whatever coding agent is editing the code. It works against **any
OpenAI-compatible endpoint**; the endpoint, the model and the credential are yours to set once, after the
install.

## What you get

| Command | What it does |
|---|---|
| `preflight-code review` | Reviews the **pending commit** — `HEAD` → working tree, untracked files included; writes `.preflight/review.md` + `.preflight/review.json` |
| `preflight-gate` | Machine check over `review.json` (exit 0 = pass) |
| `preflight-pr …` | PR-Agent with the global config (hosted/PR mode, needs a token) |

Every run that succeeds and produces output is also kept, with its start time, finish time and
`duration`, under `.preflight/runs/<id>/` — nothing is pruned, so the previous review survives the next
one.

- Reviews include committed **plus uncommitted and untracked** changes — a review never needs a commit.
- Secrets live in `~/.config/preflight/providers.toml` (chmod 600), one key per endpoint.
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
- Python 3.13 (the installer's default; `PREFLIGHT_PY` overrides it, and uv can fetch one) for PR-Agent,
  **and a `python3` 3.11+ on `PATH`** - `preflight-code` reads `settings.toml` with the standard library's
  `tomllib`, which entered it in 3.11. `install.sh` warns when the one it finds is older or absent.
- Network access to an OpenAI-compatible endpoint of your own.

## Install

```sh
git clone https://github.com/413x5/preflight ~/preflight
cd ~/preflight
./install.sh

# create your config from the installed references, then edit them
cp ~/.config/preflight/settings.toml.example  ~/.config/preflight/settings.toml
( umask 077; cp ~/.config/preflight/providers.toml.example ~/.config/preflight/providers.toml )
$EDITOR ~/.config/preflight/providers.toml      # your endpoint, key and model id
$EDITOR ~/.config/preflight/settings.toml       # [selection] main = that profile's name
```

`install.sh` installs helpers, hooks and the two **reference** files - `settings.toml.example` and
`providers.toml.example` - and deliberately creates neither `settings.toml` nor `providers.toml`: it knows
no endpoint, no model id and no window, so a file it wrote could only be a guess. The two files are yours,
and a review refuses to start without them rather than defaulting to anything. The refusal offers only the
copy that applies: a missing `settings.toml` prints that command (and the `providers.toml` one too, if that
file is absent as well), while a `providers.toml` that defines no `[profiles.<name>]` table names the file
and the tables to add. It will not tell you to copy a template over a file you already have, because that
file may be the one holding your key.

The credential is the one value the resolver enforces: it refuses to start on an empty `key` rather than
calling an endpoint without one. The endpoint and the model are ordinary strings, so the review will send
them as written - replace the placeholder host and model id, not just the key. `providers.toml` must stay
`chmod 600`; `install.sh` tightens it on a later run if it finds it looser.

## Using a different endpoint

Configuration happens **after** the install, in `providers.toml` - there are no variables that seed an
endpoint or a model:

```toml
# ~/.config/preflight/providers.toml
[providers.mine]
api_base = "https://api.example.com/v1"
key      = "sk-..."                # this file is chmod 600
# stream = true                    # see below

[profiles.mine]
provider = "mine"
model    = "your-model-id"
```

Then point `settings.toml`'s `[selection]` at that profile name. Variables that configure the *install
itself* (`PREFLIGHT_PR_AGENT_VERSION`, `PREFLIGHT_PY`, `PREFLIGHT_HOME`, `PREFLIGHT_BIN_DIR`,
`PREFLIGHT_SKIP_TOOL_INSTALL`) are listed in the header of `install.sh`; none of them names an endpoint or
a model.

Two settings in a profile are worth knowing about:

- **Token budgets** (`[profiles.<name>.config]`). `custom_model_max_tokens` is what pr-agent measures the
  prompt against when LiteLLM does not know the model id, so an id LiteLLM cannot resolve fails the review
  until you set it. `max_model_tokens` clamps the diff, and `max_output_tokens` caps the reply: unset, the
  endpoint's own ceiling applies and a reasoning model can spend all of it thinking, returning truncated
  output pr-agent treats as a failed call.
- **`stream = true`** on the *provider*, for an endpoint whose non-streaming reply LiteLLM cannot parse.
  preflight-code forces streaming **for that provider's own host only**; every other endpoint gets an empty
  pair, so the workaround never engages there.

### More than one endpoint

`~/.config/preflight/providers.toml` (600-mode, created by copying the installed reference) holds each endpoint and the
profiles that use it:

```toml
# providers.toml
[providers.mine]
api_base = "https://api.example.com/v1"
key      = "sk-..."
# stream = true                  # only if this host's non-streaming reply needs SSE

[providers.work]
api_base = "https://llm.internal.corp/v1"
key      = "sk-..."
```

```toml
# settings.toml - says what the REVIEW does
[selection]
main = "mine"                    # the profile to use first, by name
# fallback = ["mine-backup"]       # commented because nothing defines that profile below; assign a
                                   # [profiles.*] table you actually have, or leave it out

[pr_reviewer]
num_max_findings = 10
```

```toml
# providers.toml - the same file, above the [providers.*] tables
[profiles.mine]
provider = "mine"
model    = "your-model-id"

[profiles.mine.config]           # this model's own budgets
custom_model_max_tokens = 200000
max_model_tokens        = 150000
max_output_tokens       = 100000

[profiles.work]
provider = "work"
model    = "their-model-id"
```

A profile is a complete description of one model — its id, the endpoint that serves it, and the settings
that are properties of *that* model — so switching `main` switches all of it. Profiles live beside the
endpoints they name, in `providers.toml`.

There is no third config file: `settings.toml` is the config pr-agent receives, apart from what a run
decides (the model, its endpoint and credential, and the three `[litellm]` keys derived from the provider),
so any pr-agent key works there even if the template does not list it.

`[litellm]` settings are per endpoint too, so they go on the provider:

```toml
[providers.mine.litellm]
callback_timeout_seconds = 5
turn_off_message_logging = true
cache_control_injection_points = [{ location = "message", role = "system" }]
```

The keys accepted there are listed in `config/providers.toml.example`: callbacks and their timeout,
message logging, prompt-cache points, `drop_params`, `model_id`. The three preflight *derives* —
`custom_llm_provider`, `force_streaming_custom_llm_provider`, `force_streaming_api_base_substrings` — are
**refused**, because they follow that provider's `transport` and `stream` and a pin that disagreed with the
endpoint is resolved silently, to the wrong host. Any other `[litellm]` key is refused by name rather than
ignored, so a newer pr-agent setting is a one-line addition to the allow-list rather than a surprise. A
setting that is the same for *every* endpoint belongs in `settings.toml`'s own `[litellm]`.

The review knobs are the exception: they are the only run-wide, non-endpoint section, because **pr-agent
applies `[pr_reviewer]` to the whole run**, not to one model - so a copy per profile would be the same
answer written twice and free to drift. Every other pr-agent section (`[config]`, `[litellm]`) still
belongs in `settings.toml` when the value is the same for every model.

One catch, reported rather than refused: because pr-agent holds one config per run, the assigned profile's
budgets govern every model in the chain, including a fallback that answers. A fallback's own budgets
therefore cannot take effect while it is a fallback — `preflight-code` warns when it sees them, and they apply
the moment that profile is assigned as `main`.

A profile name is a TOML key, and a bare key cannot contain a dot: `[profiles.v4.1-flash]` splits into a
table `v4` with a child `1-flash`. Name profiles without dots, or quote the name everywhere it appears —
`[profiles."v4.1-flash"]` and `main = "v4.1-flash"`. The resolver diagnoses an unquoted one and says so.

Switching endpoints is then one line — `main = "work"` — and the model id needs no provider prefix, because
the provider is named on its own line instead of being spelled inside the id.

Before each run, `preflight-code` renders those two files into **one** config for pr-agent, 600-mode, outside the
repository, and overwrites it before every run. Nothing about this is per-run bookkeeping you have to do: an
install with no assignment in `settings.toml` refuses rather than reviewing: there is no fallback config, so
a file that assigns no profile has no model at all.

### Per-repository settings, and the gate's policy

A repository may override any review setting in **one** committed file at its root, `.preflight.toml`. The
merge is by section, then by key: what the file sets wins, and everything it does not mention stays as the
machine's `settings.toml` had it.

```toml
# .preflight.toml - committed with the repository
[pr_reviewer]
num_max_findings = 16

[gate]                     # the same table, so the gate's policy travels with the repo too
doc_blocks = true
```

`[profiles.*]`, `[providers.*]` and `[selection]` are **refused** there. Each names a model and, through it,
a credential entry, and a committed file that chose one would decide, on every machine that clones the
repository, which key a review spends. The models stay machine-local in `settings.toml`/`providers.toml`;
the repository overrides what the review *does* and what the gate decides.

The gate reads only its `[gate]` table, from `settings.toml` and then `.preflight.toml`; `preflight-gate
--help` lists the keys, and the `PREFLIGHT_GATE_*` environment variables override both. The renderer strips
`[gate]` from the config pr-agent receives, since pr-agent reads nothing from it.

`transport` is optional and defaults to `openai` — the OpenAI-compatible transport, which does not mean the
provider is OpenAI. Set it to name a different one (`anthropic`, `gemini`, …) where the endpoint is not
OpenAI-compatible; only `openai`, `openrouter`, `moonshot`, `ollama`, `huggingface` and `databricks` read an
endpoint from a config file, so a provider on any other transport takes its `api_base` from that provider's own
environment variable and carries only its key here.

A run holds **one** endpoint, so `main` and its fallbacks must name the same provider: pr-agent pins one
transport per process, and a chain spanning two would be answered by whichever one is pinned — a different
host, with that provider's key. `preflight-code` refuses that instead, naming the provider, and refuses a `provider`
that no `[providers.*]` table defines rather than letting pr-agent fall back to another section's host.

## Use

```sh
cd /any/repo
preflight-code review  # -> .preflight/review.md + .preflight/review.json
preflight-gate         # exit 0 = pass; 1 = key issues; 2 = security concerns; 3 = no review
preflight-code describe # or: preflight-code improve ; preflight-code ask "<question>"
preflight-code --help  # every command and environment variable
preflight-code --version # the installed bundle version
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
target something else (a release branch, a fork's trunk); if nothing resolves, `preflight-code` says so and exits 4
rather than guessing a ref that does not exist.

One review is meant to report **everything** it was shown, so the loop converges instead of re-discovering
one issue at a time. `num_max_findings` in `settings.toml` governs what the model *reports*,
and that file lists every `[pr_reviewer]` knob pr-agent accepts - the bundle's own settings live and the rest
commented at upstream's value - so the levers are visible without reading pr-agent's source.
What that setting cannot do is change what the model was *shown*: when a diff exceeds the token budget
pr-agent reviews it minus the files it pruned, so if anything could not be covered the summary line contains
`coverage=PARTIAL` and `review.md` names the omitted files. Treat that as "there may be more here", not as a
clean review, and raise the token budget rather than round-tripping until the files happen to come into view.

Reporting everything is not the same as converging, though: a reviewer cannot tell a deliberate,
documented trade-off from an oversight, and each round reviews the text the previous round wrote. The
summary line therefore ends with a `new=N/M` count - how many findings were **not** in the previous
review. `new=0` is the stopping signal: judge each finding rather than re-fixing it, since repeating is
not the same as unresolved. Full detail in
[`docs/architecture.md`](docs/architecture.md#why-the-loop-converges-new-findings-not-a-clean-review).

## Teach your coding agents

Paste `AGENTS-review-snippet.md` into the repo's `AGENTS.md` so every agent follows the loop: review → fix all
findings in one pass → re-review → commit once when the gate is green. **Adapt it rather than copying it
whole** - every section is classified `required` or `setup`, and the `setup` parts (the install and
hook-adoption recipes) are worth nothing once they have been run. Keep the `required` facts as written,
because a paraphrase of a fact about the installed helper is a fact that drifts from it. The snippet also
points at this repo, so an agent can look up current guidance as the bundle evolves.

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

- It **verifies** that the content being committed is exactly what `preflight-code review` reviewed; an edit
  after the review, or a newly staged unreviewed file, blocks the commit and names the paths.
- It is **content-based, not time-based** - a review counts only while it still covers what you commit.
- It **never runs a review** and is **strictly read-only** (index, `HEAD` and working tree untouched).
- Reviewed-but-uncommitted content is ignored, so `git commit -a` still works with untracked scratch files.
- Deleting a reviewed file is blocked too (`git rm` included) - the review must cover the removal. A
  submodule gitlink counts as a reviewed entry like any other, so removing one is blocked as well.
- Renaming a reviewed file (`git mv`) or swapping one for a symlink is blocked as well.
- The first commit in a repo with no history is allowed but not enforced; `preflight-code review` needs `HEAD`.
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

- `~/.local/bin/{preflight-code,preflight-pr,preflight-gate}` — the helpers.
- `~/.config/preflight/VERSION` — the installed bundle version (`preflight-code --version` reads it).
- `~/.config/preflight/{settings-render.sh,AGENTS-review-snippet.md,preflight-hook}` — helpers and the shipped snippet.
- `~/.config/preflight/settings.toml.example` also carries the gate's policy as a commented `[gate]` table: one file for everything preflight can be told, and the renderer strips the table before pr-agent sees it.
- `~/.config/preflight/{settings,providers}.toml.example` — the two reference files, 600-mode for the one that shows where the key goes. `install.sh` never creates `settings.toml` or `providers.toml`: they are yours, created by copying the references, and a reinstall leaves them alone (tightening `providers.toml` to 600 if it finds it looser).
- `~/.config/preflight/githooks/{pre-commit,post-commit}` — the example hooks to copy into a repo's `.githooks/`.


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
nothing is left behind. Set `PREFLIGHT_KEEP_OLD_CONFIG=1` to keep the old config (it holds the key you will
want to copy into `providers.toml`) and migrate it by hand.

## Notes

- `preflight-code` adds `.preflight/` to each repo's `.git/info/exclude` automatically, so review output is never
  committed.
- Runs are append-only under `.preflight/runs/` and nothing deletes them; remove a directory to drop that
  run. The top-level `review.md`/`review.json`/`review.meta.json` stay as they are, because the commit
  hook and `preflight-gate` read them by name.
- The commit hook is opt-in per repo: copy `~/.config/preflight/githooks/*` into the repo's `.githooks/` and
  set the **relative** `core.hooksPath`. See "Make it enforced" above.
- The helpers run the upstream **`pr-agent`** tool (installed by `uv`); "pr-agent" here always means that
  upstream project, not this bundle.
- Upgrading PR-Agent (`uv tool upgrade pr-agent`) recreates the venv. Nothing needs re-linking: the config
  reaches pr-agent as a file the wrapper renders, so nothing is written into the package's `settings/` dir.

## Upgrading from the old `pr-agent`-named bundle

The commands and config path were renamed. There is no automatic migration: the endpoint, the model and
the key are values you re-enter in the new `providers.toml`.

```sh
# 1. Remove the old install (helpers and old config dirs).
cd ~/preflight && ./uninstall.sh

# 2. Install, create your config from the references it installs, then fill them in.
./install.sh
cp ~/.config/preflight/settings.toml.example  ~/.config/preflight/settings.toml
( umask 077; cp ~/.config/preflight/providers.toml.example ~/.config/preflight/providers.toml )
$EDITOR ~/.config/preflight/providers.toml
$EDITOR ~/.config/preflight/settings.toml
```

`uninstall.sh` removes the config dir it is pointed at (`rm -rf "$cfg"`), so it takes any configuration of
the new bundle with it - run it before configuring, not after. `PREFLIGHT_KEEP_OLD_CONFIG=1` spares only the
*old* pre-rename directory, and the new one is removed either way. If you have already configured the new
install, copy its `settings.toml` and `providers.toml` somewhere first and put them back after.

Then re-paste the updated `AGENTS-review-snippet.md` into any repo that still calls `pral` — that command no
longer exists.

## Upgrading a bundle older than the two-file config

`preflight.toml` and `.secrets.toml` are no longer read, and the config dir did not move — so an upgrade
from the one-file layout leaves the endpoint, the model and the key in files nothing reads, and a review
refuses until `settings.toml` and `providers.toml` exist. `install.sh` names both files when it finds them;
the values to carry over are the endpoint, the model id and the token budget into `providers.toml`, and the
key into that provider's entry. `providers.toml.example` documents every key.
