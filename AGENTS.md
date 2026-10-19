# AGENTS.md

Instructions for AI agents working **in this repository**. The bundle's *product* is itself an agent
instruction block (`AGENTS-review-snippet.md`) - that file tells an agent how to review code in *another*
repo. This file is about changing this repo. Do not confuse the two.

## What this repo is

`preflight` is a deployable, machine-local [PR-Agent](https://github.com/The-PR-Agent/pr-agent) review setup: a
working-tree review loop plus a commit hook that makes the loop impossible to skip. It is **shell plus git
hooks** - no compiled code, no package manager, no framework. The artifacts that ship are `install.sh`,
`uninstall.sh` and the files under `src/`; everything else is docs and tests. There is no "source" and
"build" step: the scripts in `src/` *are* the product.

Published at <https://github.com/413x5/preflight>. Default branch `main`; work happens on feature branches
with pull requests. CI (`.github/workflows/ci.yml`) runs on every pull request and on pushes to `main`.
(The repo is named `pr-agent` in some local tooling for historical reasons, but the GitHub repo is
`preflight` - do not "fix" one to match the other.)

## The one rule that matters most

**No endpoint is a default, and none is named in the code.** Any OpenAI-compatible endpoint must work, and
none of it is known to this repository: the endpoint, the model id and the credential are set in
`$PREFLIGHT_HOME/providers.toml` *after* the install. Never hard-code a provider, a model id, a host or a
token window into a mechanism or a test. The shipped templates carry obvious placeholders
(`https://api.example.com/v1`, `your-model-id`), and a test fixture names its own provider so no real
endpoint's name reaches the assertions. The CI and the tests must never require a paid key or the network.

## One review must report everything, and the loop must be able to end

The product's central promise is that the loop converges: review once, fix **all** the findings, re-review.
If a review reports one finding and the next run hands you another, the bundle has failed at the one thing
it exists to do. There are **three** independent ways to break that promise, and they look identical from
the outside - fix one and the loop is still slow.

1. **What the model reports.** `pr_reviewer.num_max_findings` (upstream default 3, raised here). The
   bundle does not set `pr_reviewer.extra_instructions`: pr-agent's own reviewer prompt already carries
   its severity guidance, and our additions argued against it. See `CHANGELOG.md` and `docs/roadmap.md`.
2. **What the model was shown.** When a diff exceeds the token budget, pr-agent prunes files and reviews
   the first patch - so a "complete" review can cover a slice of the tree. **This is the one that is easy
   to miss**, because every finding in a partial review is a real finding; the missing coverage is
   invisible. The bundle does not chunk to close it; it **reports** it, which is why `coverage=PARTIAL`
   must keep working. Mechanism and the keys left off deliberately: `docs/architecture.md`.
3. **That the findings are *new*.** A reviewer cannot distinguish a deliberate, documented trade-off from
   an oversight, and each round reviews the code and comments the previous round wrote - so re-running
   keeps raising concerns already answered, at a full model call per round. `preflight-code` reports
   `new=N/M` on the summary line for exactly this reason, and `new=0` is the stopping signal.

`config/settings.toml.example` sets the completeness key it keeps, and the `config` stage asserts that and
the absence of the keys left off (so adding one means adding its assertion too). Do not weaken any of it to save tokens:
a partial review is what turns a two-round loop into an unbounded one, and silent partial coverage has the
same shape as the other failures this repo guards against - an inability to check that is indistinguishable
from a pass.

`new=` is the counterweight, and it must stay honest: it compares against the previous *run*, not against
what the agent decided, so it never claims a finding is resolved - only that it is unchanged. Do not
"improve" it by suppressing repeats or by treating `new=0` as a pass; the gate decides pass, and the loop
stops on judgement, not on silence.

"Everything" is bounded, and the docs should say so rather than overclaim. The finding cap is a prompt
instruction, not a hard truncation, but it is still a ceiling; the coverage line is a text heuristic, so a
byte-faithful reproduction of pr-agent's footer is indistinguishable from the footer itself. Do not let the
marketing get ahead of that: the claim is "one review reports every finding it was *shown*", not "a review
can never miss anything".

## Layout

| Path | What it is |
|---|---|
| `install.sh`, `uninstall.sh` | Deploy/remove the setup on a machine. `bash`, idempotent |
| `src/preflight-code` | `preflight-code` - reviews the working tree; also dispatches `preflight-code hook` |
| `src/preflight-pr`, `src/preflight-gate` | Hosted/PR mode; the machine-checkable verdict |
| `src/preflight-hook` | The commit-time verifier - **see below before touching it** |
| `src/githooks/` | The example hooks a *consuming* repo copies into its own `.githooks/` |
| `src/VERSION` | The bundle version, single source of truth. `preflight-code --version` and `install.sh` read it; CI fails if it, the `CHANGELOG` heading, and `--version` disagree |
| `config/` | The reference files `install.sh` writes into `$PREFLIGHT_HOME`: `settings.toml.example` (the `[selection]` that names the profiles, plus every pr-agent setting the review can be told) and `providers.toml.example` (placeholder endpoint and key, and the model profiles that use them, 600-mode). The user copies them to `settings.toml`/`providers.toml`; **install.sh creates neither** |
| `scripts/verify` | The gate: every check, cheapest first, in one command. CI runs this |
| `AGENTS-review-snippet.md` | The block pasted into a *consumer* repo's `AGENTS.md`. **Adapted, not copied** - every section is classified `required` or `setup`, and the `snippet` stage fails if the sections and that table disagree |
| `tests/run.sh`, `tests/sample/` | Integration tests for the hook; the fixture they build on |
| `PLAYBOOK.md` | The development standard this repo follows - the gate, the docs doctrine, the records |
| `docs/README.md` | The index: one line per document in the docs tree |
| `docs/architecture.md` | How the bundle works, and why each non-obvious decision was made |
| `docs/runbooks/troubleshooting.md` | A symptom, its cause, its fix |
| `docs/adr/` | Decision records: why, what it beat, what still holds. `0000-template.md` is the shape |
| `docs/roadmap.md` | What is left, and how to take an item |
| `docs/history.md` | The narrative of what changed and what it replaced |
| `docs/measurements.md` | The dated numbers, with the reason each moved |
| `LICENSE`, `SECURITY.md` | MIT; the trust model and how to report privately |

The human on-ramp - setup, and how to propose a change - is [`CONTRIBUTING.md`](CONTRIBUTING.md). It points
here for the rules rather than restating them.

## `src/preflight-hook` and `src/githooks/post-commit` are the sharp edges

`preflight-hook` is a ~160-line POSIX `sh` script and the highest-risk file here: it is the only thing that
makes the review loop enforceable, and its whole job is to be *hard to bypass*. `src/githooks/post-commit`
is the *opposite* kind of sharp edge - it cannot block anything, so a bug in it is silent by construction.
Read [`docs/architecture.md`](docs/architecture.md) (the containment section) and
[`tests/README.md`](tests/README.md) before editing either. Invariants that must survive any change:

- **It verifies; it never triggers.** It never runs a review, never stages anything, and never writes to
  the index, `HEAD`, the working tree, or `.preflight/`. It is strictly read-only.
- **It fails closed.** Any inability to check - missing `python3`, missing helper, unreadable sidecar,
  comparison that cannot run - must **block**, because "no output" is indistinguishable from "no
  differences" and would pass an unverified commit.
- **The advisory fails loud, not silent.** The twin rule for `post-commit`: it cannot block, so its failure
  mode is *saying nothing*. An unreadable sidecar (missing `python3`, malformed JSON, no `scope` key) must
  warn, because silence there is indistinguishable from "verified". An *absent* sidecar is the one case
  that stays quiet - `pre-commit` refuses a missing review first (bar a repository's first commit, allowed
  unenforced by design). The two hooks reading the same sidecar with opposite stances is deliberate, not an
  inconsistency: one guards the commit, the other guards the *belief* that the commit was guarded.
- **The binding is content, not time.** A review counts exactly while the content it covered is what is
  committed. Never add a clock, an expiry, or a check that the recorded `HEAD` still equals `HEAD` -
  committing moves `HEAD`, so that would invalidate the sidecar after every commit for no gain.
- **The rule is *containment*, not equality.** Every path being committed must match the reviewed tree;
  reviewed content that is *not* being committed is ignored, which is what keeps `git commit -a` working.
  Strict equality breaks `commit -a`; a superset check lets unreviewed content through. Both were measured,
  not reasoned about - the comparison table in `docs/architecture.md` is empirical.
- **Path names are handled as raw bytes** (`git … -z`, split on NUL), never interpolated into a git
  argument. `--name-only` without `-z` *quotes* awkward names, and a quoted name is not a path.
- **The bypasses are load-bearing knowledge.** Unreviewed deletions, renames, symlink typechanges,
  `git rm --cached`, git-quoted path names and gitlink removals have each been a real escape at some point.
  `tests/README.md` maps every one to the case that guards it - do not weaken those cases. A new escape is
  a new question, not only a new case: ask which other operations reach the same gap.

### If you change the hook's behaviour, prove it

The test suite is not decoration; it is the only defence against this file silently regressing into
something that passes everything. For any behavioural change:

1. Add or update the case in `tests/run.sh` and give it the next `REQ-HOOK-nn`.
2. Add it to the `run_group` list **and** to the tables in `tests/README.md`.
3. **Classify it** in the `sensitive` or `insensitive` list beside `case_selfcheck`. An unclassified case
   fails `./tests/run.sh selfcheck`; so does a case marked sensitive that passes with the hook neutered.
   This is what stops a case from claiming to test enforcement without actually testing it.
4. **Prove the case can fail** in each direction - see "Assertions must be falsifiable" below.
5. If the change is a fix rather than a feature, add it to the containment table in `docs/architecture.md`.

## Assertions must be falsifiable

**Every test case and every guard, not only the hook's.** A check that cannot fail is the same false result
as no check, and worse than no check because it is *counted*. This section is deliberately not filed under
one file's heading: keying a rule to a file makes it invisible to every change of the same kind elsewhere,
which is how the case below happened.

The directions are different properties:

1. **Revert the fix; the case must fail.** That the feature is needed.
2. **Falsify what the assertion asserts; the case must fail.** That the assertion is live.

Direction 1 alone is not enough. The session that added the run history ran mutations of direction 1
- all correct, each one watched failing - while assertions in that same new case could not fail, and
the suite was green throughout (the classified counts are in [`docs/measurements.md`](docs/measurements.md)).
Run direction 2 on the assertion you just wrote, *before* trusting it - and on the others in the same case,
because they share a fixture and a branch, so one of them being unable to fail is evidence about its
neighbours.

The shapes, each of which passed a green `./scripts/verify` in this repository:

- **A branch that cannot run.** A Python block that `print`ed its findings and exited 0, under
  `if python3 ...; then :; else <fail>; fi` - the `else` was unreachable. Forged problems still
  "passed". `sys.exit` is what makes the status non-zero.
- **A fixture aimed at the wrong path.** A read-only *grandparent* directory while the code created and
  wrote in a writable *child*, so the intended failure was never reached and the case exited through an
  unrelated branch.
- **A comparison over constant bytes.** `cmp` between an archived artifact and a fixture that wrote
  identical output on every run, so a genuine overwrite compared equal.
- **Selection by position where the order is not chronological.** `ls | tail -1` over `<UTC second>-<pid>`:
  the pid is unpadded, so `…-1000` sorts before `…-999` and "the last one" is not the newest.

Write the failing state deliberately, watch the case fail, then restore. If you cannot make it fail, the
check is not testing what its name says; fix the check or delete it rather than keep false coverage.

## Commands

**The gate is one command: `./scripts/verify`.** It composes every check below in cost order, cheapest
first, and CI calls it rather than re-listing the steps - so a change cannot pass one and fail the other.
A green local run means a green CI run. `./scripts/verify` is what "done" means; the individual commands
below exist to run one stage while working, not to replace it.

```sh
./scripts/verify              # the gate: everything, cheapest first
./scripts/verify --list       # the stage names
./scripts/verify syntax       # one stage, for the inner loop
./scripts/verify hooktests    # the offline hook cases - seconds, no network, no key. Run this constantly.
./scripts/verify hooktests selfcheck   # the suite, then the suite against a neutered hook

./tests/run.sh e2e            # the one live case: needs the installed helpers and a real key, and skips
                              # itself without them. NOT in CI
```

`selfcheck` exists because a green suite is **not** proof the hook enforces: many of the offline cases
take the hook (or the helper) neutered without complaint - they assert acceptance (`commit -a`, a reviewed
deletion, a reviewed rename), test a deliberate bypass, or exercise a different file such as the example
hooks and the review helper, so they never ask the hook to refuse anything. (Some of them skip instead of
passing wherever pr-agent is not installed, which is the case in CI.) The selfcheck runs the whole suite
against a neutered hook and requires exactly the enforcement-sensitive cases to fail. It also **requires
every case to be classified**, so a new case must be declared sensitive or insensitive, or the selfcheck
fails.

| Stage | What it checks |
|---|---|
| `tools` | `git`, `python3`, `awk`, `sed`, `mktemp` are present, and `python3` can `import tomllib` (3.11+) |
| `syntax` | Every script parses - `bash -n` for the helpers and installer, `sh -n` for the hooks and tests - and no editor or backup leftover sits beside them |
| `install` | `install.sh` deploys into a throwaway prefix, is idempotent, and never clobbers `settings.toml` or `providers.toml` |
| `config` | The generated config parses, the completeness keys are set and the keys left off are absent, and the gate template is inert |
| `models` | The `settings.toml`/`providers.toml` templates are inert, the renderer derives the endpoint, the key and the transport pin together, and it refuses a chain spanning two providers |
| `envhelp` | Every `PREFLIGHT_*` the helper reads is in `--help`, no `--help` entry is unread, an internal variable is not advertised as a setting, and the shared resolver's default caller name is the installed command |
| `version` | `src/VERSION`, the CHANGELOG's released heading for it, and `--version` agree |
| `gateshapes` | `preflight-gate` survives the JSON shapes the model really produces |
| `coverage` | The coverage marker matches pr-agent's footer and ignores prose |
| `snippet` | Every section of `AGENTS-review-snippet.md` is classified required or setup, so the file keeps telling a consumer what it may drop |
| `hooktests` | The commit-hook integration suite (offline cases) |
| `selfcheck` | That suite re-run against a neutered hook |

These move with the gate and are easy to forget: **CI must not grow a step** that re-lists a check -
it belongs in `scripts/verify`, and CI names a **group** (`./scripts/verify fast`) rather than the stages
in it, so a stage added to the script is picked up there without editing the workflow; and **`actionlint`
is the one check that needs a binary** the gate does
not require, so CI runs it in its own job and `scripts/verify` runs it only when it is installed (a full
run says so when it is not).

Pass **one** file per `-n` invocation. `bash -n a.sh b.sh` only parses `a.sh` - the second name becomes a
positional parameter, so a syntax error in `b.sh` is silently not reported.

`python3` is what the hook, the tests and the gate run on. **Do not `pip install` anything**: nothing here
needs a dependency, and a system interpreter commonly refuses one (PEP 668) anyway. YAML can be parsed
with Ruby's built-in Psych if you need to inspect config.

## Never do these

- **Never commit a secret.** Only the `config/*.toml.example` templates are committed - settings has no
  credential field, and the providers example carries a placeholder endpoint and an empty `key`. Real keys
  live in `$PREFLIGHT_HOME/providers.toml` (`~/.config/preflight` by default, chmod 600), never in the
  environment.
- **Never set `core.hooksPath` in this repository.** It is clone-wide: setting it here would affect this
  checkout *and* every worktree of this clone, and would start enforcing a hook against this repo's own
  commits. Do all hook testing in a `mktemp -d` repository.
- **Never introduce an absolute `core.hooksPath`** in anything you write, including docs and examples. It
  breaks git worktrees - each worktree would run another checkout's hooks dir. Relative `.githooks` only.
- **Never reintroduce the old names.** `pra`/`pral`/`pral-gate` and `~/.config/pr-agent/` are the former
  names; `pr-agent` means only the upstream tool. The same applies to the bare `preflight` command: it was
  renamed to `preflight-code` because an unrelated project ships a binary of that name, so nothing here
  installs, aliases or prints it as a command. `preflight-gate`, `preflight-pr`, `preflight-hook`, the
  `PREFLIGHT_*` variables and `~/.config/preflight` keep their names - the *project* is still `preflight`.
- **Never make the doc examples require a paid key or the network**, and never add a test that does.
- **Never hand-edit a `.preflight/review.meta.json`** in a test to fake the *real* review path. The suite
  deliberately simulates a review by writing a sidecar (`review_here`); that is a fixture, not a shortcut
  for production code. `preflight-code review` is the only thing that may write it.
- **Never let base resolution silently guess.** The base is resolved by *verifying* each candidate
  (`PREFLIGHT_BASE`, `origin/HEAD`, `ls-remote --symref origin HEAD`, then `origin/main|master`, `main|master`)
  and failing with exit 4 when none resolves. An unchecked fallback to a bare `main` would produce a fatal
  `git diff` and an **empty** artifact dir, which the hook reports as "no review found" - turning a base
  problem into an unexplainable block on every commit.
- **Never widen a rendered config's endpoint or transport by inference.** `scripts/settings-render.sh` derives
  `litellm.custom_llm_provider` AND the endpoint section from ONE provider entry, and its `TRANSPORTS` table is
  asserted against pr-agent's own `PROVIDER_SETTING_PATHS` by the `models` stage. Both halves are load-bearing:
  a pin that disagrees with the endpoint is resolved *silently* by LiteLLM, so the request goes to the pinned
  provider's host carrying that provider's key, with no error. Do not "fall back" to the model id's prefix, to
  a pin, or to another section's `api_base`, and do not write a section pr-agent reads nothing
  from - refuse by name instead. The rendered file is the config pr-agent receives, built from `settings.toml`, so a
  setting the render drops is a setting the run loses; and it holds a credential, so it stays 600-mode, at
  `$PREFLIGHT_HOME/.pragent.settings.<pid>.toml`, outside the repository (a review stages the working tree
  with `git add -A`). One file per run, so concurrent runs cannot read each other's key; each run deletes
  its own, and a copy of the last is left at `.pragent.settings.toml` for inspection.
- **Never make the `post-commit` advisory exit 0 on a sidecar it cannot read.** It is the only thing that
  reports silent non-enforcement, so a malformed sidecar or a missing `python3` must warn. An *absent*
  sidecar stays quiet (no review has run, and `pre-commit` refuses first).

## A trap in this repo's own shell

macOS ships **bash 3.2**, and its parser mis-handles a heredoc that sits **inside `$( )`** when the body
contains an **apostrophe**: it treats the quote as opening a string and reports `unexpected EOF while
looking for matching '`, pointing at a line far from the cause. Sites like that live in `src/preflight-code`,
`src/preflight-hook`, `src/githooks/post-commit` and `tests/run.sh`.

So: an apostrophe is fine in a normal heredoc, and fine in a comment *outside* one - but not in the body
of a `<<'PY'` that is inside a command substitution. Write `the hashes` rather than `the #'s`. The syntax
check catches it (`sh -n` / `bash -n` per file), which is also how CI would.

## Do not assume the bundle is installed

`install.sh` is what puts the helpers on `PATH` and writes the config, so a clone is not an installation.
Ask which state the machine is in rather than reaching for either:

```sh
command -v preflight-code   # a path means installed; no output means a bare clone
```

- **Bare clone.** The offline half works with no key and no network: `./scripts/verify` is the whole gate,
  and `tests/run.sh` drives the shipped hook (`src/preflight-hook`, overridable with `PREFLIGHT_TEST_HOOK`)
  against throwaway repositories. A *real* review is the one thing that cannot run - it needs the installed
  helpers, pr-agent and an API key - so `./tests/run.sh e2e` skips itself instead of failing.
- **Installed.** The live case runs, and a scratch repo can go through a real review.

`python3` 3.11 or newer is needed to run the gate, because it parses TOML with `tomllib`, which entered the
standard library there; `tools` reports a too-old interpreter rather than letting a later stage die on an
import error. What ships needs less - the hook, the installer and `preflight-code` import nothing outside the
standard library, so they run on an interpreter the gate refuses, and only `preflight-gate` degrades (its
row in [`docs/architecture.md`](docs/architecture.md) says how). The `python3` macOS ships is below the
floor, so a machine needs another one on `PATH`.

A scratch repo, with the install in place:

```sh
R="$(mktemp -d)"; cd "$R"; git init -q -b main .
printf 'def add(a, b):\n    return a + b\n' > util.py
git add -A
git -c commit.gpgsign=false commit -q --no-verify -m init
mkdir -p .githooks && install -m 0755 "${PREFLIGHT_HOME:-$HOME/.config/preflight}"/githooks/* .githooks/
git add .githooks
git update-index --chmod=+x .githooks/pre-commit .githooks/post-commit   # git IGNORES a non-executable hook
git config core.hooksPath .githooks
preflight-code review && preflight-gate     # expect a pass, then the commit is accepted
```

Without an install that last line cannot run - there is no `preflight-code` to review with - so copy the hooks
from `src/githooks/` instead of the config dir, and commit with the checkout's helper, which is the one a
clone modifies:

```sh
CHECKOUT=/path/to/the/preflight/checkout   # set this to your clone
mkdir -p .githooks && install -m 0755 "$CHECKOUT/src/githooks/"* .githooks/
git add .githooks && git update-index --chmod=+x .githooks/pre-commit .githooks/post-commit
git config core.hooksPath .githooks
PREFLIGHT_HOOK="$CHECKOUT/src/preflight-hook" git -c commit.gpgsign=false commit --allow-empty -m should-block
```

The `git add -A` before the first commit is required: `preflight-code review` exits 3 on a repo with no commits,
and without it the single file stays untracked. The first commit passes unreviewed by design, because the
hook cannot be installed before the commit that installs it. `core.hooksPath` is local to the clone you set
it in, so a `mktemp -d` repository is the only thing it affects; never set it in a preflight checkout,
because it would then guard that checkout's own commits.

A review is a full model call, and what a run costs moves - it is measured in `docs/measurements.md` rather
than repeated here. Do not run one in a loop.

Note when testing the *gate*: `PREFLIGHT_GATE_ALLOW_ISSUES=1` relaxes key issues only.
`security_concerns` still fails, regardless of the opt-out. The gate decides on nothing else: effort and
`risk_level` are printed by it and `merge_recommendation` by `preflight-code`, never enforced - `docs/architecture.md`
covers why.

## Before you start: check docs/roadmap.md for handoff state

`docs/roadmap.md` is the working document, and its **Now** and **Next** sections carry anything a previous
session left unfinished - including work that is *implemented but uncommitted* in the working tree, which
is invisible from `git log`. Read **Now** first. **Next** has two groups: **Experiments** (cheap,
reversible, each phrased as a question with the result that would settle it) and **Open questions on
shipped work** (`[x]` items whose still-open paragraph is the work). A second section, "What upstream's
own docs say", records what pr-agent's shipped `_help_docs/` says about models and settings, so it is not
re-derived.

The rules it follows, worth keeping: an experiment must state **what would falsify it**, and a lever that
has been tested and rejected stays in the file **with its result** - re-testing `seed` because nobody
recorded that it is inert on this endpoint would waste another hour.

Do not assume a clean tree means a clean slate, and do not assume the last commit describes the current
state. `git status` is the first thing to check in this repo.

**The roadmap holds to-dos only.** There is no "Done" section: a finished item is deleted from
`docs/roadmap.md` and its reasoning recorded in `CHANGELOG.md`, which is the file that answers "what changed
and why". The one exception is a `[x]` item under **Open questions on shipped work**, where the tick marks
the *shipping* as settled and the paragraph beneath it as still open - that entry stays until the question
is answered. Committing work is not a roadmap item; it is a routine step, and the roadmap records decisions
and unresolved questions, not a task list for a single session.

## Working on docs

The docs are part of the product, and they drift. Before claiming something works, run it. If you change
behaviour, grep for every place that describes it: `README.md`, `AGENTS-review-snippet.md`, `docs/roadmap.md`,
`CHANGELOG.md`, `docs/architecture.md`, `docs/runbooks/troubleshooting.md`, `tests/README.md`, `CONTRIBUTING.md`. Case
counts, the requirement table, and the containment table go stale fastest.

**A change to `AGENTS-review-snippet.md` is a change to a consumer's instruction file.** Adding, removing
or renaming a section means adding, removing or renaming its row in the classification table at the top of
the file - the `snippet` stage fails otherwise, so the table cannot drift from the sections. The class is
the interface: `required` facts are the ones a consumer must keep as written, so promoting something to it
means arguing the loop is incorrect without it, and demoting something out of it means a consumer may drop
it and still be correct.

## Never write a number into a sentence

**A figure in prose is a copy that nothing checks.** Something else already owns the fact — the run, the
code, the artifact, the dated record — and the sentence is the copy with no reason to stay right. Every
shape of it is one defect: **what a run printed** (a check count, a suite duration, an `N of M` figure);
**a count of the text's own list** ("three habits", "the two boundaries"); **a measurement of an artifact**
(a file's line count, a comment ratio, a size). It rots silently, and a reader who catches it cannot tell
whether the text or the thing it describes moved.

State the **shape** instead ("every section passed", "these habits"), quote the run's own output in a code
fence so it reads as one transcript rather than a claim about the project, or point at the dated record.
The test is *who notices when it is wrong*: if the answer is "a reader, eventually", the number does not
belong in the sentence.

**A number that IS the interface stays.** A knob's value, a timeout, a port, an exit code, a version, a
format's offsets - changing one means changing the code, and the code is where it is checked. This applies
wherever prose lives (a doc, a comment, a test's message, a template, a commit body), so a number repeated
into a second document is the same defect as one written twice in one file. The full form is in
[`PLAYBOOK.md`](PLAYBOOK.md) §6.

The numbers that legitimately appear in this file are knobs and the dated measurements that
[`docs/measurements.md`](docs/measurements.md) owns; a suite's own output belongs in a code fence or in
the run, never in a sentence.

## Comments in code files state current invariants, nothing else

A comment in `src/*` or `*.toml` explains the code as it **is**: the invariant that a change would
break, and why a value is that value rather than the obvious alternative. It does not narrate history
("used to", "previously", "historically", "no longer", "was reverted"), restate the diff, or retell the
decision journey that produced the line.

- **The test: if deleting the comment would not change a reader's next action, delete it.**
- History, measurements and reverted experiments belong in `CHANGELOG.md`; design rationale belongs in
  `docs/architecture.md`; operator symptoms belong in `docs/runbooks/troubleshooting.md`.
- **An unverifiable comment is a liability, not documentation.** Prose is not executed, so a comment that
  contradicts the code beside it survives indefinitely. A documentation pass took `config/settings.toml.example` to
  mostly comments - the ratio is in [`docs/measurements.md`](docs/measurements.md), which owns it - and left
  a `post-commit` comment instructing users to "run `preflight-code review` with the default worktree scope" - a
  scope that had not been the default since the `commit` scope landed. Trimming that comment is what exposed
  the matching bug (the advisory warned on every default-scope commit), which no test had covered.

## Each fact lives in exactly one file, chosen by audience

Adding a finding to every file that could mention it is the same failure as writing a narrative comment:
it multiplies the surface a reviewer must check, and the copies drift apart. Each document has one
audience, and a fact belongs in the one that audience reads:

| File | Audience and purpose | A fact belongs here when... |
|---|---|---|
| `README.md` | A new user | it is needed to install, run, or understand what this is |
| `docs/architecture.md` | Someone asking "why is it built this way" | it is a mechanism or the reason a decision was made |
| `docs/runbooks/troubleshooting.md` | An operator with a symptom | it is a symptom → cause → fix |
| `docs/adr/` | Someone questioning a rule | it is a decision, its alternatives, or its cost |
| `AGENTS.md` | An agent changing this repo | it is a rule, trap, or invariant for editing |
| `docs/roadmap.md` | A future session picking up work | it is *not done yet*, or an open decision |
| `CHANGELOG.md` | Someone asking "what changed" | it is history: what changed and why it changed |
| `docs/history.md` | Someone reconstructing the arc | it is the long-form narrative of what replaced what |
| `docs/measurements.md` | Anyone about to quote a count | it is a dated number, and the reason it moved |
| `tests/README.md` | Someone auditing coverage | it is which case guards which requirement |
| `src/*`, `*.toml` | Someone reading the code | it is the current invariant (see above) |

**When a second file needs the same fact, it gets a pointer, not a copy**: one sentence naming the file
that holds it. Measured cost of not doing this: the `reasoning_effort` forwarding rule ended up stated in
full in several files, and the copies disagreed - some still claimed "pr-agent's `medium` default
applies" after a probe showed no effort is sent at all. The rule is what makes a fact cheap to correct.
The exception is a habit an agent must hold *while editing*: that one is stated where the editing
happens rather than only where the rule is filed, because a link is read after the change, not during it.

**Settle the behaviour before you describe it.** A document states what the code *does*, never what it is
meant to do. Prose written ahead of its code is a guess about behaviour the code has not yet settled, and
when the code then changes the document is not part of that change - so the text is left asserting the old
shape. This is the ordering half of the rule above, and it is where the point-one-two rule earns its keep:
a fact in one file is corrected by the change that settles it, while a fact copied into five is corrected
in at most one of them.

When behaviour changes, grep for the *opposite* phrasing of the old claim as well as the new one - "is
kept" as well as "is not kept" - because a copy that inverts the meaning will not match a search for the
new wording.

## Keep each round's change small, or the loop will not converge

This repo's own loop is the thing being built, so it is worth knowing how it fails to end; the ones handled
above are what the model reports and what it was shown, and the ones handled here are **how much you change
between rounds** and a round that **fixes the instance and leaves the rule.**

A round reports one defect. Fix the code: usually a few lines. The temptation is to also rewrite the
comments around it, add a docs paragraph, add a changelog bullet, and add a row to the mutation table.
That diff is mostly *claims*, which are the part most likely to be wrong, because prose written to describe
a fix is not verified the way the fix is - and the next round reviews all of it. Correcting prose adds more
prose, which is a loop with no stopping condition. One change here measured
**more lines of comment about a change than lines of the change**, across several rounds whose later
findings were almost entirely about the writing - the figures are in
[`docs/measurements.md`](docs/measurements.md), which owns them.

So:

- **Change the code the finding requires, and little else.** Do not rewrite comments, docs or the changelog
  unless the finding is *about* those files. That bounds the *prose*, not the fix: reaching the rule behind
  the finding (below) is often a larger diff than satisfying the finding as written, and it is the smaller
  change over the loop it ends.
- **Do not add a sentence saying you fixed something.** The diff is the record. A comment narrating a fix
  duplicates the diff and can only be checked against it, which spends a round to learn nothing.
- **Code files carry current invariants only.** History and design rationale go to `CHANGELOG.md` and
  `docs/architecture.md`; see "Comments in code files state current invariants" above.
- **Do not write a claim you have not verified.** "This is guarded by REQ-HOOK-nn" and "every mutation is
  listed" are factual assertions that a reviewer will check. If you did not run the mutation, the claim is
  usually wrong in the direction of overclaiming - and a wrong claim about coverage is the same failure this
  repo guards against everywhere else, just applied to its own documentation.
- **Delete a claim rather than qualify it.** When a review says a comment overstates, the fix is normally to
  remove the sentence, not to add a caveat. The caveats are the surface the next round works on.
- **`new=0` means judge, and usually means change nothing.** Two rounds at `new=0` is the hand-off point.
  A clean round is not a licence to add prose: a session here saw `new=0` at round four and then
  documented the feature anyway, which added fresh claims for the next round to check and reset a
  converged signal. Fix the code; when the loop is clean, stop.
- **The mutation-table rule is not a formality.** Every row in `tests/README.md` must have been *run*: apply
  the mutation, watch the case fail, revert, watch it pass. A row claiming coverage that no case provides is
  worse than no row, because it retires the requirement without testing it.
- **Answer the class, not the instance.** Satisfying a finding as written is how the same finding returns
  wearing a different name: the reviewer reports what it saw, so the rest of the class is next round's
  work, at a full review apiece. A finding is one member of a class the code did not exclude, so before
  editing, ask **what class is this, and what would make every member of it impossible**. A completeness
  finding (_you check these, but more exist_) is the commonest member and is never closed by adding the
  next item: replace the set with the property that makes a set unnecessary - the directory rather than
  the files in it, the content rather than the marker, the parent rather than the spellings. A finite list
  is legitimate only when it is _closed_ and asserted against its source, so the check fails when the
  source grows. **Two rounds on one class is the signal; the third is a course you were already told to
  change.** The in-repo config guard is the worked example: each round named the file the reviewer had
  spotted and the class survived, and only the directory predicate ended it.

Test before submitting: would a reviewer find more *claims* to check in this diff than *code*? If yes, cut
until it does not.

<!-- Only the section below is sent with a review (REQ-HOOK-40); the rest of this file is not. Keep it
     to FACTS - state a decision and point at where its reasoning lives. Not "do not report X", which is
     what the gate's tier and opt-outs are for. This comment is not part of the sent text because it sits
     above the heading. -->

## Code review

- **The bundle is shell, git hooks and docs.** There is no build step and no package manager, by design.
- **`src/preflight-gate`'s documentation tier is advisory by default**, covering `.md`, `.markdown`,
  `.rst` and `.adoc`. Which paths that implies, and the reasoning behind it, are in `docs/architecture.md`.
- **`[gate]` in `.preflight.toml` and the gate's opt-outs can relax enforcement.** The hook is a local
  pre-commit check on the committer's own work and `git commit --no-verify` bypasses it regardless; the
  trust-boundary reasoning is in `docs/architecture.md`.
- **A repository overrides review settings in `.preflight.toml`, but never the models.** The file may set
  any review section and `[gate]`; `[profiles.*]`, `[providers.*]` and `[selection]` are refused, because
  naming one is choosing which machine's credential a review spends. `docs/architecture.md` has the rest.
- **`AGENTS.md` and `AGENTS-review-snippet.md` have different audiences:** the first is for agents
  changing this repo, the second is the block pasted into a consuming repo.
- **The "answer the class, not the instance" rule is stated in `AGENTS.md`, `PLAYBOOK.md` §3 and
  `AGENTS-review-snippet.md` by design.** An agent must hold that habit *while editing*, so it cannot live
  one link away; `PLAYBOOK.md` is the publication form for repositories that have no `AGENTS.md`, and the
  snippet carries it to the consuming agent's round-economy habits.
- **One fact lives in one file, chosen by audience** - the table under "Each fact lives in exactly one
  file" names which file each kind of fact belongs to.
- **`docs/roadmap.md` holds to-dos only**, and finished items are deleted from it into `CHANGELOG.md`. A `[x]`
  item appears only under "Open questions on shipped work", where the tick marks the shipping as settled
  and the paragraph beneath it as the work; the shipping paragraph is context for it.
- **The review's diff is the pending change against the last commit, and it includes tracked edits that
  are not staged.** So "no `.gitignore` change appears in this diff" is verifiable: run `git diff HEAD`
  and read it before reporting a missing rule. `config/settings.toml` and `config/providers.toml` are
  ignored by explicit path in `.gitignore`, and the `models` stage asserts it with `git check-ignore`.
- **No endpoint, model id, host or credential is named in the code, the tests or the shipped templates.**
  Configuration happens after the install, in `$PREFLIGHT_HOME/providers.toml`; the templates carry
  obvious placeholders (`https://api.example.com/v1`, `your-model-id`) and `install.sh` substitutes
  nothing - it installs them verbatim. A test fixture names its own fictional provider, so no real
  endpoint's name reaches an assertion the suite is then written around. "This value is what `<some specific service>` needs" is not
  a reason to hard-code it - it is a reason to document the key in `config/providers.toml.example`.
- **`install.sh` never takes a credential.** The key is typed into `providers.toml` (created 600-mode) by
  the operator, so it never appears in a command's argv, a shell history or the environment. What the code
  guarantees: `providers.toml` is 600-mode, the rendered config is 600-mode and outside the repository,
  the review's `git add -A` snapshot cannot see either (`.gitignore`), and a key is refused in any derived
  or shadowed position. `SECURITY.md` carries that trust model; a change that *widens* it is worth
  reporting.
- **`.secrets.toml` is out of scope, including the symlink an older bundle left in the pr-agent package.**
  Nothing in this bundle reads or writes that name any more; the config is `settings.toml` + `providers.toml`
  rendered per run to `$PREFLIGHT_HOME/.pragent.settings.<pid>.toml`. `install.sh` and `uninstall.sh` therefore do NOT
  clean up a leftover `pr_agent/settings/.secrets.toml` from a pre-0.6 install, and a finding that asks for
  that cleanup is out of scope rather than a defect. Measured, not assumed: pr-agent's dynaconf load
  **skips** a dangling entry in its settings-file list and loads the rest (probe: a `settings/.secrets.toml`
  symlink pointing at a deleted path, alongside one real settings file - the real one loaded normally). The
  link is dead weight, not a failure. Delete it by hand if you want it gone.
- **`--extra_config_url` takes a bare filesystem path, and that is verified, not assumed.** pr-agent's
  `_resolve_extra_config_to_file()` accepts a bare path, a `file://` URL and an `http(s)://` URL; the
  renderer passes the bare path, because the two wrappers resolve `$PREFLIGHT_HOME` once and a scheme adds
  nothing. The stub `pr-agent` in the tests treats the argument as a path, so a scheme regression would not
  show up there - which is why the property lives in this list rather than only in a test.
- **Reviews here are non-deterministic on identical content.** The spread is in
  [`docs/measurements.md`](docs/measurements.md), so `new=0` is a judgement signal, not a clean bill of
  health.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/) - `type(scope): subject`, one logical change
per commit. Commits on this repo are **GPG-signed** (`commit.gpgsign=true`). Call out breaking changes
(renamed commands, renamed env vars) in both the commit body and `CHANGELOG.md`. Do not commit unless
asked.
