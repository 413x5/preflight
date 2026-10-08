# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **The pending commit is now the default review scope.** `preflight review` used to review the whole
  branch since the default branch. It now reviews exactly what a commit would contain - HEAD to the working
  tree, untracked files included - which is the case the tool exists for: reviewing a change before it is
  submitted. This needs no remote, no base resolution and no `git commit-tree`, so the default path makes
  no network round trip and cannot fail with "cannot tell which branch to diff against".

  `PREFLIGHT_SCOPE=worktree` still reviews the whole branch, and `=head` still reviews committed content
  only; both are unchanged, including the exit-4 failure when no base resolves.

  Reviewing commit by commit covers a multi-commit branch completely. The pre-commit hook binds content,
  not time - it deliberately does not check that the recorded `HEAD` still equals `HEAD` - and it compares
  the reviewed tree against the tree being committed, so it constrains only the commit being made. Every
  commit is therefore reviewed against the tree it commits, and the union of those reviews covers the
  branch. A branch review, by contrast, is a sample of the final state and enforces nothing.

  `coverage=PARTIAL` is now emitted only for the branch scopes: a pending-commit diff is far below the
  token budget, so pr-agent never prunes it and there is nothing to announce. Guarded by `REQ-HOOK-33`,
  whose three mutations (default reverted, `worktree` losing its base, unknown scope accepted) were each
  confirmed to fail the case.
