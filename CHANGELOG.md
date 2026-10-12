# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`scripts/verify` - the gate, as one command.** It composes every check this repository has in cost
  order, cheapest first (shell syntax -> installer into a throwaway prefix -> config and TOML -> version
  consistency -> the gate's JSON shapes -> the coverage marker -> the commit-hook suite -> the selfcheck),
  and reports `gate: PASS`/`FAIL` with the failing stages named. `.github/workflows/ci.yml` now **calls**
  it instead of listing the steps, split into a fast job and the behavioural one. That is the point: a CI
  job and a local instruction list maintained separately drift, and a change then passes one and fails the
  other. `scripts/verify --list` names the stages, and a single stage can be run while working.
  `PREFLIGHT_VERIFY_SKIP=<stage>` is the deliberate escape hatch - a check that cannot run exits non-zero
  rather than reporting a success it never earned.
- **`docs/` gained a tree, an index and decision records.** `docs/README.md` is the map, one line per
  document. `docs/adr/` holds the decisions that were previously implicit in prose, one per file, each
  with the options that lost, what it costs, and what enforces it: containment over equality, `commit` as
  the default scope, the pr-agent pin, the reviewer-context channel, the licence, and this restructure.
  `docs/history.md` carries the narrative arc, and `docs/measurements.md` the dated numbers with the
  reason each moved. `docs/DESIGN.md` became `docs/architecture.md` (mechanics only - the history and the
  numbers it had accumulated moved out), `docs/TROUBLESHOOTING.md` became
  `docs/runbooks/troubleshooting.md`, and `ROADMAP.md` became `docs/roadmap.md`.
- **`LICENSE` (MIT) and `SECURITY.md`.** The repository had no licence at all, which for a published
  repository means all rights reserved - not "undecided". `SECURITY.md` states what is deliberately out of
  scope (the hook is not a boundary against a hostile repository; the recorded verdict is not
  tamper-evident) so it is not mistaken for a control it is not.

### Changed

- **The shipped bundle moved from `files/` to `src/`; the templates `install.sh` writes to `config/`;
  the dev helpers to `scripts/`.** That is: `config/preflight.toml.example`, `config/gate.toml.example`,
  `config/secrets.toml.example` (all three shipped templates in one place - the global config, the gate
  policy and the secrets file) and `scripts/ensure-link.sh`. This is a **source-tree rename only**: it does
  not affect an installed machine, because `install.sh` copies into `$PREFLIGHT_HOME`, and nothing on disk
  records the repository path, so no installed helper, hook or config changes. What does change is every reference inside this repository - `install.sh`'s
  directory variables, the CI paths, the tests, and the docs - and one inside the consumer-facing snippet,
  which fetches the version from `contents/src/VERSION`. The reasoning, including why `src/` is a slightly
  hopeful name for a tree with no build step, is in `docs/adr/0006-adopt-the-playbook-layout.md`.
- **`AGENTS.md` now owns the layout, the invariants and the commands; `CONTRIBUTING.md` points at it.**
  Both files carried the same layout table, ground rules and command list. `AGENTS.md` keeps them because
  every coding agent reads it by convention, and a fact an agent has to discover is a fact it may not
  find; `CONTRIBUTING.md` keeps the human on-ramp - setup, and how to propose a change.
- **`.github/workflows/ci.yml` is two test jobs and a lint, not one long step list.** The fast job
  (syntax, installer, config, version, gate shapes, coverage) answers in seconds; the behavioural job runs
  the commit-hook suite and the selfcheck; `actionlint` stays its own job with a pinned binary, because it
  is the one check that needs a tool the gate does not require.

### Fixed

- **The docs' config-path check silently stopped covering the file it exists for.** `REQ-HOOK-29` walks the
  docs and fails on a documented `section.key` that pr-agent does not declare - a check written because the
  docs once told an operator to set `config.callback_timeout_seconds`, which pr-agent reads from
  `[litellm]`, so following the advice changed nothing and said nothing. Its glob was
  `docs/*.md`, **not recursive**, so moving that file to `docs/runbooks/troubleshooting.md` took it out of
  scope - a coverage loss with no failure to show for it, which is the exact shape this project's checks
  exist to prevent. The scan is now recursive, and asserts it covered **every** tracked doc by comparing
  against `git ls-files docs`, so a subdirectory can no longer drop a file quietly.
- **Two false positives in that same check, both exposed by the deeper scan.** A dotted name that is really
  a filename (`pr_code_suggestions.py`, cited throughout the docs) was parsed as `section=pr_code_suggestions,
  key=py` and reported as a bad key; source and config file extensions are now excluded. And a passage that
  names a key **in order to warn that it does not exist** was read as advice - such a line now says so
  inline with `doc-path-ok: <why>`, the same self-justifying marker style the meta-tests use, so the
  exception stays visible in review instead of living in an allow-list.


## [0.3.0] - 2026-10-11

### Added

- **The installer now pins pr-agent instead of tracking the latest release**, and exposes
  `PREFLIGHT_PR_AGENT_VERSION` to override it (default `0.47.0`, the version this bundle is verified
  against). `preflight` reads pr-agent's own output structure - the coverage marker matches the exact
  wording of its "files were not included" footer - so an unpinned upgrade could stop `coverage=PARTIAL`
  from printing. That failure is invisible in the direction that matters: a review that silently covered
  a slice of the tree still reports real findings, so the missing coverage reads as a clean review. CI
  asserts both that the `uv tool install` line carries the pin and that its value is the one the coverage
  fixture in `tests/run.sh` was copied from, so a bump has to come with a re-check rather than a silent
  drift. (Note `uv tool install` on an existing install reports "already installed" and does not upgrade,
  so installations that predate this change were already effectively frozen - the pin closes the gap for
  fresh installs.)

### Changed

- **`AGENTS-review-snippet.md` now states only the invariants of using `preflight`** - the loop and the
  gate's exits, the scopes and which the hook can enforce, the artifact fields, how to read `new=` and
  `coverage=`, the hook recipe, and the `Code review` context recipe. The three process essays that had
  grown in it (the stop condition, "fix the defect, not the narrative", and how to verify a claim) are
  gone, along with the measurements and history they carried - a consuming repo was being handed this
  bundle's own development discipline, and the reasoning already lives in `docs/DESIGN.md` and
  `AGENTS.md`, where the people who need it read it. The bundle-location section now says to re-paste the
  snippet from the **local installation** (`~/.config/preflight/AGENTS-review-snippet.md`) rather than
  from the repository, because the installed copy is the one that matches the helper actually on the
  machine - a newer snippet over an older bundle would document commands that are not there - and it shows
  how to compare the installed version with the repository's before deciding to upgrade. `install.sh`'s
  closing pointer names the surviving "Make it enforced" heading.

### Fixed

- **`README.md` described the pre-`commit`-scope review.** It still said `preflight review` diffs the
  working tree against the remote default branch with base resolution through `origin/HEAD` and
  `main|master`. The default scope became `commit` (`HEAD` -> working tree) in #5, which needs no remote,
  no base and no fetch; `--help` and `docs/DESIGN.md` were updated then and the README was missed. The
  base-resolution paragraph now says it applies to `PREFLIGHT_SCOPE=worktree` only, and the command table
  names the pending commit. Found by reviewing this change with the tool: the first round reported the
  contradiction between the new paragraph and the command table, and it was real - the scope builds its
  tree with `git add -A`, so untracked files are included while a commit contains only staged content. The
  force is a superset, not an equivalence, and that is load-bearing: reviewing *more* than a commit
  contains is what keeps `git commit -a` and newly staged files safe. The same overclaim was in
  `docs/DESIGN.md` and `--help` and is corrected in both.

## [0.2.0] - 2026-10-10

### Added

- **The reviewer now receives the repository's own review context, from AGENTS.md.** A reviewer
  cannot tell a deliberate, documented trade-off from an oversight, so it reports the trade-off as
  a defect - the `.preflight-gate.toml` trust boundary came back as a finding three times. A
  heading in AGENTS.md whose text starts with `Code review` is extracted and sent **alone**, so a
  long AGENTS.md does not follow the reviewer into the prompt; with no such heading the whole
  file is sent, because how much context to hand over is the repository's choice. The summary
  line reports `context=<file>` so a review given the repo's facts is distinguishable from one
  that was not. It reaches the model through pr-agent's `[artifacts]` channel: `repo_context_files`
  cannot, because the plain-diff provider implements neither `get_repo_file_content` nor
  `get_repo_context_ref`, leaving `build_repo_context` empty for a `--stdin` run. The file carries
  facts, never verdicts - suppression is what the tier and the gate's opt-outs are for - and it is
  read from the working tree, unlike pr-agent's and Codacy's config files, because this is a local
  pre-commit harness where the file is committed and therefore part of the diff under review.
  Guarded by `REQ-HOOK-40` (14 mutations confirmed). Every artifact setting comes from the
  environment, not `preflight.toml`: pr-agent injects the artifact *before* it loads
  `--extra_config_url`, so an `[artifacts]` section there is read too late - the first version set
  `artifact_label` in config and the prompt still said `CI Artifact: context.md`. CI now asserts the
  section stays out of that file. The section extraction skips fenced code blocks, so a shell comment
  or a fenced example cannot end the section and silently drop the facts after it, and the prompt's
  artifact label names the file actually used, so it cannot disagree with `PREFLIGHT_CONTEXT_FILE`.

- **`preflight-gate`'s policy is configurable, with machine, repo and environment layers.** The gate's
  tunables - which file types count as documentation (`doc_suffixes`), whether a documentation finding
  blocks (`doc_blocks`), whether key issues are ignored (`allow_issues`), and the effort ceiling
  (`max_effort`) - now come from two optional TOML files: `$PREFLIGHT_HOME/gate.toml` (created from
  `files/gate.toml.example` on install, only if absent) and a repo-local `./.preflight-gate.toml` that
  overrides it. The `PREFLIGHT_GATE_*` environment variables still override both, so nothing that worked
  before changes. Every key has a built-in default. A malformed file warns and falls back rather than
  crashing (a crash is a non-zero exit, which the commit hook reads as "the review did not pass"), and on
  a Python older than 3.11 - where stdlib `tomllib` is unavailable - no file is read and a present file
  warns, because an unrunnable gate would fail closed and block every commit. Every key in the shipped
  template is commented out, so an untouched install and no file behave identically and the built-in
  defaults stay the single source of truth; a live key would freeze today's default into every machine
  and silently override a later change to it.

  One rule covers every key: a value that is *present but invalid* is reported and the value already
  in force is kept - never silently dropped, and never coerced permissively - so a repo cannot come to
  believe its policy is loaded when it is not. The keys name only how to validate their own value;
  the warning, the fallback and the precedence are shared, so a new key cannot invent its own failure
  behaviour. Each value's accepted domain is a WHITELIST rather than a list of rejected cases: a
  suffix must match one extension shape (a dotless `"txt"` is normalised to `.txt` and reported; a
  path fragment, `.`, an empty string or a non-string entry is invalid), and a boolean accepts
  `true`/`false` and the `1`/`0` mirror only - "any non-zero number is true" would let
  `allow_issues = 2` disable the key-issue check. A blacklist is unbounded, and each of those was a
  bug found in turn. A finding's tier is kept consistent with the verdict - a waived key issue prints
  `[waived]` and is counted rather than still reading `[blocking]` - and an empty `doc_suffixes`
  entry invalidates the whole list instead of being dropped with the rest applied. Guarded by
  `REQ-HOOK-39`, whose invalid-value cases are driven from a table rather than per-key assertions.
- **Findings on documentation no longer block a commit.** pr-agent's finding schema has no severity
  field, so `preflight-gate` failed on every finding alike - a typo in a README counted the same as a
  bug in the hook. The gate now derives a tier from each finding's **file type**: documentation
  (`.md`, `.markdown`, `.rst`, `.adoc`) is **advisory** - still printed, tagged
  `[advisory]`, and counted separately - while everything else, including code under `docs/` and a
  `requirements.txt`, blocks as before. "Advisory" means the finding does not fail the gate on its own:
  `merge_recommendation = changes_required` and `security_concerns` still fail regardless of tier. Because the tier is applied inside the gate, it reaches the commit hook for
  free: `preflight` records the gate's exit as the sidecar verdict, and the hook reads that. Advisory by
  default, so the old strict behaviour is `PREFLIGHT_GATE_DOC_BLOCKS=1`. The path is normalised before
  matching, since real payloads carry a trailing newline in `relevant_file` (`'README.md\n'`), which a
  naive `endswith('.md')` classified as code. Guarded by `REQ-HOOK-38`, whose mutations were each
  confirmed to fail the case.
- **`preflight`'s summary line now carries `risk=` and `merge=`.** `merge_recommendation` is one of the
  four fields `preflight-gate` fails on, and it previously appeared only in the gate's own output - so
  `preflight review` could report a change that the gate would then refuse, discoverable only by running a
  second command. `risk_level` is reported for the reader and **not** enforced: the gate reads it only to
  print it, so `risk=low` alongside real findings passes regardless (`risk=low` with two key issues was
  observed). **Every** field on the line degrades to `n/a` when the model omits it - a lesson learned
  twice: the first version of this change handled `risk`/`merge` and left `effort` printing `effort=None`,
  and fixing that revealed `tokens` doing the same. Both were found by reviewing the change with the tool
  itself, and both are now asserted (`REQ-HOOK-35`), including a sweep for any literal `None`.
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

- **The `commit` scope never showed untracked files to the model, while the hook accepted them as
  reviewed.** The diff handed to pr-agent was a bare `git diff HEAD`, but the scope's own comment said
  `git diff HEAD <tree>`. The snapshot tree is built with `git add -A` and stored as `reviewed_tree`,
  which is what the pre-commit hook compares against - so a new file was simultaneously never reviewed and
  accepted as reviewed, and a defect in it could be committed with the containment check passing. Verified
  before the fix: with a new file containing a divide-by-zero the model was handed no diff for it at all,
  while `ls-tree reviewed_tree` listed it. The diff is now taken against the snapshot tree with an explicit
  `HEAD` base. `REQ-HOOK-37` records what the stub `pr-agent` received, and reverting fails it.
- **A malformed review took the whole summary line with it.** The line's fields are read by an agent, so
  each now degrades to `n/a` instead of raising: `security_concerns` was still coerced with a raw
  `.strip()`, so a JSON boolean (which the model returns, and which `preflight-gate` has its own guard for)
  raised `AttributeError`; `key_issues_to_review` fed `len()` directly, so `"no issues"` reported
  `issues=9`; and a `review` or `usage` that was not an object raised before any field was read. The gate's
  verdict is unchanged - it still exits 3 on a malformed review - this only keeps `issues=`, `new=` and
  `coverage=` visible. `REQ-HOOK-35` covers all three shapes.
- **The `post-commit` advisory warned on every default-scope commit, and named a scope that no longer
  exists.** It recognised only `scope=worktree` as enforced, but `commit` became the default scope - and
  `files/preflight-hook` accepts `commit|worktree`. So the common case printed *"the last review used
  scope=commit, so this commit was NOT verified by the hook"* for a commit that the hook had in fact
  enforced, and told the reader to re-run with *"the default worktree scope"*, which had stopped being the
  default. Found while reviewing the hook's own comments. `REQ-HOOK-27` now asserts `commit` is silent;
  reverting the fix fails it.
- **The documented way to install the commit hooks could produce a hook git ignores.** The recipe said
  `cp ~/.config/preflight/githooks/* .githooks/`. `cp` preserves the source mode, so it works on a machine
  where `install.sh` put the files down - but git **ignores a hook that is not executable**, printing a
  hint and committing anyway, and what a *fresh clone* obeys is the mode recorded in the index, not the
  installer's. A repo whose hooks ever lost that bit enforces nothing while looking completely installed,
  which is the failure this bundle exists to make impossible. Verified directly: a clone of a repo whose
  hooks are committed `100644` accepts an unreviewed commit, exit 0.

  The recipe is now `install -m 0755` **plus** `git update-index --chmod=+x` in every place it appears
  (`README.md`, `AGENTS.md`, `AGENTS-review-snippet.md`, `CONTRIBUTING.md`, `install.sh`'s own
  instructions, and the suite's fixtures). The second step is not belt-and-braces: it was verified that
  where git runs with `core.fileMode=false`, `git add` records `100644` however the file was installed,
  and `update-index --chmod=+x` is the way to force `100755` into the index that a clone obeys.
  `REQ-HOOK-36` checks the shipped files are executable both on disk and as committed, and skips the
  index half - reporting why - when `$repo_root` is not a git working tree, so a source tarball does not
  turn a missing `.git` into a reported defect.
  `docs/TROUBLESHOOTING.md` now lists this first under "the hook never blocks anything", because it is the
  cause that looks like a working install.
- **`--help` still described the old default scope.** After the pending commit became the default review
  scope, the usage text said `review` was a "review of the working tree vs the base branch" - the branch
  behaviour it no longer has by default, and a base it never resolves in that scope. `preflight --help`
  and the script header now describe the pending change, and name `PREFLIGHT_SCOPE=worktree` for the
  branch review.
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

- `config.fallback_models` no longer points at a model the ClinePass endpoint cannot route. The
  upstream default (`["gpt-5.6-terra"]`) is a bare id, which the endpoint rejects (ids must be
  `provider/model`), so a failed primary model retried against a dead one; it is now
  `["openai/cline-pass/glm-5.3-flash"]`.

### Changed

- **`files/preflight.toml` no longer sets `pr_reviewer.extra_instructions` or `[config] reasoning_effort`.**
  Both are removed, so pr-agent's own reviewer prompt and its own `medium` reasoning default apply.

  The `extra_instructions` text was the more consequential of the two. Capturing the literal request
  pr-agent sends - a local endpoint that logs the body and returns a canned review, so no key and no cost -
  showed it appended to a system prompt that already says, in the same payload: *"For lower-severity
  concerns, be certain before flagging... do not flag it"*, *"Otherwise, prefer not reporting over
  guessing"*, and, in the schema description, *"An empty list is acceptable if no clear issues are
  found."* Our text said *"Report EVERY issue you are confident about... If you find one issue, keep
  looking: most real diffs have several."* That sentence was the only content in an ~8,000-character
  prompt pushing toward **generating** findings rather than filtering them - the opposite of the loop
  converging, which is what the bundle exists to achieve. The prompt is now sent unmodified; the effect on
  finding volume is an open experiment in `ROADMAP.md`, not a settled result.

  `reasoning_effort = "low"` and the `additional_reasoning_effort_models` that existed only to forward it
  are removed on the evidence rather than on principle. The pin rested on interleaved arms measured on one
  synthetic 525-line diff (mean ~18.6s / ~4,051 completion tokens unforwarded versus ~9.2s / ~1,689 with
  `low`). Four consecutive reviews of this repo's own branch, at `low`, spent 23k-34k completion tokens -
  60-68% of each run's total - and ranged 1m19s-2m30s on similar diffs, so the synthetic figure was not a
  predictor of real content. CI now asserts these keys are **absent**, so neither can return silently.

- **`require_risk_assessment = true` is removed, and the `[pr_code_suggestions]` override with it.** Both
  asked the model for more output that nothing acts on: `risk_level` is only *printed* by the gate (the
  verdict comes from effort, security, `merge_recommendation` and issues), and it measured unstable -
  `low, low, medium, low` across four reviews of this repo while `merge_recommendation` never moved off
  `merge_with_caution` - so requiring it bought a go/no-go-looking field with no signal in it.
  `num_code_suggestions_per_chunk = 20` (upstream 3) is the same nudge as `num_max_findings`, applied to
  `preflight improve`, and is reverted for the same reason. CI asserts both stay unset.
- **Comments in `files/` no longer narrate their own history.** Shipped files and the operator docs now
  state what a value *is* and why; what it replaced, what was measured, and what was reverted live in this
  changelog. `files/preflight.toml` was 73% comments (61 of 84 lines) after a single documentation pass and
  is now 48%, with the reasoning it lost recorded here. The rule is written into `AGENTS.md`, with the test
  "if deleting a comment would not change a reader's next action, it belongs in the changelog or nowhere".
- **`files/preflight`'s own commentary was cut to what is load-bearing**: 210 comment lines of 564 (37%)
  to **137 of 491 (28%)**. The densest blocks were the coverage-marker section, the summary function and
  the review-job block; what survives is the non-obvious reasoning - why the coverage marker matches
  emitted structure rather than the model's words, why both waits are bounded, why the hook's binding is
  content- and not time-based, and each trap already hit here. Only comments and two `--help` strings
  changed; no executable line was touched.
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
- The repository is public at <https://github.com/413x5/preflight>, default branch `main`, and the
  initial commits plus the `v0.1.0` tag are **GPG-signed** (the signed history replaces earlier unsigned
  commits).

[Unreleased]: https://github.com/413x5/preflight/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/413x5/preflight/releases/tag/v0.3.0
[0.2.0]: https://github.com/413x5/preflight/releases/tag/v0.2.0
[0.1.0]: https://github.com/413x5/preflight/releases/tag/v0.1.0
