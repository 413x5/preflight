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
run reports 3 findings, the agent fixes 3 and re-runs to find 3 more. It is set to 20 here. That setting
does not change what the model is *shown* - raise it and a review still only covers the content the model
received.

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

**A finding on documentation does not reach this point.** `preflight-gate` derives a tier from each
finding's file type and treats documentation (a `.md`/`.markdown`/`.rst`/`.adoc` file) as
**advisory**: it is printed and tagged `[advisory]`, and it does not fail the gate on its own, so a typo
in a README no longer blocks a commit by itself. Code under `docs/` and a `requirements.txt` still block,
and `merge_recommendation = changes_required` fails the gate regardless of tier. A finding on code, or one with no file attached, blocks as before. Set `PREFLIGHT_GATE_DOC_BLOCKS=1` (or `doc_blocks = true` in the gate's config file, see
`preflight-gate --help`) to make documentation findings block too.

The gate's policy - which file types count as documentation, whether they block, whether key issues are
ignored, and the effort ceiling - lives in `$PREFLIGHT_HOME/gate.toml` and an optional repo-local
`.preflight-gate.toml` that overrides it; the `PREFLIGHT_GATE_*` variables still override both.

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

- **The hook file is executable.** Git ignores a hook that is not, printing only
  `hint: The '.githooks/pre-commit' hook was ignored because it's not set as executable` - and then
  committing anyway. This is the one that looks installed: `git config core.hooksPath` is right, the file
  is committed, and the commit still goes through. Check the **committed** mode with
  `git ls-files -s .githooks/` - it must be `100755` - as well as the file on disk, because a fresh clone
  checks out whatever the index says. Fix both halves: `install -m 0755` for the file, then
  `git update-index --chmod=+x .githooks/pre-commit .githooks/post-commit` for the index. The second step
  is what covers a git running with `core.fileMode=false`, where `git add` records `100644` however the
  file was installed.
- `git config core.hooksPath` - if it is empty, the repo is still using `.git/hooks` and the committed
  `.githooks/` files are not being run. Set it to the **relative** `.githooks`.
- The branch actually contains `.githooks/pre-commit`. A branch created before the hooks were committed
  will not have them.
- `PREFLIGHT_SKIP=1` in the environment (or a shell profile) silently disables the check.
- Your last review used `PREFLIGHT_SCOPE=head`. Head-scope reviews cover already-committed content, so a
  pre-commit hook could never vouch for a commit that did not exist when it ran - the hook says so on
  stderr and allows the commit. The default `commit` scope is enforceable.

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

The helper could not find `src/VERSION` next to itself or in the config dir (`PREFLIGHT_HOME`, default
`~/.config/preflight`). Re-run the bundle's `install.sh`. The version is used to answer "is this machine's
bundle current?", so if it matters, re-install rather than guessing from file mtimes.

## `preflight-pr` / `preflight` print "relinked secrets" on every run

Normal after a `uv tool upgrade` (the venv, and the symlink, are recreated). It is a one-time message
per upgrade; if it happens every run, the symlink target is being deleted - check
`~/.config/preflight/.secrets.toml` exists.

## `preflight review` prints nothing more and never exits

**As of this version the helper handles this itself, so you should not have to.** It reports the counts
from `.preflight/review.json` as soon as the artifact exists - before waiting for pr-agent - and if
pr-agent has still not exited `PREFLIGHT_SHUTDOWN_WAIT` seconds (default 120) after writing it, the
helper says so, stops the process, and lets the run succeed. The review is complete at that point;
`preflight-gate` is what decides the verdict, and the sidecar is still recorded so the commit hook does
not then block on a review that in fact passed. Expected output:

```
preflight: issues=2 security=No risk=low merge=review carefully effort=3 tokens=71791 new=0/2 (...)
preflight: warning: pr-agent did not exit within 120s after writing .preflight/review.json; stopping it (the review is complete and usable)
```

If you see that warning, the review is fine - read `.preflight/review.md`. The warning means pr-agent's
shutdown step is still misbehaving on this machine, which is worth reporting upstream, not a reason to
re-run the review.

