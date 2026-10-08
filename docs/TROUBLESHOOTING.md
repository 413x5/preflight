# Troubleshooting

Symptoms we actually hit, and the fix. Most of these apply to any OpenAI-compatible endpoint; the
ones that are ClinePass-specific are labelled.

## `preflight review` fails with a 401 / authentication error

The key is missing or in the wrong place. It belongs in `~/.config/preflight/.secrets.toml` under
`[openai]`, as `key = "..."` (the setting is **`key`**, not `api_key`). The section is `[openai]`
because that is the OpenAI-compatible transport, not because the provider must be OpenAI:

```toml
[openai]
api_base = "https://api.cline.bot/api/v1"   # your endpoint
key      = "..."
```

Then confirm the symlink exists in the package `settings/` dir (`preflight-pr --help` re-links it).

## Using a different provider (not ClinePass)

Re-run `install.sh` with overrides — no hand-editing needed. See the README table for the full list:

```sh
PREFLIGHT_API_BASE=https://api.openai.com/v1 \
PREFLIGHT_KEY=sk-... \
PREFLIGHT_MODEL=gpt-4o \
PREFLIGHT_CUSTOM_MODEL_MAX_TOKENS=0 \
PREFLIGHT_MAX_MODEL_TOKENS=0 \
  ./install.sh
```

The two token knobs are the ones that bite: `0` means "let LiteLLM resolve the context window", which
is what you want for a model LiteLLM already knows (otherwise you override its real window with a
guess). The ClinePass streaming workaround keys on the request host, so it goes inert automatically —
you do not need to delete it.

## `preflight review` fails with "Failed to generate prediction with gpt-5.6-terra" (ClinePass)

That is the **fallback** model. The upstream default fallback is the bare OpenAI id
`gpt-5.6-terra`, which an endpoint can reject outright - ids must be in `provider/model`
form, so a bare id fails with `400 invalid model format. Expected format: modelType/model` (the
endpoint serves this model as `openai/gpt-5.6-terra`). The config here pins a working fallback
instead:

```toml
[config]
fallback_models = ["openai/cline-pass/glm-5.3-flash"]
```

Set it to your own model, or to `[]` to disable fallback (a primary-model failure then fails hard
rather than silently retrying). The id must be in the endpoint's `provider/model` form; `cline-pass/...`
works too, while the `openai/` prefix above routes through LiteLLM's OpenAI-compatible transport.

## The review reports few issues per round and the loop will not converge (the "cascade")

This has **two** causes, and only fixing the first one leaves the loop slow.

**1. A cap on how many findings are returned.** `pr_reviewer.num_max_findings` defaults to 3, so each
run reports 3 findings, the agent fixes 3 and re-runs to find 3 more. It is set to 20 here, and
`preflight.toml` also sets `pr_reviewer.extra_instructions`, which is injected into the reviewer's
system prompt and tells the model to report *everything* it is confident about rather than stopping at
the first issue. Neither setting changes what the model is *shown* - raise both and a review still only
covers the content the model received.

**2. A pruned diff.** That is the half `num_max_findings` cannot fix. When a diff exceeds the token
budget, pr-agent's default is to **prune files** and review only the first patch, so one "complete"
review silently covers a slice of the tree. The next run, against different content, surfaces findings
that were there all along - which looks identical to an agent that only found one issue. `preflight.toml`
therefore sets `enable_large_pr_chunking = true` (with `max_number_of_calls = 3`), so an oversized diff
is split, up to `max_number_of_calls` chunks are reviewed, and the findings are unioned into one review. It is inert unless the
budget actually leaves files out, so a normal diff still costs exactly one AI call.

If a review could not cover everything, it says so: the summary line contains
`coverage=PARTIAL (token budget left files out - see review.md)`, and `review.md` names the omitted
files. Treat that as "there may be more here" and do **not** read a low `issues=` count on a partial
review as "the change is nearly clean". Raise `config.max_model_tokens` / `custom_model_max_tokens` if
you want the whole diff in a single call.

## `preflight review` says the repository has no commits yet

`preflight` snapshots from `HEAD`, and an empty repo has none. Make one commit first.

