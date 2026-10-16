# Design

How the bundle works, and why each non-obvious decision was made.

## The goal

Review a change **before** it becomes a pull request, without a commit and without a GitHub round
trip, and hand the findings back to whatever coding agent is editing the code.

## `preflight` - reviewing the working tree

PR-Agent's plain-diff mode only sees what you hand it as a diff. To review *uncommitted* work,
`preflight` builds a throwaway snapshot of the working tree:

1. a temporary `GIT_INDEX_FILE` is pointed at a scratch file;
2. `git read-tree HEAD` seeds it from `HEAD`;
3. `git add -A` stages the working tree (tracked edits **and** untracked files) into it;
4. `git write-tree` turns it into a tree. The `worktree` scope additionally wraps that tree in a synthetic
   commit (`git commit-tree`, authored as `preflight <preflight@localhost>`, with `commit.gpgsign=false` so
   a global `gpgsign = true` cannot break it); the `commit` scope needs no commit, because a tree is
   diffable directly;
5. that tree is diffed according to `PREFLIGHT_SCOPE` - against `HEAD` for the default `commit` scope, or
   against the base for the branch scopes.

The real index, `HEAD`, and history are never touched - the scratch index is deleted on exit.

`PREFLIGHT_SCOPE` chooses what step 5 diffs against:

| Scope | Diffs | Needs a base? |
|---|---|---|
| `commit` (**default**) | `HEAD` -> the snapshot (working tree + untracked; not `git diff HEAD`, which would miss untracked files) | no |
| `worktree` | the default branch -> the snapshot (the whole branch, plus uncommitted work) | yes |
| `head` | `base...HEAD`, committed content only (no snapshot: it builds no scratch tree) | yes |

`commit` is the default because it is the case the tool exists for: reviewing a change before it is
submitted. It does no fetch and resolves no base, so it works offline and cannot fail the way base
resolution can. Reviewing commit by commit also *covers* a multi-commit branch completely - the hook
checks each commit against the tree that was reviewed for it, so the union of the per-commit reviews
covers the branch, and content cannot reach it unreviewed.

`preflight` also fetches `origin` first, so it never diffs a stale base. The base is the first of these
that resolves to a commit: `PREFLIGHT_BASE` (the explicit override), `origin/HEAD`, the remote's own
`HEAD` (`git ls-remote --symref origin HEAD`, needed because a `--single-branch` clone and a hand-added
remote never create the local `origin/HEAD` symref), then `origin/main`, `origin/master`, `main`,
`master`. If none resolves it fails with exit 4 and names the candidates rather than guessing.

The verification order is the point, not the list. A base-resolution failure must be loud, because its
silent form is indistinguishable from an unreviewed tree: an unchecked fallback produces a fatal `git
diff` and an empty artifact dir, which the hook reports as "no review found" - a block on every later
commit, with nothing pointing at the base. Hence exit 4 naming the candidates rather than a guess.
[`history.md`](history.md) records the failure this replaced.

Finally it appends `.preflight/` to the repo's `.git/info/exclude` (per-clone metadata, shared by every
worktree, never committed).

## The ClinePass streaming workaround (provider-specific)

This is the one genuinely **ClinePass-specific** piece; it is not part of the general mechanism.

ClinePass returns a **wrapped** non-streaming envelope (`{"data": ..., "success": true}`) that LiteLLM
cannot normalize. Streaming returns standard SSE, which LiteLLM parses fine. So the config forces
streaming for that host — and only that host:

```toml
[litellm]
custom_llm_provider = "openai"
force_streaming_custom_llm_provider = "openai"
force_streaming_api_base_substrings = ["api.cline.bot"]
```

The substring is matched against the request's `api_base`, so pointing at any other endpoint simply
never matches and the block is inert — nothing to remove. If you reach ClinePass through a proxy,
`PREFLIGHT_FORCE_STREAMING_HOST` (or the value in `config/preflight.toml.example`) sets the host to match.

Token budgets are needed here for a related reason: `cline-pass/*` is not in LiteLLM's model table, so
nothing declares the context window and the packing clamp cuts the diff to 32k. Hence
`custom_model_max_tokens` and `max_model_tokens` are set explicitly. For a model LiteLLM *does* know,
set both to `0` and let LiteLLM resolve the window — `0` means "look it up", not "no limit".

Any OpenAI-compatible endpoint that behaves normally needs neither the workaround nor a guessed
budget.

## Secrets

- Live in `~/.config/preflight/.secrets.toml` (`chmod 600`), under `[openai]`, as `key = "..."`.
- `install.sh` symlinks them into the PR-Agent package's `settings/` dir.
- `uv tool upgrade` recreates the venv and drops that symlink, so `preflight` and `preflight-pr` source
  `ensure-link.sh`, which re-creates it on the next run.

The key is never placed in the shell environment.

## Enforcing the review: the commit hook

The loop is only as good as remembering to run it, so the bundle ships a hook (in `src/githooks/`) that a
repo commits into its own `.githooks/` and enables with `git config core.hooksPath .githooks`.

### It verifies; it does not review