- **A hung shutdown no longer hides a review's results, and no longer blocks the loop.** `preflight
  review` has been observed writing both artifacts and then never exiting, because pr-agent's post-run
  callback drain blocked on a stalled socket. The review was complete the whole time. The summary is now
  read from `review.json` *before* waiting, so a hang cannot hide `issues=`/`new=`/`coverage=` - the signal
  the loop stops on - and a process that has not exited `PREFLIGHT_SHUTDOWN_WAIT` (default 120s) after
  writing its artifact is stopped, with the run still succeeding and its sidecar recorded. The review's own
  wait is bounded too, at an hour by default: it is a backstop against a hang, not a performance target. A
  run stopped without an artifact keeps its non-zero status, so a missing review cannot read as a pass.
  Covered by `REQ-HOOK-32`.
- **The reasoning budget is set, and it was the largest lever on review time.** A ~500-line diff was
  measured at ~23,500 completion tokens in 111s, of which only ~2,500 characters reached `review.md` - the
  rest was hidden reasoning, invisible in the artifacts, so a slow review read as a slow provider.
  `files/preflight.toml` sets `[config] reasoning_effort` together with the
  `[config] additional_reasoning_effort_models` entry required for it to arrive: pr-agent forwards the
  setting only to a model litellm's metadata calls reasoning-capable, and `cline-pass/*` is not in that
  table - the same gap that forces `custom_model_max_tokens` - so without the second key the value was
  read, logged as the default, and silently dropped. Measured interleaved on one diff: mean **~18.6s /
  ~4,051 completion tokens** unforwarded against **~9.2s / ~1,689** with `low` forwarded. Measure any
  change here against `new=N/M`: a cheaper round that reports fewer findings just moves the cost into a
  second round.

- **A convergence signal on the summary line: `new=N/M`.** Reporting every finding in one pass is not
  enough to make the loop end, because a reviewer cannot tell a deliberate, documented trade-off from an
  oversight - and each round necessarily reviews the code, comments and docs the previous round wrote, so
  re-running keeps producing findings that were already considered. Chasing those is what turns the loop
  into a treadmill, at a full model call per round. Each run now compares its findings against the
  previous run's and reports how many are new:

  ```
  preflight: issues=2 security=No effort=3 tokens=71791 new=0/2 (unchanged since the previous review: judge each, do not re-fix blind)
  ```

  Identity is pr-agent's own dedupe key - `(relevant_file, issue_header, issue_content)`, normalised - so
  a different issue in the same file is still new. `new=0` is the stopping signal: judge each finding as a
  real defect, already answered, or wrong, and fix only the first. The hint deliberately does not say
  "done": it compares against the previous *run*, not against what you decided, so a deferred finding
  looks like a repeat. Text matching means a lightly reworded repeat can still read as new - a strong
  hint, not a verdict, absent on a first review or when the previous one is unreadable.
  `AGENTS-review-snippet.md` documents the stop condition, and `docs/DESIGN.md` the reasoning and limits.

  Reviewing this feature found that its own tests were the weakest part, and each gap is fixed:
  the assertions were **skipped wherever pr-agent is absent** - which is always, in CI - so the headline
  logic ran under no check at all; they now live in a pr-agent-independent case (`REQ-HOOK-31`) that runs
  in CI. A simulated upstream change to the footer bullet format now fails loudly instead of quietly
  retiring the marker. And `COVERAGE_RE` no longer requires the emoji: the lenient read that keeps the
  counts on a non-UTF-8 `review.md` replaces an invalid emoji with U+FFFD, so requiring it meant the
  marker could never fire on exactly the file it was written to tolerate.

  Review also caught a doc bug worth naming: the troubleshooting advice pointed at
  `config.callback_timeout_seconds` when pr-agent reads it from `[litellm]`, so anyone following it would
  have changed nothing and kept hanging. A wrong config path fails silently, so `REQ-HOOK-29` now checks
  every `section.key` the docs name against pr-agent's own defaults - the guidance cannot rot unnoticed
  again.
- **One review now reports everything, instead of one finding at a time.** The `review → fix → re-review`
  loop was slow because it had two independent causes, and only one of them was configured for.
  `pr_reviewer.num_max_findings` caps how many findings a review *returns* (upstream default 3), and it
  was already raised to 20 - but raising it does nothing when the model was only *shown* part of the
  diff. When a diff exceeds the token budget, pr-agent's default is to prune files and review the first
  patch, so a "complete" review silently covered a slice of the tree, and the next run surfaced findings
  that were there all along. `files/preflight.toml` now also sets:
  - `pr_reviewer.extra_instructions` - injected verbatim into the reviewer's system prompt (verified),
    telling the model to work through the whole diff and report every issue it is confident about rather
    than stopping at the first;
  - `pr_reviewer.enable_large_pr_chunking = true` (`max_number_of_calls = 3`) - an oversized diff is
    split, up to `max_number_of_calls` chunks are reviewed, and the per-chunk findings are unioned into one review instead of
    files being pruned. It is inert unless the budget actually leaves files out, so an ordinary diff
    still costs exactly one AI call.
  Anything still uncovered is reported rather than hidden: `preflight` now appends
  `coverage=PARTIAL (token budget left files out - see review.md)` to its summary line, so a low
  `issues=` count on a partially-reviewed diff is not mistaken for a clean change. CI asserts the
  completeness settings, because a regression in any of them shows up as a loop that will not converge
  rather than as a failing build.
  The marker decides **structurally, then textually**: findings render inside the review `<table>` and
  pr-agent emits the footer after it, so a match only counts past the last `</table>`, with the footer's
  wording as a secondary check. Text matching alone could not hold - one phrase, two independent
  substrings, and the contiguous sentence each false-positived on a real review of this very feature,
  because the model reproduces the footer while explaining it. Both directions matter: a missed footer
  retires the marker and a partial review reads as complete; a spurious match fires it on a complete one
  and teaches the reader to ignore it. CI checks the surface that needs no network (the marker matches
  the footer literal from pr-agent's source, and ignores prose and in-table quotes); `tests/run.sh`
  `REQ-HOOK-28` re-checks against the **installed** pr-agent's own footer source and skips where the tool
  is absent, so an upstream rewording is caught on a machine that has it.
- **`preflight --help` and `preflight --version`** (plus `-h`/`-V` and `preflight-gate --help`). Both are
  answered before anything touches git or the config, so they work outside a repository too (`--help` is
  the first thing a new user runs, and it must not need a repo or a configured key). `--version`
  reports the installed bundle version, read from a single source of truth (`files/VERSION`, installed as
  `~/.config/preflight/VERSION`); `install.sh` prints the same number. An installed copy previously had no
  way to say what it was, which made "is the bundle current on this machine?" unanswerable except by
  re-running the installer - the exact question a real session got stuck on. CI fails if `files/VERSION`,
  the `CHANGELOG` heading for it, and what `--version` prints ever disagree.
- **`PREFLIGHT_HOME` is now honoured by the helpers, not just the installer.** `preflight`, `preflight-pr`
  and `ensure-link.sh` all resolve the config dir the same way (`PREFLIGHT_HOME`, else
  `~/.config/preflight`), so the version lookup, the secrets relink, the hook helper and the review's
  `--extra_config_url` can no longer point at different trees. On a machine installed under a
  `PREFLIGHT_HOME` prefix, `review` previously read `~/.config/preflight` while `--version` read the
  prefix.
- **`PREFLIGHT_BASE`** overrides the ref the review diffs against.
- **CI** (`.github/workflows/ci.yml`): on every pull request and on pushes to `main`, on both Ubuntu and
  macOS, it checks shell syntax (`bash -n` for the helpers/installer, `sh -n` for the hooks and tests),
  dry-runs `install.sh` into a throwaway prefix (including that it never clobbers an existing
  `.secrets.toml`), validates the generated config as TOML, and runs the offline commit-hook suite. A
  separate job lints the workflows with a pinned `actionlint`. The live-endpoint test is deliberately
  excluded: it needs a paid key, and CI must not depend on one.
- **Dependabot** (`.github/dependabot.yml`) keeps the workflow actions current, weekly and grouped into a
  single pull request. The pins had already gone stale once (CI shipped with `actions/checkout@v5` and
  `actionlint` 1.7.7), so this replaces "someone notices" with an automated bump whose PR is checked by
  the CI it changes.
- **A commit hook that refuses an unreviewed commit.** An agent (or human) could previously skip the review
  entirely; now a repo can make the commit itself fail. Copy the bundled `files/githooks/*` into the repo's
  own `.githooks/` and run `git config core.hooksPath .githooks` (relative - an absolute path breaks git
  worktrees). The hook is opt-in per repo and covers every worktree.
  - It **verifies** that the content being committed is exactly what `preflight review` reviewed, and never
    runs a review itself (a review cannot be graded before the commit it describes exists).
  - The binding is **content-based, not time-based**: an edit after the review, or a newly staged unreviewed
    file, blocks the commit and names the paths.
  - Reviewed-but-uncommitted content is ignored, so `git commit -a` keeps working with untracked scratch
    files. This is `containment` - deliberately not strict equality, which would break `commit -a`, and not
    a superset check, which would let a brand-new unreviewed file - or the deletion of a reviewed one -
    through. Deleting a whole reviewed file is blocked (`D` records that `HEAD` knows), while an untracked
    scratch file that is merely not being committed is ignored. Renaming a reviewed file (`git mv`) and
    swapping one for a symlink are blocked too - with rename detection on those are `R`/`T`, which an
    `AM`-only filter reports as no change at all.
  - The **first** commit in a repository with no history is allowed but not enforced: `preflight review`
    cannot run before a first commit exists, so blocking would make the hook impossible to adopt.
  - It is **strictly read-only**: it never modifies the index, `HEAD`, the working tree, or the artifacts,
    and it fails closed when the helper is missing.
  - `PREFLIGHT_SCOPE=head` reviews cannot be enforced (they cover already-committed content), so the hook
    says so on stderr rather than pretending; a `post-commit` companion warns when enforcement did not apply.
  - `preflight review` now also writes `.preflight/review.meta.json`, recording the tree it reviewed and the
    `preflight-gate` verdict. `.preflight/` is left in place on a block so the findings can be inspected.
- New `preflight hook` subcommand and `preflight-hook` helper; `install.sh` installs both plus the example
    hooks into `~/.config/preflight/`.
  - Covered by an integration suite in `tests/` (`./tests/run.sh`): real repositories, the real hook
    files, no framework and no network. One check per requirement (`REQ-HOOK-nn`, mapped in
    `tests/README.md`), each protecting a specific behaviour - including the bypasses found while
    building this (unreviewed deletions, renames, symlink typechanges, `git rm --cached`, reviewed files
    whose names git quotes, gitlinks, and an unset `HOME`).
    Every fix was reverted in turn to confirm the matching case fails without it, and the selfcheck
    below requires that a neutered hook turns exactly the enforcement-sensitive cases red.
  - Path listings use `-z` and the paths are handled as raw bytes. `--name-only` without `-z` wraps any
    path that needs quoting in double quotes and backslash-escapes it, and `core.quotePath` cannot
    disable that for the characters that matter. Handing such a name back to git asks about a path that
    does not exist, which made a reviewed file named `a"b.py`, `c\d.py` or `café.py` indistinguishable
    from an untracked scratch file - so deleting it committed unreviewed.
  - The tracked paths at `HEAD` are read with `git ls-tree` rather than by asking git about each
    candidate path. `git cat-file -e "HEAD:sub"` fails for a **gitlink**, so a submodule removal was
    classified as "not tracked at HEAD" and slipped through unreviewed.
- **A selfcheck for the hook test suite** (`./tests/run.sh selfcheck`, wired into CI). A green suite was
  not evidence that the hook enforced anything: stubbing the hook out entirely still satisfied a large
  share of the offline cases, because those assert *acceptance* (a reviewed deletion, `commit -a`, a
  reviewed rename), exercise a deliberate bypass, or test the separate example hooks. Nothing kept the
  enforcement-sensitive cases sensitive, so a case claiming to catch an unreviewed commit could have
  passed with the hook disabled and nobody would have known. The selfcheck re-runs the whole suite
  against a neutered hook and requires exactly the declared enforcement-sensitive cases to fail, reports
  the split, and **requires every case to be classified** - an unclassified case, or a sensitive case
  that passes or skips, fails it. The check is itself mutation-tested.

### Fixed

- **The `new=` count was suppressed after a clean review.** It was computed only when the previous
  review had findings, so a run following a clean pass reported no convergence signal - the one round
  most likely to be re-running for no reason. It is now computed whenever a previous review was *loaded*,
  and a clean previous review correctly makes every current finding new.
- **The temp file used to compare against the previous review could leak.** `mktemp` created it, but a
  failed copy cleared the variable, so the exit trap no longer knew to remove the file. The path is now
  assigned only after a successful copy.
- **`REQ-HOOK-30` could vanish instead of failing.** It asserted on `.preflight/review.md` inside an
  `if [ -f ... ]`, so a review that reported a pass without writing the file produced neither a pass nor
  a failure - the requirement silently retired, which is exactly the "a guard that did not run proves
  nothing" rule the selfcheck applies to skips. A missing `review.md` now fails the case.
- **`max_number_of_calls` was documented as capping cost without losing findings.** It caps how many
  chunks are *reviewed*: a diff needing more chunks has the excess never sent to the model, so their
  findings are never produced and the files appear only in the coverage footer. The comment now says so
  instead of implying chunking always covers the whole diff.
- **`preflight review` blocked every commit on Debian/Ubuntu.** The helper ran the gate with `sh
  "$gate_bin"`, but `preflight-gate` is a **bash** script (`set -euo pipefail`) and on Debian/Ubuntu
  `/bin/sh` is dash, which rejects `pipefail` on the first line. The gate died with exit 2, and since
  `preflight review` records the gate's exit as the sidecar verdict, that was stored as `fail` - so
  `preflight-hook` then refused *every* commit with "the last review did not pass", for a reason that
  had nothing to do with the review. It now executes the gate directly, honouring its shebang, with no
  `|| sh` fallback (which would reintroduce the silently-wrong verdict). macOS hid this: its `/bin/sh`
  is bash and accepts `pipefail`, so only the Ubuntu half of CI could have caught it - and nothing
  exercised the helper's own gate launch.
- **`preflight-gate` crashed with a traceback whenever a review field had the wrong type or shape.** The
  review is model output, so any field can arrive as something other than what the code assumed, and each
  such case was an uncaught traceback - which is **not** a neutral failure: the commit hook reads any
  non-zero exit as "the review did not pass", and `preflight review` records that exit as the sidecar
  verdict, so a perfectly clean review was stored as `fail` and then blocked every commit. Four separate
  shapes did it: a boolean where text was assumed (`"relevant_tests": true`, which the model produces
  often), a non-object `review.json` or non-object `review`, a non-list `key_issues_to_review` (`true` or
  `3`, which broke `len()` and iteration), and a non-finite effort (`1e999` parses to `inf`, and
  `int(float('inf'))` raises `OverflowError`, not `ValueError`). Every field is now coerced or
  shape-checked, an unreadable or wrong-shaped `review.json` exits 3 with a message (3 is "no usable
  review", which is what it amounts to), and `PREFLIGHT_GATE_MAX_EFFORT` is compared numerically whether
  the effort arrives as an int, a float or a string. CI now exercises all of these shapes, because
  nothing in the commit-hook suite covers the gate at all - which is how they survived.
- **`preflight --version` aborted with `HOME: unbound variable` when `HOME` was unset.** Bash expands
  every word of a `for` list before the loop runs, so the config-dir fallback evaluated a bare `$HOME`
  even when `files/VERSION` beside the script had already matched - and the script runs under `set -u`.
  The same trap was in the gate-lookup loop, where it was worse: the abort landed *after* pr-agent had
  run but *before* the verdict was recorded, so the artifact dir was left without a usable sidecar and
  `preflight-hook` then reported "no review found" and blocked every later commit. Both are now
  `${HOME:-}`, the same guard the example hook uses (REQ-HOOK-26), plus an undocumented
  `PREFLIGHT_HOME` override on the lookup so a throwaway-prefix install reports its own version. Found by
  this repo's own review loop, on the first version of this very change.
- **Base-branch resolution.** The base is now the first of `PREFLIGHT_BASE`, `origin/HEAD`, the remote's
  own `HEAD` (`ls-remote --symref`, needed because a `--single-branch` clone and a hand-added remote never
  create the local `origin/HEAD` symref), then `origin/main|master`, `main|master`. Before, an unresolvable
  `origin/HEAD` fell through to a bare `main` **without being checked**: in a repository whose default
  branch was anything else, `git diff main...HEAD` was fatal, pr-agent exited 2 with "No diff content
  received", and the artifact dir was left empty - which the commit hook reads as "no review found", so
  every later commit was blocked for a reason unrelated to the commit. It now fails with exit 4 and names
  the candidates instead. This is the one item here that was not found by a review of this repo; it was
  reproduced from a report of a session in another repository.
- **The `post-commit` advisory is no longer silent when it cannot read the review sidecar.** It decides
  whether a commit was covered by reading `scope` out of `.preflight/review.meta.json`, and it used to
  `exit 0` when `python3` was missing or the sidecar was malformed or lacked `scope`. That made it mute in
  exactly the case it exists to report, where silence and "verified" are indistinguishable - and a
  consuming repository had already patched its vendored copy to say so. An **absent** sidecar still stays
  quiet, which is correct: no review has run, and `pre-commit` would have refused the commit first (bar a
  repository's first commit, which is allowed unenforced by design).
- **`install.sh` no longer tells you to paste an API key you already have.** The `NEXT:` line was printed
  whenever `PREFLIGHT_KEY` was unset, including on a refresh install of a machine configured months
  earlier; it now checks the secrets file for a real key first.
- `files/githooks/pre-commit` aborted with `HOME: unbound variable` when `HOME` was unset, because it ran
  under `set -u` and expanded a bare `$HOME`. The commit was still refused - it failed closed - but with a
  confusing shell error instead of the documented "the preflight helper is missing" message. Now
  `${HOME:-}`, so an unset `HOME` degrades to the intended message. The live review of this repo reported
  it, which is a good argument for running `preflight review` on the bundle itself.
- `README.md` claimed "Python 3.12/3.13"; `install.sh` defaults to `PREFLIGHT_PY=3.13`.
- `docs/TROUBLESHOOTING.md` told you to re-record a failed verdict with
  `PREFLIGHT_GATE_ALLOW_ISSUES=1 preflight-gate`. That cannot work: the gate only prints and never rewrites
  `.preflight/review.meta.json`, so the verdict stayed `fail` and the commit stayed blocked. It now shows
  the command that does work (`PREFLIGHT_GATE_ALLOW_ISSUES=1 preflight review`) and notes that the opt-out
  relaxes key issues only - security concerns and `merge_recommendation=changes_required` still fail.
- `ROADMAP.md` referenced a `github-action.example.yml` staged for Layer 3 that has never existed in any
  commit.

### Changed

- The `post-commit` companion hook is now covered by the suite (`REQ-HOOK-27`; classified insensitive,
  since a post-commit hook cannot block) - it previously had only a `sh -n` syntax check, which is why the
  silent-sidecar defect above survived.
- **Added `AGENTS.md`** and linked it from `README.md` and `CONTRIBUTING.md`. It is instructions for agents
  *changing this repo* - the hook's invariants, the checks to run, the traps that have already caught
  someone - as opposed to `AGENTS-review-snippet.md`, which is the block pasted into a *consuming* repo.

- CI actions updated to current: `actions/checkout` v5 to v7 and `actionlint` 1.7.7 to 1.7.12. They stay
  pinned to a moving major tag, so patch releases arrive without an edit. Note that `checkout` v6 and later
  run on Node 24, which the `ubuntu-latest` and `macos-latest` runner images already provide.
- **Renamed the bundle from `pr-agent` to `preflight`**, so it no longer collides with the upstream
  PR-Agent project it wraps. After this change `pr-agent` means exactly one thing: the upstream tool.
  - Commands: `pra` → `preflight-pr`, `pral` → `preflight`, `pral-gate` → `preflight-gate`.
  - Config: `~/.config/pr-agent/pr-agent.toml` → `~/.config/preflight/preflight.toml`.
  - Artifacts: `.pr-agent/` → `.preflight/`.
  - Env: `PRAGENT_*`/`PR_AGENT_*` → `PREFLIGHT_*`, and `PRAL_DIR`/`PRAL_SCOPE`/`PRAL_GATE_*` →
    `PREFLIGHT_DIR`/`PREFLIGHT_SCOPE`/`PREFLIGHT_GATE_*`.
  - Repo: `413x5/pr-agent` → `413x5/preflight` (GitHub redirects the old name).
  - **Breaking.** Any repo whose `AGENTS.md` carries the old snippet calls `pral`, which no longer
    exists - re-paste `AGENTS-review-snippet.md`. The secrets file is *moved*, not regenerated (a
    fresh install would create an empty key). `uninstall.sh` cleans up the old names.
- **Decoupled the bundle from ClinePass.** It now documents and supports any OpenAI-compatible
  endpoint, with ClinePass as the built-in default rather than the premise. `install.sh` gains
  `PREFLIGHT_MODEL`, `PREFLIGHT_FALLBACK_MODELS`, `PREFLIGHT_CUSTOM_MODEL_MAX_TOKENS`,
  `PREFLIGHT_MAX_MODEL_TOKENS`, and `PREFLIGHT_FORCE_STREAMING_HOST`.
- The ClinePass force-streaming workaround is now keyed on the `api.cline.bot` literal instead of
  whatever `api_base` is configured. Previously a non-ClinePass endpoint silently inherited a
  ClinePass-specific quirk; now the block is inert unless the endpoint really is ClinePass.
- `AGENTS-review-snippet.md` now points at this bundle's repository, so an agent working in another
  repo can read current guidance (README, ROADMAP, design, troubleshooting, changelog) as the bundle
  evolves.
- `custom_model_max_tokens = 0` / `max_model_tokens = 0` are now documented as meaningful: `0` means
  "let LiteLLM resolve the window" and "no clamp" respectively, rather than being unexplained.

### Fixed

- `config.fallback_models` no longer points at a model the ClinePass endpoint cannot route. The
  upstream default (`["gpt-5.6-terra"]`) is a bare id, which the endpoint rejects (ids must be
  `provider/model`), so a failed primary model retried against a dead one; it is now
  `["openai/cline-pass/glm-5.3-flash"]`.

### Known issue

- **`preflight review` can complete and then never exit.** Both artifacts are written, and then
  pr-agent's post-run wait for litellm callbacks fails to finish - measured at 4-13 minutes, in two
  shapes: sleeping in `kevent`, or spinning at 100% CPU in the asyncio loop. The review itself is
  finished and correct, so a scripted loop that waits on the process stalls for no reason; stop it and
  use the artifacts. The summary line (`issues=`, `new=`) is printed after pr-agent exits, so a hang
  hides the counts too - read them from `review.json`. `config.ai_timeout` bounds the model request, not
  this wait, which has its own budget at `[litellm] callback_timeout_seconds` (not `[config]` - the
  wrong section is silently ignored). That bound has **not** been confirmed to stop the hang. Not fixed
  by wrapping the command in a shorter timeout, which would risk cutting off a slow but valid review -
  the silent-truncation failure this project works hardest to avoid. Diagnosis, the two contributing
  conditions, and what remains untested are recorded in `docs/TROUBLESHOOTING.md`, with the follow-up
  work in `ROADMAP.md`.

## [0.1.0] - 2026-10-07

Initial release: a deployable, machine-local PR-Agent review setup for the ClinePass endpoint.

> The command/file/env names below are the ones this version shipped with; they were renamed in the
> `[Unreleased]` entry above.

### Added

- `install.sh` - one-command, idempotent deploy: installs PR-Agent via `uv`, writes the config,
  creates the secrets file (`chmod 600`, never overwriting an existing one), installs the helpers,
  and links the secrets into the PR-Agent package. Honors `PR_AGENT_KEY`, `PR_AGENT_API_BASE`,
  `PRAGENT_PY`, `PRAGENT_SKIP_TOOL_INSTALL`, `PRAGENT_SKIP_PACKAGE_LINK`, `PRAGENT_HOME`,
  `PRAGENT_BIN_DIR`.
- `uninstall.sh` - removes the helpers and config (and the uv tool with `PRAGENT_REMOVE_TOOL=1`).
- `files/pra` - run PR-Agent with the global config (hosted/PR mode).
- `files/pral` - review the **working tree** (committed + uncommitted + untracked) against the
  remote default branch, with no commit and no history changes; writes `.pr-agent/review.md` and
  `.pr-agent/review.json`. `PRAL_SCOPE=head` limits it to committed content.
- `files/pral-gate` - machine-checkable gate over `review.json` (exit `0`/`1`/`2`/`3`).
- `files/ensure-link.sh` - re-links the secrets file after `uv tool upgrade` recreates the venv.
- `files/pr-agent.toml` - the ClinePass model, the 1M-token budget, the LiteLLM **force-streaming**
  workaround, `num_max_findings = 20`, and the risk/merge signals.
- `files/secrets.toml.example` - the secrets template (no real key).
- `AGENTS-review-snippet.md` - the per-repo instruction block for `AGENTS.md`.
- `README.md`, `CONTRIBUTING.md`, `docs/DESIGN.md`, `docs/TROUBLESHOOTING.md`, this changelog and
  the roadmap.

### Fixed

- The review -> fix -> review "cascade" (fix 3 findings, the next run reveals 3 more) by raising
  `num_max_findings` from the default 3 to 20.
- Snapshotting the working tree for review without touching the index or `HEAD`, using a temporary
  `GIT_INDEX_FILE` plus `git commit-tree` with `commit.gpgsign=false`, so a global `gpgsign = true`
  cannot break it.

[Unreleased]: https://github.com/413x5/preflight/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/413x5/preflight/releases/tag/v0.1.0