## The review includes my `.preflight/` output

`preflight` adds `.preflight/` to the repo's `.git/info/exclude`. If you changed `PREFLIGHT_DIR`, the new dir is
added on the next run. If you set `PREFLIGHT_DIR` to an absolute or escaping path, the exclude is skipped
on purpose.

## Output is cut off / summaries stop around 32k tokens

`max_model_tokens` was not raised (or was set to a low value). The default here is 1,000,000 so the
packing clamp does not cut the diff; set it to `0` to disable the clamp entirely. For a model LiteLLM
already knows, `custom_model_max_tokens = 0` lets LiteLLM declare the real window instead.

## `git commit-tree` fails with a GPG error

A global `commit.gpgsign = true` was applied to the synthetic snapshot commit. `preflight` passes
`-c commit.gpgsign=false`; make sure you are running the bundled `preflight`, not a modified copy.

## `git commit` says "commit blocked: no review found for this repo"

The commit hook is doing its job: nothing has been reviewed yet. Run `preflight review`, fix what it
finds, and commit again. The hook never runs the review for you - it only verifies one that already ran.

## `git commit` says "these paths changed after the review"

You edited (or staged) content after the last review. The named paths are the ones being committed that
the reviewer never saw. Re-run `preflight review` so the review covers the current content, then commit.

This is the normal consequence of iterating: the review is bound to the exact content it covered, so any
later edit invalidates it. It is not a bug and there is no time-based expiry to wait out.

## `git commit` says "the last review did not pass"

The review ran but the gate verdict was not a pass - `preflight-gate` decides this (key issues,
security concerns, `changes_required`, or an effort over the limit). Read `.preflight/review.md`, fix the
findings, and re-review. The artifacts are left in place on a block precisely so you can read them.

If you disagree with a finding, opt out deliberately rather than defeating the hook. The recorded verdict
comes from the gate and is written **only** by `preflight review`, so to turn it into a pass you must
re-run the review with the gate's opt-out exported:

```sh
PREFLIGHT_GATE_ALLOW_ISSUES=1 preflight review
```

Running `preflight-gate` on its own only prints an exit code - it never rewrites
`.preflight/review.meta.json`, so `PREFLIGHT_GATE_ALLOW_ISSUES=1 preflight-gate` exits 0 but leaves the
sidecar on `fail` and the commit still blocked. That re-review costs another full model run; for a single
commit, `git commit --no-verify` is cheaper and leaves no trace.

Note that `PREFLIGHT_GATE_ALLOW_ISSUES` relaxes **key issues only**. Security concerns and
`merge_recommendation=changes_required` still fail the gate (see the header of `preflight-gate`), so a
review that is blocked for one of those will stay blocked no matter how it is re-run. Genuinely
disagreeing with *those* is a `--no-verify` decision, not an opt-out.

## `git commit` says "commit blocked: the preflight helper is missing"

The hook is installed but `~/.config/preflight/preflight-hook` is not. Run the bundle's `install.sh`. The
hook fails closed on purpose: passing the commit would let unreviewed work through, which is the one thing
it exists to prevent. `git commit --no-verify` bypasses it deliberately.

## The hook never blocks anything

Check, in order:

- `git config core.hooksPath` - if it is empty, the repo is still using `.git/hooks` and the committed
  `.githooks/` files are not being run. Set it to the **relative** `.githooks`.
- The branch actually contains `.githooks/pre-commit`. A branch created before the hooks were committed
  will not have them.
- `PREFLIGHT_SKIP=1` in the environment (or a shell profile) silently disables the check.
- Your last review used `PREFLIGHT_SCOPE=head`. Head-scope reviews cover already-committed content, so a
  pre-commit hook could never vouch for a commit that did not exist when it ran - the hook says so on
  stderr and allows the commit. Use the default worktree scope for enforcement.

## The hook does not run in a git worktree

An **absolute** `core.hooksPath` breaks worktrees: every worktree is pointed at the hooks directory of
whichever checkout the path names, instead of its own. Use the relative form:

```sh
git config core.hooksPath .githooks
```

## `preflight review` says "cannot tell which branch to diff against" (exit 4)