The hook **never runs `preflight review`**. It cannot: `pre-commit` runs *before* the commit exists, so a
worktree-scope review would hash content that only *becomes* the commit, and a head-scope review hashes the
*parent*. There is also no way to invoke a run and then return to grade it, and review flags change the
result without changing any hash. So the hook only checks a review that already happened.

It also never reads `preflight review`'s exit code as a verdict: in plain-diff mode `review` exits `0` even
when it finds 20 issues (it returns `1` only for a tool failure). The verdict comes from `preflight-gate`'s
rules, which `preflight` records in `review.meta.json` at review time.

### What it compares, and why content and not time

`preflight review` snapshots the **worktree** (`read-tree HEAD` + `add -A` in a temporary index) and hands
that diff to the model. It records the tree of exactly that snapshot in `review.meta.json` as
`reviewed_tree`, captured on the same temp index - so it is a true record of what the model saw, rather than
a later recomputation.

At commit time the hook computes the **staged** tree (`git write-tree`) and compares:

```sh
git diff-tree -r -M -z --diff-filter=ACMRTU --name-only "$reviewed_tree" "$staged_tree"
```

Empty output means every path being committed matches the reviewed tree. Anything printed names a path
that is being committed but was never reviewed.

The filter must be `ACMRTU`, not `AM`. With rename detection on, a moved file is neither added nor
modified, and a changed file type (regular file to symlink, say) is `T` - so an `AM`-only filter reports
**nothing** for `git mv auth.py auth_disabled.py` or for a file swapped for a symlink, and both would
commit unreviewed.

A second comparison picks up removals, because deleting reviewed code is how a guard disappears
unnoticed:

```sh
git diff-tree -r -M -z --diff-filter=D --name-only "$reviewed_tree" "$staged_tree"
```

### Why every listing uses `-z`

Without `-z`, `--name-only` **quotes** any path that needs it - wrapping it in double quotes and
backslash-escaping it - and `core.quotePath` cannot turn that off for the characters that matter (it only
controls bytes above `0x7f`). A quoted name is not a path: handing `"q\"uote.py"` back to git asks about a
file that does not exist. The deletion discriminator below does exactly that, so a reviewed tracked file
named `a"b.py`, `c\d.py` or `café.py` looked like an untracked scratch file and **its deletion committed
unreviewed**. `-z` emits the raw name NUL-terminated, and the names are then handled as bytes rather than
through the shell.

The same reasoning rules out the obvious alternative for the deletion check - `git cat-file -e "HEAD:$path"`
per candidate - for a second, independent reason: interpolating a path into a git argument is exactly the
operation that breaks on a quoted name, and a **gitlink** (submodule) is not a blob, so `cat-file -e
"HEAD:sub"` fails for it and a reviewed submodule removal counted as "not tracked at HEAD" and slipped
through unreviewed. HEAD's paths are read once instead, which lists gitlinks like any other entry:

```sh
git ls-tree -r -z HEAD   # "<mode> <type> <sha>\t<name>", split on the first tab
```

The comparison is **content-based, not time-based**, so there is no clock skew and no expiry window to
reason about: a review counts exactly while the content it covered is what is being committed.

### Why containment, and not the two obvious alternatives

Both alternatives were measured on a real repo rather than reasoned about:

| Situation | strict equality | **containment** | superset |
|---|---|---|---|
| Edit a file after review, then stage | blocked | blocked | blocked |
| Stage a brand-new, never-reviewed file | blocked | blocked | **passes - unsafe** |
| Delete a reviewed tracked file (`git rm`) | blocked | blocked | **passes - unsafe** |
| Rename a reviewed file away (`git mv`) | blocked | blocked | **passes - unsafe** |
| Swap a reviewed file for a symlink | blocked | blocked | **passes - unsafe** |
| Delete a reviewed file whose name git would quote | blocked | blocked | **passes - unsafe** |
| `git commit -a` with an untracked scratch file | **blocked - breaks a common idiom** | passes | passes |
| Commit a subset of the reviewed files | blocked | passes | passes |
| Delete, rename or retype as the review covered it | passes | passes | passes |

- **Superset** (merely require the reviewed tree to cover the staged tree) is unsafe: it lets a brand-new,
  never-reviewed file through, and equally lets reviewed content be deleted, renamed or retyped untouched
  by any review.
- **Strict equality** breaks `git commit -a`. `-a` stages tracked modifications but not untracked files,
  while the snapshot includes them, so any non-ignored scratch file or build artifact makes the trees
  differ and the commit fails. That is a common workflow, not a corner case.
- **Containment** is the rule: every path being *committed* must equal that path in the *reviewed* tree.
  Reviewed content that is not being committed is ignored.

`D` records need one refinement, and it matters. The comparison runs **reviewed -> staged**, where a `D`
means "in the reviewed tree, absent from the staged tree". Two very different things produce that:

- a **tracked file being deleted** - reviewed content going away, which is a change the reviewer never
  saw and is exactly how a guard is removed without being noticed, so it is **blocked**; and
- an **untracked scratch file** that was in the snapshot (the snapshot includes untracked files) and is
  simply not being committed - blocking that would break `git commit -a`, the very thing this rule
  exists to preserve.