**Why it happens.** pr-agent waits after the run for litellm's deferred callbacks to flush
(`drain_litellm_callbacks`), and on this machine that wait has been measured running 4-13 minutes despite
its own budget. Two distinct shapes have been observed, both *after* the artifacts were written, so both
are shutdown problems rather than review problems:

| Shape | Process state | Where it sits |
|---|---|---|
| waiting | `S`, ~0% CPU | `select_kqueue`/`kevent` - blocked on a socket read that never delivers |
| spinning | `R`, ~100% CPU | the asyncio loop re-entering `task_step`/`context_run` without settling |

**What is and is not known.** Two conditions plausibly contribute and which dominates has **not** been
isolated: `config.litellm.force_streaming_api_base_substrings` makes the response arrive as a long-lived
SSE connection (a stalled or half-closed stream is exactly what blocks `kevent`), and very large
completion-token counts produce far more callback traffic to drain. Several routine reviews run during
this investigation did *not* hang at all, so this is intermittent rather than deterministic - which is
itself the reason the fix above is a bound rather than a diagnosis.

**The levers, in order of usefulness:**

1. **Bring the reasoning output down.** The hang correlates with completion volume. `[config]
   reasoning_effort` is the lever, but note it is currently inert: `config/preflight.toml.example` leaves it unset
   AND unregistered, so no effort reaches the endpoint at all (the section below explains both).
2. **`PREFLIGHT_SHUTDOWN_WAIT`** (env, default 120) bounds only the tail *after* the artifact exists. It
   is a safety net, not a fix, and it deliberately never bounds the review itself: a timeout that cut off
   a slow but valid review is the silent-truncation failure this project works hardest to avoid.
3. **`[litellm] callback_timeout_seconds`** (default 30) is the drain's own budget. Note the section: it is
   **`[litellm]`**, not `[config]` - `cli.py` reads
   `get_settings().litellm.get("callback_timeout_seconds", 30)`, and a key placed under `[config]` is
   silently ignored, so an operator who "sets" the wrong one keeps hanging with no feedback. Lowering it
   has **not** been confirmed to stop the hang; treat it as a lever to test, not a known fix. The model
   *request* is bounded separately by `config.ai_timeout` (default 120s), which does not cover this wait.

## `preflight review` is slow, and the output looks tiny for it

Check the run-details footer in `.preflight/review.md`:

```
- Tokens: 23,400 in / 8,137 out / 31,537 total
- Time cost: 34.6s
```

That "out" count is the number to watch, and it is usually far larger than the review text. A review of a
~500-line diff on this machine has reported **23,467 completion tokens in 111s**, of which only about
2,500 characters reached `review.md`. The rest was **hidden reasoning**: tokens the model spent
deliberating and then discarded, invisible in `review.json` and on the summary line. That is the extreme
end rather than the norm - the same diff has also completed in 11s / 2,126 tokens - which is exactly why
the count is worth watching: a slow review looks like a slow provider when it may be an unset reasoning
budget, and the same content can take ten times longer from one run to the next.

`[config] reasoning_effort` is the lever, and there is a trap in it:

**No `reasoning_effort` value reaches this endpoint**, which is why setting one changes nothing: the
forwarding rule, the probe that confirmed it, and the current choice are in
[`docs/architecture.md`](../architecture.md) under "Where a review's time goes". Set it only alongside
`[config] additional_reasoning_effort_models`, or it is read and silently dropped.

If you do set it, measure on a real diff, interleaved, against `new=N/M` as well as wall clock. A pin of
`low` was tried on one synthetic 525-line diff and did not survive real content - a cheaper round that
reports fewer findings just moves the cost into a later round. `docs/roadmap.md` carries the numbers and the
re-test.

**Related, and also invisible by default:** pr-agent pins `config.temperature` (upstream default `0.2`)
and its `seed` (default `-1`, which means unset). Neither is set by this bundle, so each review samples
freely and a re-review of unchanged content can legitimately word a finding differently. That matters
for the stop signal: `new=N/M` counts a reworded repeat as new. `[config] seed` accepts a positive integer
that also pins `temperature` to 0; the endpoint accepts both. It is left unset deliberately - pinning can
reduce finding coverage, and the loop's judgement step is what handles a reworded repeat - but it is the
lever to reach for if `new=` never settles.