No candidate base resolved. That is deliberate rather than a fallback: diffing a branch that does not
exist is a fatal git error, and the old code reduced the resulting empty review to a bare `main` guess
that failed far from its cause. Name the base explicitly:

```sh
PREFLIGHT_BASE=origin/develop preflight review
```

If the repository has no remote at all, any local ref works (`PREFLIGHT_BASE=main`). If it does have one,
`git fetch` first - the base is resolved from refs you actually have, and a branch that only exists on the
remote is not one of them until it is fetched.

## `preflight review` leaves `.preflight/` empty and every commit is blocked

The old symptom of the failure above: pr-agent never ran, so no `review.json` or `review.meta.json` was
written, and the hook reports a missing sidecar as "no review found for this repo" - so *every* commit is
blocked, however small. Check the review command's own output for the real cause (the base, a missing key,
or a provider error) rather than the hook's message, which can only see that the artifacts are absent.
Fixed in this version: an unresolvable base now fails with exit 4 before pr-agent is invoked.

## `preflight --version` says "unknown"

The helper could not find `files/VERSION` next to itself or in the config dir (`PREFLIGHT_HOME`, default
`~/.config/preflight`). Re-run the bundle's `install.sh`. The version is used to answer "is this machine's
bundle current?", so if it matters, re-install rather than guessing from file mtimes.

## `preflight-pr` / `preflight` print "relinked secrets" on every run

Normal after a `uv tool upgrade` (the venv, and the symlink, are recreated). It is a one-time message
per upgrade; if it happens every run, the symlink target is being deleted - check
`~/.config/preflight/.secrets.toml` exists.

## `preflight review` prints nothing more and never exits

Check `.preflight/review.json` first. If it exists, is recent, and parses, the review **finished** - the
artifacts are written before pr-agent's shutdown step - and only the exit is stuck. Stop the process; the
review is usable, so continue with `preflight-gate` and carry on. `preflight review` prints its summary
line (`issues=... new=N/M ...`) only after pr-agent exits, so a hang also hides the counts: read them from
`review.json` (`review.key_issues_to_review`, `usage.total_tokens`) instead.

**Diagnosis.** Two distinct shapes have been observed on this machine, both *after* the artifacts were
written, so both are shutdown problems rather than review problems:

| Shape | Process state | Where it sits |
|---|---|---|
| waiting | `S`, ~0% CPU | `select_kqueue`/`kevent` - blocked on a socket read that never delivers |
| spinning | `R`, ~100% CPU | the asyncio loop re-entering `task_step`/`context_run` without settling |

pr-agent waits after the run for litellm's deferred callbacks to flush
(`drain_litellm_callbacks`). That wait is *supposed* to be bounded by `DEFAULT_CALLBACK_TIMEOUT_SECONDS`
(30s, overridable) but has been measured running for 4-13 minutes.

Two conditions on this machine plausibly contribute, and which dominates has **not** been isolated:
`config.litellm.force_streaming_api_base_substrings` makes the response arrive as a long-lived SSE
connection (a stalled or half-closed stream is exactly what blocks `kevent`), and `extra_instructions`
makes the model emit far more output than a default review, so there is far more callback traffic to
drain.

**Do not bound the whole command.** A timeout that cuts off a slow but valid review is the
silent-truncation failure this project works hardest to avoid, and a review is expensive enough that
losing one is worse than waiting.

**If it becomes routine**, the shutdown wait has its own budget:
`[litellm] callback_timeout_seconds` (default 30) in `~/.config/preflight/preflight.toml`. Note the
section: it is **`[litellm]`**, not `[config]` - `cli.py` reads
`get_settings().litellm.get("callback_timeout_seconds", 30)`, and a key placed under `[config]` is
silently ignored, so an operator who "sets" the wrong one keeps hanging with no feedback. The model
*request* is bounded separately by `config.ai_timeout` (default 120s), which does not cover this wait.

Lowering `callback_timeout_seconds` has **not** been confirmed to stop the hang - one attempt was
inconclusive because it used the wrong section, and no verified bound has been measured. Treat it as a
lever to test, not a known fix.