The discriminator is `HEAD`: a `D` path that `HEAD` knows is tracked content genuinely being deleted; a
`D` path `HEAD` does not know was never part of the commit's history. Only the former blocks.

Note what containment does **not** permit: committing only part of a reviewed *file* (for example the first
half of its new content) is blocked, because that intermediate version was never reviewed. Deleting a whole
reviewed file is blocked too, for the same reason. A deletion or rename that is *included in the review*
passes normally - re-reviewing is the intended way to accept a removal.

### The first commit is not enforced

A repository with no commits has nothing to protect: the commit being made *is* the initial content, and
`preflight review` cannot run at all before a first commit exists (it needs `HEAD` to diff against, and
exits 3). Blocking there would deadlock adoption - the hook could never be installed before the commit
that installs it. So with no `HEAD` the hook allows the commit and says it is not enforced.

### The state it needs, and the state it deliberately does not have

`review.meta.json` inside the artifact dir is the single source of truth. `.preflight/` is **not deleted**
by the hook: leaving it in place lets a blocked review be inspected, each run refreshes it, and deletion
would buy nothing anyway - if someone acts on stale findings the content changes and the comparison fails,
and if they change nothing the recorded verdict was already `fail`.

### The run history, and why it is additive

A run destroys its predecessor's output: `preflight` removes `review.json`/`review.md` before launching
pr-agent, because phase 1 of the review wait polls for `review.json` and a stale file would make that wait
return immediately with the **previous** run's counts. That removal is load-bearing, so the run it removes
is preserved beside the fixed paths instead - each run is archived under `runs/<UTC start>-<pid>/`, with a
`run.json` (start, finish, duration, `stopped`, artifacts, gate verdict) and copies of that run's
artifacts. Every command is archived, not only `review`.

The fixed paths keep meaning "the latest run", and that is the point rather than a convenience: the commit
hook reads `.preflight/review.meta.json` and `preflight-gate` reads `.preflight/review.json`, both by name,
so a history that moved them would break the enforcement path it exists to serve. Nothing prunes the
history - an append-only directory cannot lose a run to a retention bug, and the operator can delete a
directory deliberately.

