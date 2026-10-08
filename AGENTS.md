# AGENTS.md

Instructions for AI agents working **in this repository**. The bundle's *product* is itself an agent
instruction block (`AGENTS-review-snippet.md`) - that file tells an agent how to review code in *another*
repo. This file is about changing this repo. Do not confuse the two.

## What this repo is

`preflight` is a deployable, machine-local [PR-Agent](https://github.com/The-PR-Agent/pr-agent) review setup: a
working-tree review loop plus a commit hook that makes the loop impossible to skip. It is **shell plus git
hooks** - no compiled code, no package manager, no framework. The artifacts that ship are `install.sh`,
`uninstall.sh` and the files under `files/`; everything else is docs and tests. There is no "source" and
"build": the scripts in `files/` *are* the product.

Published at <https://github.com/413x5/preflight>. Default branch `main`; work happens on feature branches
with pull requests. CI (`.github/workflows/ci.yml`) runs on every pull request and on pushes to `main`.
(The repo is named `pr-agent` in some local tooling for historical reasons, but the GitHub repo is
`preflight` - do not "fix" one to match the other.)

## The one rule that matters most

**ClinePass is a default, not an assumption.** Any OpenAI-compatible endpoint must work. Never hard-code a
provider into a mechanism: anything endpoint-specific - a model id, a streaming quirk, a token window -
belongs in `files/preflight.toml` as an overridable default, and must be documented as provider-specific in
the file itself and in `docs/DESIGN.md`. The CI and the tests must never require a paid key or the network.

## One review must report everything

The product's central promise is that the loop converges: review once, fix **all** the findings, re-review.
If a review reports one finding and the next run hands you another, the bundle has failed at the one thing
it exists to do. There are two independent ways to break that promise, and they look identical from the
outside - fix one and the loop is still slow.

1. **What the model reports.** `pr_reviewer.num_max_findings` (upstream default 3) and
   `pr_reviewer.extra_instructions`. Lowering either re-creates the cascade.
2. **What the model was shown.** When a diff exceeds the token budget, pr-agent prunes files and reviews
   the first patch unless `pr_reviewer.enable_large_pr_chunking` is on - so a "complete" review can cover a
   slice of the tree. **This is the one that is easy to miss**, because every finding in a partial review is
   a real finding; the missing coverage is invisible.

`files/preflight.toml` sets all four keys, CI asserts them, and `preflight` prints `coverage=PARTIAL` when
anything was left out. Do not weaken any of it to save tokens: a partial review is what turns a two-round
loop into an unbounded one, and silent partial coverage has the same shape as the other failures this repo
guards against - an inability to check that is indistinguishable from a pass.

## Layout

| Path | What it is |
|---|---|
| `install.sh`, `uninstall.sh` | Deploy/remove the setup on a machine. `bash`, idempotent |
| `files/preflight` | `preflight` - reviews the working tree; also dispatches `preflight hook` |
| `files/preflight-pr`, `files/preflight-gate` | Hosted/PR mode; the machine-checkable verdict |
| `files/preflight-hook` | The commit-time verifier - **see below before touching it** |
| `files/githooks/` | The example hooks a *consuming* repo copies into its own `.githooks/` |
| `files/VERSION` | The bundle version, single source of truth. `preflight --version` and `install.sh` read it; CI fails if it, the `CHANGELOG` heading, and `--version` disagree |
| `files/preflight.toml` | The global config template (model, provider knobs, review caps) |
| `files/ensure-link.sh`, `files/secrets.toml.example` | Secrets relink helper; template with an empty key |
| `AGENTS-review-snippet.md` | The block pasted into a *consumer* repo's `AGENTS.md` |
| `tests/run.sh`, `tests/sample/` | Integration tests for the hook; the fixture they build on |
| `docs/DESIGN.md`, `docs/TROUBLESHOOTING.md` | How/why it works; symptoms and fixes |

Full contract and ground rules: [`CONTRIBUTING.md`](CONTRIBUTING.md). Read it before changing `files/`.

## `files/preflight-hook` and `files/githooks/post-commit` are the sharp edges

`preflight-hook` is a ~160-line POSIX `sh` script and the highest-risk file here: it is the only thing that
makes the review loop enforceable, and its whole job is to be *hard to bypass*. `files/githooks/post-commit`
is the *opposite* kind of sharp edge - it cannot block anything, so a bug in it is silent by construction.
Read [`docs/DESIGN.md`](docs/DESIGN.md) (the containment section) and
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
  not reasoned about - the comparison table in `docs/DESIGN.md` is empirical.
- **Path names are handled as raw bytes** (`git … -z`, split on NUL), never interpolated into a git
  argument. `--name-only` without `-z` *quotes* awkward names, and a quoted name is not a path.
- **The bypasses are load-bearing knowledge.** Unreviewed deletions, renames, symlink typechanges,
  `git rm --cached`, git-quoted path names and gitlink removals have each been a real escape at some point.
  `tests/README.md` maps every one to the case that guards it - do not weaken those cases.

### If you change the hook's behaviour, prove it

The test suite is not decoration; it is the only defence against this file silently regressing into
something that passes everything. For any behavioural change:

1. Add or update the case in `tests/run.sh` and give it the next `REQ-HOOK-nn`.
2. Add it to the `run_group` list **and** to the tables in `tests/README.md`.
3. **Classify it** in the `sensitive` or `insensitive` list beside `case_selfcheck`. An unclassified case
   fails `./tests/run.sh selfcheck`; so does a case marked sensitive that passes with the hook neutered.
   This is what stops a case from claiming to test enforcement without actually testing it.
4. **Revert your fix and confirm the new case fails.** A case that cannot fail is worth nothing - one was
   written during this project, shown to be unfalsifiable, and deleted rather than kept as false coverage.
5. If the change is a fix rather than a feature, add it to the containment table in `docs/DESIGN.md`.

## Commands

Everything CI runs is available locally; a green local run means a green CI run.

```sh
./tests/run.sh hook        # the offline hook cases - seconds, no network, no key. Run this constantly.
./tests/run.sh selfcheck   # re-runs the above against a neutered hook (see below)
./tests/run.sh e2e         # one live case: needs the installed helpers and a real key
./tests/run.sh             # everything
```

`selfcheck` exists because a green suite is **not** proof the hook enforces: 10 of the 26 offline cases
pass with the hook stubbed out entirely, because they assert acceptance (`commit -a`, a reviewed deletion,
a reviewed rename) or test a deliberate bypass. The selfcheck runs the whole suite against a neutered hook
and requires exactly the enforcement-sensitive cases to fail. It also **requires every case to be
classified**, so a new case must be declared sensitive or insensitive or the selfcheck fails.

| Check | Command |
|---|---|
| Syntax (helpers/installer are `bash`) | `for f in install.sh uninstall.sh files/preflight files/preflight-pr files/preflight-gate files/ensure-link.sh; do bash -n "$f" || echo "FAIL $f"; done` |
| Syntax (hooks/tests are POSIX `sh`) | `for f in files/preflight-hook files/githooks/pre-commit files/githooks/post-commit tests/run.sh; do sh -n "$f" || echo "FAIL $f"; done` |
| Installer into a throwaway prefix | `PREFLIGHT_HOME=$(mktemp -d)/cfg PREFLIGHT_BIN_DIR=$(mktemp -d) PREFLIGHT_SKIP_TOOL_INSTALL=1 PREFLIGHT_SKIP_PACKAGE_LINK=1 ./install.sh` |
| Generated config is valid TOML | `python3 -c "import tomllib;print(tomllib.load(open('CFG/preflight.toml','rb'))['config'])"` |
| Commit-hook integration tests | `./tests/run.sh hook` |
| Selfcheck (the suite against a neutered hook) | `./tests/run.sh selfcheck` |
| Version is consistent | `v=$(head -n1 files/VERSION); grep -q "^## \[$v\]" CHANGELOG.md && ./files/preflight --version` |
| Workflow lint | `actionlint .github/workflows/ci.yml` |

Pass **one** file per `-n` invocation, as the loops above do. `bash -n a.sh b.sh` only parses `a.sh` - the
second name becomes a positional parameter, so a syntax error in `b.sh` is silently not reported.

`python3` is available and is used by the hook, the tests and CI. **Do not `pip install` anything** -
the machine is externally managed (PEP 668) and nothing here needs a dependency. YAML can be parsed with
Ruby's built-in Psych if you need to inspect config.

## Never do these

- **Never commit a secret.** Only `files/secrets.toml.example` (empty key) is committed. Real keys live in
  `~/.config/preflight/.secrets.toml`, which is gitignored and never belongs in the environment.
- **Never set `core.hooksPath` in this repository.** It is clone-wide: setting it here would affect this
  checkout *and* every worktree of this clone, and would start enforcing a hook against this repo's own
  commits. Do all hook testing in a `mktemp -d` repository.
- **Never introduce an absolute `core.hooksPath`** in anything you write, including docs and examples. It
  breaks git worktrees - each worktree would run another checkout's hooks dir. Relative `.githooks` only.
- **Never reintroduce the old names.** `pra`/`pral`/`pral-gate` and `~/.config/pr-agent/` were renamed;
  `pr-agent` must mean only the upstream tool. The installer actively cleans the stale commands up.
- **Never make the doc examples require a paid key or the network**, and never add a test that does.
- **Never hand-edit a `.preflight/review.meta.json`** in a test to fake the *real* review path. The suite
  deliberately simulates a review by writing a sidecar (`review_here`); that is a fixture, not a shortcut
  for production code. `preflight review` is the only thing that may write it.
- **Never let base resolution silently guess.** The base is resolved by *verifying* each candidate
  (`PREFLIGHT_BASE`, `origin/HEAD`, `ls-remote --symref origin HEAD`, then `origin/main|master`, `main|master`)
  and failing with exit 4 when none resolves. The old unchecked fallback to a bare `main` produced a fatal
  `git diff` and an **empty** artifact dir, which the hook reports as "no review found" - turning a base
  problem into an unexplainable block on every commit.
- **Never make the `post-commit` advisory exit 0 on a sidecar it cannot read.** It is the only thing that
  reports silent non-enforcement, so a malformed sidecar or a missing `python3` must warn. An *absent*
  sidecar stays quiet (no review has run, and `pre-commit` refuses first).

## This machine has the bundle installed

`preflight` is on `PATH` and a key is configured, so the live `e2e` case runs and you can exercise the real
tool in a scratch repo:

```sh
R="$(mktemp -d)"; cd "$R"; git init -q -b main .
printf 'def add(a, b):\n    return a + b\n' > util.py
git add -A
git -c commit.gpgsign=false commit -q --no-verify -m init
mkdir -p .githooks && cp ~/.config/preflight/githooks/* .githooks/
git config core.hooksPath .githooks
preflight review && preflight-gate          # expect a pass, then the commit is accepted
```

The `git add -A` before the first commit is required: `preflight review` exits 3 on a repo with no commits,
and without it the single file stays untracked.

A review is token-heavy (roughly 15-23k tokens). Do not run one in a loop.

Note when testing the *gate*: `PREFLIGHT_GATE_ALLOW_ISSUES=1` relaxes key issues only.
`security_concerns` and `merge_recommendation=changes_required` still fail, regardless of the opt-out.

## Working on docs

The docs are part of the product, and they drift. Before claiming something works, run it - several
documented recipes in this repo were wrong (a "re-record the verdict with `preflight-gate`" instruction
that could not work, and a reference to a file that never existed). If you change behaviour, grep for every
place that describes it: `README.md`, `AGENTS-review-snippet.md`, `ROADMAP.md`, `CHANGELOG.md`,
`docs/DESIGN.md`, `docs/TROUBLESHOOTING.md`, `tests/README.md`, `CONTRIBUTING.md`. Case counts, the
requirement table, and the containment table go stale fastest.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/) - `type(scope): subject`, one logical change
per commit. Commits on this repo are **GPG-signed** (`commit.gpgsign=true`) and carry **no
`Co-authored-by` trailer**; match that. Call out breaking changes (renamed commands, renamed env vars) in
both the commit body and `CHANGELOG.md`. Do not commit unless asked.