The record is written from the existing `EXIT` trap, and only a run that SUCCEEDED is archived. The
output path is removed *before* the launch for every command, not only for `review` (where the removal is
separately required, so phase 1 waits for this run's artifact): description.md / improve.md / answer.md
are written only when pr-agent actually produces them, so without the removal an agent that exits 0 having
written nothing would leave the previous run's file in place - and archiving on "the file exists" would
file it, and record it in `run.json`, as this run's output. With the path cleared, a file present at
archive time is provably this run's. That is also the limit of the guarantee, and it is worth stating:
the clearing protects against a *previous* run's file being mistaken for this one's, not against this
run's own partial output, which is left at the fixed path for inspection. So an artifact at the top level
belongs to the most recent run that wrote one, which may not be the most recent run - the history under
`runs/` is the thing that records completed runs and nothing else. The gate verdict comes from the
sidecar this same run wrote, so it too is only ever the current run's. And a run that wrote nothing
leaves no directory, because an empty one reads as a run whose artifacts went missing.

Consequently the hook is **strictly read-only**: it never touches the index, `HEAD`, the working tree, or
the artifacts. It needs no per-run state of its own.

One limitation follows from that and is worth stating plainly: the recorded verdict is **not
tamper-evident**. `review.meta.json` is an ordinary file, so anyone who can edit the working tree can edit
it too and fabricate a `pass`. The hook defends against the realistic failure mode - a review being skipped
or stale - not against a determined author who is willing to write their own sidecar. Making the verdict
trustworthy needs a party that can sign or re-derive it (server-side review state, or a check that runs
where the author has no write access), which is a different layer than this hook.

### Worktrees

A commit can only be verified once it exists, so enforcement is inherently about the commit you are
*making*. Two consequences:

- Use a **relative** `core.hooksPath`. An absolute path points every worktree at the hooks directory of
  whichever checkout it names, instead of the worktree you are in.
- `git rev-parse --git-path preflight/` resolves per worktree, but the hook does not need it: the artifact
  dir is a working-directory path, so it is already per worktree, and each worktree is reviewed and
  committed independently.

## Where a review's time goes (the reasoning budget)

A review is one model call, and most of it can be **hidden reasoning** - tokens the model deliberates with
and discards. The artifacts do not split that from the text: `review.json` carries `usage` totals and
`review.md` repeats them in its run-details footer, but neither separates reasoning from findings. The
footer's "out" count is therefore the only evidence, and it can be an order of magnitude larger than the
text that reached `review.md` - so a slow review looks like a slow provider when it may be reasoning
volume. [`measurements.md`](measurements.md) has the figures.

The lever is `[config] reasoning_effort`, and pr-agent forwards it **only** to a model its bundled litellm
metadata calls reasoning-capable. `cline-pass/*` is not in that table, so the value is read, logged, and
never sent - the escape hatch is `[config] additional_reasoning_effort_models`, naming the id explicitly,
and the two are only useful together.

`config/preflight.toml.example` sets **neither**, so the practical effect is that **no** effort reaches this endpoint
- not pr-agent's `medium` default either. A probe of the constructed request confirmed it: adding
`reasoning_effort` produced a byte-identical payload. `docs/roadmap.md` carries the open decision on this;
`docs/runbooks/troubleshooting.md` carries the measurements and the symptom.

There is deliberately **no sampling pin**, and it is inert anyway: `config.temperature` (upstream default
0.2) and `config.seed` (default -1, i.e. unset) are left alone, and this endpoint ignores `seed` even when
set. Reviews therefore sample freely - the stated limit of `new=N/M` - and `docs/roadmap.md` records the probes.

## The gate

`preflight-gate` is a small, dependency-free check over `review.json`:

| Exit | Meaning |
|---|---|
| 0 | pass |
| 1 | `merge_recommendation = changes_required` (only when the model was asked for the field - see below), or a key issue on non-documentation |
| 2 | security concerns present |
| 3 | no review found |

Findings carry no severity field from the model, so the gate derives a tier from each finding's
`relevant_file`: a documentation **file type** (`.md`, `.markdown`, `.rst`, `.adoc` by default) is
**advisory** - printed and tagged, and never fatal on its own, so a doc typo cannot block a commit
by itself; `security_concerns` still fails - and everything
else, including a finding with no file, is **blocking**. The path is normalised before it is matched
(real payloads carry a trailing newline in `relevant_file`, and a naive `endswith('.md')` would classify
those as code).

The merge rule is the one exit the shipped configuration does not exercise: `preflight-gate` reads
`review.merge_recommendation` and fails on `changes_required` whenever the field is present, but whether
it is present is pr-agent's `require_merge_recommendation`, which gates the field in the schema the model
is sent. The bundle leaves that off, so a default install reports `merge=n/a` and the rule cannot fire -
which is why the summary line prints it as `n/a` rather than as a verdict nobody made.

A finding's tier is always printed, and it is kept consistent with the verdict: with `doc_blocks` a
promoted finding prints `[blocking]`, and with `allow_issues` a waived one prints `[waived]` and is
counted, because a label that disagrees with the exit code is worse than no label. For the same
reason an empty entry anywhere in `doc_suffixes` invalidates the whole list rather than being
dropped with the rest applied - a list the writer got wrong is one value.

The rule is keyed on the **file type, not the directory**: executable code under `docs/` (a Sphinx
`conf.py`, a build script) keeps blocking, so the tier cannot be defeated by where a file sits. `.txt`
is deliberately not in the list: `requirements.txt` and `constraints.txt` are dependency manifests, and
a finding such as "this pin is vulnerable" must keep failing the gate. `.mdx` is out too, being
Markdown plus executable JSX. The remaining cost is the safe direction - an unusual prose extension is
treated as code and blocks.

**The tier is a heuristic over model output, and this is its limit.** `relevant_file` is produced by the
same model being gated, so a finding whose path is mislabeled as documentation is tagged `[advisory]` and
does not block. The gate cannot detect that on its own: it reads `review.json`, not the diff, so it has
no independent list of changed files to check the path against. The fail-safe direction bounds the blast
radius - an absent or unrecognised path blocks - so the exposure is a model that names non-documentation
as documentation, not an ordinary code finding.

## The gate's policy file

Every gate tunable has a built-in default, so the gate needs no config to run. It is read from two
optional TOML files - `$PREFLIGHT_HOME/gate.toml` (machine-wide), then `./.preflight-gate.toml` (repo,
overriding) - and the `PREFLIGHT_GATE_*` environment variables override both, so a one-off invocation
needs no edit. Keys: `doc_suffixes` (list), `doc_blocks`, `allow_issues` (bools), `max_effort` (int).

**One rule, one place.** A value that is present but invalid is *reported* and the value already in
force is *kept*. Every key names only how to validate its own value; the warning, the fallback and the
precedence are not per-key, so a new key cannot invent its own failure behaviour. That is deliberate,
because the alternative - drop the key, or fall back to a hardcoded default - silently changes
enforcement, and this class recurred once per key while each had its own setter. The environment is
applied through the same validator, so a one-off override cannot behave differently from the file value
it replaces, and validation happens per value and left to right, so a bad value in the repo-local file
cannot mask a valid one from the home file.

| Situation | What happens |
|---|---|
| A value that is present but invalid - `doc_blocks = "ture"`, `max_effort = inf`/`3.5`/`true`, a non-numeric env override, or a boolean given as a number other than the `0`/`1` mirror | warns, naming the key and the reason, and keeps the value already in force. The `0`/`1` restriction matters: "any non-zero number is true" would let `allow_issues = 2` disable the key-issue check, which is the unsafe direction |
| A suffix entry | validated against one WHITELISTED shape - a leading dot and a few name characters - rather than a list of rejected cases. A dotless `"txt"` is normalised to `.txt` (matching it raw would also match `notes.baktxt`, and the normalisation is reported); a path fragment, `.`, an empty string, or a non-string entry is invalid, and the previous list stands. The whitelist is the point: a blacklist of rejected inputs is unbounded, and every one of these was a bug found in turn |
| An unknown key | warns; a typo'd key name is how a policy looks configured while doing nothing |
| A key that is absent | nothing to say: the built-in default, or the value already in force, stands |
| A malformed (unparseable) config file | warns and falls back. A crash is a non-zero exit, which the commit hook reads as "the review did not pass" |
| A config file that is present but unreadable | warns and falls back; only an *absent* file is silent |
| A `tomllib`-less interpreter (Python < 3.11) | no file is read; a present file warns, because a hard dependency would leave the gate unable to run, and it fails closed |
| The repo-local filename | `.preflight-gate.toml`, not `.preflight/gate.toml` - pr-agent owns `.preflight/` via `--output`/`--json-output` |
| The trust boundary | a committed `.preflight-gate.toml` can relax enforcement (`allow_issues`, wider `doc_suffixes`) without the operator setting anything. That is accepted, not overlooked: the hook is a local pre-commit check on the committer's own work, and a committer who wants to skip it already has `git commit --no-verify` / `PREFLIGHT_SKIP=1`. It is not a boundary against a hostile repository, and it should not be relied on as one |

Because the tier and the effort ceiling are what decide a verdict, the config file is not cosmetic: a
policy that silently failed to load would leave a repo believing its rules were in force. `REQ-HOOK-39`
pins the precedence in both directions and the rule above, driven from a table: one row per key, with
the two wrong behaviours - dropping the key to a hardcoded default, or applying the invalid value -
chosen so that each row's exit code differs from both. A new key needs a row there rather than another
bespoke assertion.

`preflight review` runs the same check to record `gate.verdict` in `review.meta.json`, so the commit hook
and the gate can never disagree about what counts as a pass.

## Reviewer context: the `Code review` section of AGENTS.md

A reviewer cannot tell a deliberate, documented trade-off from an oversight, so it reports the
trade-off - the `.preflight-gate.toml` directory trust boundary has been raised as a finding three
times, and each time the answer was the same. The fix is to hand the reviewer the repository's own
facts, and AGENTS.md is where they go: it is the convention every other tool reads (Copilot, Cursor,
Cline, CodeRabbit, and pr-agent's own default `repo_context_files` entry), so no team maintains a
second file.

A heading whose text starts with `Code review` - any level - is extracted and sent **alone**, so a long
AGENTS.md does not follow the reviewer into the prompt. `#`-style (ATX) headings only, which is what
the convention uses, matched as CommonMark defines them: up to three leading spaces, then the hashes,
which must be followed by a space or end the line - otherwise a `#!/bin/sh` or `#hashtag` line would read
as a heading and end the section. Fences are CommonMark-correct too, so a closing fence carries only
whitespace after the run and a tagged fence inside a block stays content. A Setext heading (text
underlined with `===`) is not matched at all; in every unmatched case the whole file is sent, which is
the safe direction - but it does defeat the bound, so the limitation is stated rather than implied. The extraction skips fenced code blocks: a
shell comment at column 0, or a fenced example containing a heading, would otherwise be read as the
section boundary and silently drop every fact after it - the failure this channel exists to prevent. With no such heading the **whole file** is
sent: how much context to hand over is the repository's choice, not the harness's. `PREFLIGHT_CONTEXT_FILE`
names a different file. The summary line reports `context=AGENTS.md (Code review section)` or the plain
filename, because a review that was given the repository's facts is not the same review as one that was
not, and nothing else in the output distinguishes them.

**The mechanism, and why it is not pr-agent's own.** `repo_context_files` looks like the right feature
and is architecturally dead here: the plain-diff provider implements neither `get_repo_file_content` nor
`get_repo_context_ref`, so `build_repo_context` returns empty for a `--stdin` run. The `[artifacts]`
channel does reach `pr_reviewer`, so it carries the file. It composes into the same prompt slot
`extra_instructions` occupies - which is why `[pr_reviewer]` still does not set that key (see
docs/roadmap.md).

**Everything for it must come through the environment, not `config/preflight.toml.example`.** pr-agent calls
`inject_artifact_context()` from `cli.py` *before* `apply_repo_settings()` loads `--extra_config_url`,
so an `[artifacts]` section there is read too late: `enable`, `target_tools` and `artifact_label`
resolve from the environment and defaults first. The helper therefore
sets `ARTIFACT_PATH`, `ARTIFACT_INSTRUCTIONS` (both first-class env keys) and `ARTIFACTS__ARTIFACT_LABEL`
(dynaconf's `SECTION__KEY` form), and CI asserts that `[artifacts]` stays OUT of the config file so a
future edit cannot reintroduce a setting that looks configured and does nothing.

**Facts, not verdicts.** The file carries *facts* - architecture, accepted trade-offs, known limitations -
never verdicts: never "do not report X". Suppression is what the tier and the gate's opt-outs are for, and a
context channel that can silence findings is a trust boundary in disguise. And it is read from the
**working tree**, not the base branch, which is the opposite of what pr-agent and Codacy do with their
config files; they read from the default branch so a change cannot edit its own reviewer instructions.
That is deliberate here: this is a local pre-commit harness, the file is committed and therefore part of
the diff under review, and it is repo-controlled in exactly the way `.preflight-gate.toml` is - not a
boundary against an untrusted repository.

**What it does not fix.** Missing facts are only one cause of a wrong finding. A model that misreads
context it already has - the shell-quoting false positive, where `cat <<'EOF'` was in the diff - is a
different failure, and no amount of added context addresses it.

## The snippet is adapted, not copied

`AGENTS-review-snippet.md` is not a file to paste verbatim. It is the union of what every consuming
repository might need, and a repository that has already installed the bundle needs less than that: the
installation recipe, the hook-adoption recipe and the upgrade instructions are all worth exactly nothing
once they have been run once, while every line that stays is read by an agent on the next change. A
consuming agent that dropped the install instructions rather than pasting them was reading the file
correctly.

So each section carries a class - **required** or **setup** - and the class is what decides whether it
survives. The split is not cosmetic: it exists because the alternative is a file that grows monotonically
in every repository that adopts it, and because "which of these facts is load-bearing" was previously left
to whoever happened to be pasting.

Boundaries make the classification safe rather than merely permitted:

- **`required` means the loop is not correct without it**, and those facts are to be kept as written. A
  paraphrase of a fact about the installed helper is a fact that drifts from the helper - the same failure
  the one-fact-one-file rule exists to prevent, applied to prose the bundle does not control.
- **The hook's *behaviour* is required even where its *recipe* is setup.** Adopting `.githooks/` is a
  one-time step, but what the hook does when it blocks - containment, not equality; content, not time; a
  deletion blocked until a review covers it - is what makes a refusal explicable to whoever hits it, and
  it cannot be recovered from the recipe above it. The same holds for `core.hooksPath`: it is local config,
  so a clone does not inherit it, and a repository that dropped the step without replacing it enforces
  nothing while still looking installed.

Round economy is required for the same reason, and it is the one that looks like advice. The habits in
that section are what keep the loop's round count down, and the round count is the loop's whole cost: a
repository that dropped them keeps a correct-but-slow loop, which is the failure the completeness work
exists to prevent. Process guidance that pays for itself in rounds is not optional material.

`scripts/verify`'s `snippet` stage enforces that the section list and the classification table agree: a
section added without a row, a row naming a heading that no longer exists, or a table that classifies
everything the same way each fail the gate. The table is the whole interface, so a section it does not
mention is a section with no instruction.

## Making one review report everything (why the loop converges)

The loop is `review → fix all findings → re-review`. It is only as good as the claim that *one* review
reports *all* findings, and that claim has two independent failure modes. Both show up the same way - an
agent fixes a finding, re-runs, and gets handed a fresh one - so the two are easy to mistake for each
other, and fixing only one leaves the loop slow.

**The model returns few findings.** `pr_reviewer.num_max_findings` caps how many are returned (upstream
default 3). `config/preflight.toml.example` raises it. It does not set `pr_reviewer.extra_instructions`, so pr-agent's
reviewer prompt is sent unmodified - including its own guidance to prefer not reporting over guessing, and
its schema's "an empty list is acceptable". See `CHANGELOG.md` for why that text is gone and `docs/roadmap.md`
for the open experiment.

That cap is a prompt instruction, not a hard truncation: pr-agent does not slice the merged list (checked
against its source - the value feeds the prompt and one resolution heuristic only). It is still a bound,
so "everything" means "everything within the cap"; a diff with more findings than that would need the
number raised. The point of the setting is that the cap stops being the reason a review reports one issue
at a time.

**The model was shown only part of the diff.** This is the half `num_max_findings` cannot fix: raising a
cap on *returned* findings does nothing if the diff itself was pruned before the call. When a diff exceeds
the token budget, pr-agent prunes files and reviews the first patch, so a "complete" review covers a slice
of the tree - and a later run, against different content, surfaces findings that were there all along.

This bundle does **not** compensate by chunking. `pr_reviewer.enable_large_pr_chunking` would split the
diff, review each chunk within `max_number_of_calls`, and merge the per-chunk results
(`algo/review_merge.py` upstream) - but it is left off deliberately, so an over-budget diff costs exactly
the one AI call an ordinary diff costs and the pruning is **reported** instead of hidden. That report is
the mechanism: pr-agent appends a coverage footer whenever `remaining_files_list` is non-empty, and this is
independent of chunking (verified against v0.47.0's `pr_reviewer.py`, which emits the footer after the
chunked branch), so the footer arrives whether or not the diff was split.

The other fields the bundle leaves off are in the same family, because asking for a field changes the
schema the model is sent. `require_merge_recommendation` gates `merge_recommendation` in pr-agent's reviewer
prompt, so `preflight-gate`'s `FAIL merge_recommendation=changes_required` rule has nothing to read while it
is off - the gate's `merge=` field reports `n/a`. What the gate decides on regardless is `security_concerns`,
the key-issue count and effort.

Whatever is left uncovered after that is reported rather than hidden. pr-agent appends a coverage footer
to `review.md`, and `preflight` repeats it on the summary line as `coverage=PARTIAL ...`. That line exists
because the summary is what an agent actually reads: `issues=1` on a partial review means "the other files
were not looked at", not "the change is nearly clean". Silent partial coverage is the failure this whole
section guards against - the same shape as the base-resolution and gate failures above, where an
inability to check was indistinguishable from a pass.

The marker is reported in **every** scope. It was once gated on the branch scopes, on the reasoning that a
pending-commit diff is far below the token budget - true of ordinary changes, and false of a large one (a
generated or untracked file before the first commit). Since the bundle does not chunk, pruning is what
pr-agent does to an over-budget diff, so a commit-scope review of a slice printed a clean summary line with
nothing else saying the rest was never read. `REQ-HOOK-43` drives that path through the real helper.

Detecting that footer is harder than it looks, because the file being searched is model-generated prose
that may legitimately *discuss* coverage - and a review of this very feature did exactly that. Text
matching alone cannot win, because the model can reproduce the footer's words while explaining them; one
phrase, two independent substrings, the contiguous sentence, and searching only after the review table
each false-positived or was too weak in practice. What the marker actually keys on is the footer **as
pr-agent emits it**: a horizontal rule, the header, the sentence, and then the generated file bullets.
Reproducing all of that is a much narrower accident than quoting a sentence, and the search is
additionally restricted to the text after the review's last `</table>` (findings render inside the table;
the footer is emitted after it).

The match spans the rule and the bold header with a wildcard rather than naming pr-agent's emoji, for two
reasons: the read is deliberately lenient (so the counts survive a non-UTF-8 `review.md`), and that same
leniency rewrites an invalid emoji as U+FFFD - so requiring the emoji meant the marker could never fire on
exactly the file it was written to tolerate. Nothing non-ASCII is needed to discriminate, so nothing
non-ASCII is required.

Two honest limits. It is still text matching, so a byte-faithful copy of the emitted footer is
indistinguishable from the footer. And the structural half - searching only after the review table -
assumes plain-diff mode emits that table; if a future output shape drops it, the restriction goes inert
and the emitted-structure match carries the decision alone. Neither failure direction is acceptable, so
both are tested: a miss retires the marker and a partial review reads as complete, while a spurious
`PARTIAL` fires it on a complete one and teaches the reader to ignore it. Treat the summary line as a
pointer to the authoritative signal, which is the footer in `review.md` itself.

pr-agent's structured `remaining_files_list` is not exposed in plain-diff JSON, so there is no exact
signal to use instead. CI checks the marker against the footer literal from pr-agent's source and against
the near-miss shapes that must not fire, and `tests/run.sh` `REQ-HOOK-28` re-checks it against the
**installed** pr-agent's own footer source (skipping where the tool is absent), which is also where the
table assumption is exercised against real output.

The real budget lever is `config.max_model_tokens` / `custom_model_max_tokens`: raise those and the whole
diff fits in a single call. The bundle does not chunk the diff to reach that; see the section on the
output cap below for what it does instead.

## Which model answered, and the output cap that decides it

`config.model` is not necessarily the model that answered. pr-agent tries `config.model` first and only
then each entry in `fallback_models`, recording the winner in the run details - and the run details reach
`review.md` as prose, not as a field in `review.json` (v0.47.0's plain-diff JSON carries only `review` and
`usage`). So the bundle reads the line pr-agent writes and repeats it on the summary line:

```
preflight: issues=0 security=No risk=n/a merge=n/a effort=3 tokens=84055 model=FALLBACK (the configured model did not answer - see review.md)
```

This exists because the failure it reports is invisible in every other way. A review produced by the
fallback model looks exactly like a review produced by the configured one - `issues=0` reads as clean, the
gate passes, and nothing in the artifacts says the model this install was set up for never answered. That
is the same shape the rest of this bundle guards against: an inability to check that is indistinguishable
from a pass. It is reported rather than fatal because a fallback answer is still a review; the reader needs
to know what produced it, not to be blocked.

**Why the fallback engages at all: the output cap.** `max_output_tokens` unset means the *endpoint* chooses
the ceiling, and an endpoint that picks a low one creates a failure that looks like nothing: a reasoning
model spends the whole allowance thinking and returns truncated YAML, which does not parse, which pr-agent
treats as a failed attempt and hands to `fallback_models`. The bundle therefore sets `config.max_output_tokens`
explicitly - the measured values and the method are in [`docs/measurements.md`](measurements.md), not
repeated here. This is also why the key is asserted in the `config` stage: dropping it silently restores
the endpoint's ceiling, and the only visible symptom is that the configured model stops answering.

Note the interaction with the budget above: the output cap is *reserved* from `max_model_tokens` when the
diff is fitted, so the cap and the window have to leave room for the diff between them. Setting the cap equal to the
window would prune the diff, which is the failure the budget section exists to prevent.

## Why the loop converges: new findings, not a clean review

The loop is `review → fix → re-review`, and the section above makes one review report everything it was
*shown*. That is necessary but not sufficient: a loop can satisfy it and still never end. The failure is
not that the reviewer misses bugs - it is that a reviewer reading a diff **cannot tell a deliberate,
documented trade-off from an oversight**, and each round necessarily reviews the code, comments and docs
the previous round wrote. Re-running therefore produces findings that were already considered, arriving
as fresh issues because a single review has no memory of the last one. Chasing those is what turns the
loop into a treadmill, and it is expensive: a round is a full model call.

The fix is to make the distinction mechanical and put it on the line the agent already reads. Each run
compares its findings against the previous run's (saved before the artifacts are overwritten) and reports
how many are new:

```
preflight: issues=2 security=No risk=low merge=review carefully effort=3 tokens=71791 new=0/2 (unchanged since the previous review: judge each, do not re-fix blind)
```

`new=N/M` means N of the M findings were not in the previous review. Identity is the tuple pr-agent
itself uses to dedupe - `(relevant_file, issue_header, issue_content)`, whitespace- and case-normalised -
so a different issue in the same file is still new while the same sentence is not.

There is **no sampling pin**: `config/preflight.toml.example` sets neither `config.temperature` nor `config.seed`, so
each review samples freely - the stated limit of `new=N/M`. The prompt is fixed, which
is what makes a re-review tend to reproduce its wording, but a paraphrase is a normal outcome rather than
a bug - and it is why a reworded repeat can still read as new. `[config] seed` (a positive integer, which
also pins temperature to 0) is the lever if that instability ever needs removing; it is left unset
deliberately, because pinning can cost finding coverage, and shrinking what the loop finds is the worse
failure when the judgement step already exists to handle a repeat.

`new=0` is the stopping signal: **judge, do not re-fix**. Each finding is one of these, and only
the first is work:

| The finding is | What to do |
|---|---|
| a real defect | fix it - this is the case the loop exists for |
| already answered (a limit, trade-off or alternative the code/comment/docs already address) | write the reasoning down once if it is not recorded, and do not rewrite the design to satisfy a preference |
| wrong | say so; `preflight-gate` is the check, not agreement with the model |

Two rounds of `new=0` is the hand-off point, whatever remains, with the judgements recorded in the pull
request so a human sees the reasoning instead of the loop's history.

**The honest limits.** This is text matching over model output, so a lightly reworded repeat can still
count as new - the count is a strong hint, not a verdict, and the `new=` field is absent on a first
review or when the previous one is unreadable (judge the findings yourself then). It also compares
against the previous *run*, not against what you decided: deferring a real finding (judged wrong, or out
of time) makes it look like a repeat next round, which is why the hint says *judge*, not *done*. And the
signal is only as good as the reviewer's wording being stable - a provider whose model paraphrases freely
gets less from it, which is why the identity key is the reviewer's own rather than a fuzzy match we
invented.

A related hazard, and the reason the loop must not be driven blindly: `preflight review` has been observed
completing a review and writing its artifacts, then **never exiting** because pr-agent's post-run
callback drain blocked on a stalled socket. The artifacts are complete and correct - only the exit hangs -
so a scripted loop that waits for the process would stall forever.

`preflight` handles that itself rather than leaving it to the reader. The review runs as a background job,
and the counts are read from `review.json` as soon as it exists - *before* waiting for pr-agent - so a hang
cannot hide `issues=`/`new=`/`coverage=`, which is the signal the loop stops on. The wait is then split:
`PREFLIGHT_SHUTDOWN_WAIT` (default 120s) bounds only the tail *after* the artifact was written, and when
it expires the helper says so, stops the process, and still succeeds, because the review is complete and
`preflight-gate` is what decides the verdict.

Boundaries are deliberate here, and each replaces a specific wrong answer:

- **Both phases are bounded, and neither bound is short.** Phase 1 (`PREFLIGHT_REVIEW_WAIT`, default
  3600s) covers the review itself; phase 2 (`PREFLIGHT_SHUTDOWN_WAIT`, default 120s) covers only the tail
  after the artifacts exist. Phase 1 exists because a pr-agent that hangs *before* writing anything would
  otherwise block forever - the same hang, one phase earlier. Its default is deliberately an hour: it is a
  backstop against a hang, not a performance target, and a timeout that cut off a slow but valid review
  would be the silent-truncation failure this project avoids everywhere else.
- **A stopped hang is not a failed review - but only if it produced one.** When this code stops a process
  that had already written its artifacts, the killed status (143/137) is normalised to success and the
  sidecar is still recorded, because `preflight-gate` grades the artifact and propagating the status would
  turn a cosmetic exit problem into a blocked commit. A run stopped *without* an artifact keeps its
  non-zero status, so a caller's loop cannot read a missing review as a pass. Any status other than this
  code's own TERM/KILL is propagated unchanged, so a genuine pr-agent failure is not swallowed either.

The behaviour is guarded offline by `REQ-HOOK-32`, which drives fake `pr-agent` scripts - the review
cannot be reproduced in CI (no key, no network), and "the artifact is fine, the process is not" is
precisely the shape being guarded. It runs the helper under its own watchdog, because a regression here
hangs rather than fails and a test that stalls the suite reports nothing.

See `docs/runbooks/troubleshooting.md` for the measured symptoms, what is and is not known about the cause, and the
reasoning-budget lever that correlates with it.
