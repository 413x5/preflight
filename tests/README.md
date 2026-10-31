# Tests

Integration tests for the preflight commit hook. No framework, no network, no API key:

```sh
./tests/run.sh           # everything (~1–4 min; the live case needs a configured key)
./tests/run.sh hook      # hook enforcement only, fully offline (seconds)
./tests/run.sh selfcheck # the suite re-run against a neutered hook (see below)
./tests/run.sh e2e       # the one case that calls the real endpoint
```

## Why integration tests rather than unit tests

Every bug found in this hook lived in **how git reports a staged change**, not in any comparison
function that could be unit-tested:

- a rename is status `R` — neither `A` nor `M` — so `--diff-filter=AM` reports *no change at all*;
- a changed file type is `T`, with the same consequence;
- a gitlink (submodule) is not a blob, so `cat-file -e "HEAD:sub"` fails for it;
- an untracked scratch file appears as a **deletion** in the reviewed-to-staged comparison;
- `git rm --cached` removes a path from the index while leaving the file on disk;
- `--name-only` without `-z` **quotes** any path that needs it, so a name handed back to git belongs
  to no file at all.

So the tests drive **real repositories** through the **real hook files** in `src/`, and assert on the
commit's exit code. Each test builds a throwaway repo from `tests/sample/`.

## How a review is simulated

A worktree-scope review records the tree it handed to the model. `review_here` reproduces that using
the same scratch-index method `preflight-code` itself uses (`read-tree HEAD` + `add -A` + `write-tree`) and
writes the sidecar a passing review would have written. That keeps the suite offline and deterministic
while still exercising the real comparison, and the scratch index is kept **outside** the repo so it can
never appear in a snapshot.

## Traceability

Each case declares the requirement it guards. The mapping is one-to-one with the behaviour it protects,
and every previously-fixed bug has a case that fails if the fix is reverted. Hook cases use `REQ-HOOK-nn`;
the selfcheck itself is `REQ-SELF-nn`, listed in its own table below.

| Requirement | What it asserts | Guards against |
|---|---|---|
| REQ-HOOK-01 | An edit after the review is blocked | the core content binding |
| REQ-HOOK-02 | A new unreviewed file is blocked | superset-style checks that let new files through |
| REQ-HOOK-03 | `git rm` of a reviewed file is blocked | deletion of reviewed code going unnoticed |
| REQ-HOOK-04 | `git rm --cached` of a nested reviewed file is blocked | the slash-skip special case that let a nested guard be un-indexed |
| REQ-HOOK-05 | Renaming a reviewed file away is blocked | `--diff-filter=AM` missing status `R` |
| REQ-HOOK-06 | Swapping a reviewed file for a symlink is blocked | `--diff-filter=AM` missing status `T` |
| REQ-HOOK-07 | `commit -a` with an untracked scratch file passes | strict tree equality (the reason containment was chosen) |
| REQ-HOOK-08 | A reviewed deletion passes | over-blocking; re-review must be able to accept a removal |
| REQ-HOOK-09 | A reviewed rename passes | over-blocking on status `R` |
| REQ-HOOK-10 | An empty commit after a clean review passes | false blocks when nothing is staged |
| REQ-HOOK-11 | No review at all is blocked | the baseline guarantee |
| REQ-HOOK-12 | A failing gate verdict is blocked | the verdict being ignored when content matches |
| REQ-HOOK-13 | An unusable reviewed tree is blocked | failing open when the comparison cannot run |
| REQ-HOOK-14 | `--no-verify` bypasses | the documented escape hatch |
| REQ-HOOK-15 | `PREFLIGHT_SKIP=1` bypasses | the documented escape hatch |
| REQ-HOOK-16 | A head-scope review is allowed **but reported as not enforced** | silently pretending to enforce |
| REQ-HOOK-17 | The first commit of an empty repo is allowed, with a notice | the adoption deadlock (review needs HEAD) |
| REQ-HOOK-18 | Enforcement is active again on a later commit | the bootstrap allowance leaking into later commits |
| REQ-HOOK-19 | A blocked commit leaves the index and HEAD untouched | the hook not being read-only |
| REQ-HOOK-20 | Review artifacts survive a block | deleting the findings a human needs to read |
| REQ-HOOK-21 | The hook enforces inside a linked worktree | an absolute `core.hooksPath` breaking worktrees |
| REQ-HOOK-22 | A missing helper fails closed | the helper being absent letting commits through |
| REQ-HOOK-23 | A real review then commit passes end to end | the simulated review drifting from the real one |
| REQ-HOOK-24 | Deleting a reviewed file whose name needs quoting is blocked | `--name-only` without `-z` quoting the path turned a tracked file into a nonexistent one, so its deletion looked like an untracked scratch file |
| REQ-HOOK-25 | Removing a reviewed gitlink (submodule) is blocked | `git cat-file -e "HEAD:sub"` failing for a gitlink, so a submodule removal counted as "not tracked at HEAD" |
| REQ-HOOK-26 | The example hook reports a missing helper when `HOME` is unset | `set -u` plus a bare `$HOME` aborting with "HOME: unbound variable" instead of the documented message |
| REQ-HOOK-27 | The `post-commit` advisory warns when it cannot read the review sidecar | the advisory exiting 0 on a missing `python3` or a malformed/scope-less sidecar, making it silent in exactly the case it exists to report |
| REQ-HOOK-28 | The coverage marker matches pr-agent's footer and ignores prose, including a verbatim quote of the footer inside the review table | the marker keying on text alone - one phrase, two substrings, or the contiguous sentence each false-positived on a real review that discussed coverage; and the footer being reworded upstream, which would silently retire the marker |
| REQ-HOOK-29 | The keys the bundle sets sit in the section pr-agent reads them from; the example file lists **every** key pr-agent declares there (the bundle's live, the rest commented at upstream's value), and a commented entry is checked against the installed pr-agent for a **stale value**, for a key upstream declares but the file omits, and for an **orphan** naming a key pr-agent does not declare at all (a no-op left by a key removed or renamed upstream); **and** the shipped `FALLBACK_RE` compiled over the run-details wording read from pr-agent's own `run_output.py`, so a reworded marker line fails there rather than silently never firing (the fixtures in `REQ-HOOK-42` agree with whatever the regex says, so they cannot show it); **and** every config path the docs name exists in pr-agent's own defaults | a key in the wrong table (or renamed upstream) leaving the finding cap silently inert while CI, which only checks presence, stays green; a `[pr_reviewer]` knob pr-agent adds, renames, re-defaults or REMOVES, any of which leaves the steering list quietly wrong - the removed case being the one the value and omission checks cannot see, since neither looks at a key upstream no longer has, so the entry stays and reads as configurable; and documented advice pointing at a path pr-agent ignores - which fails silently for whoever follows it, as `config.callback_timeout_seconds` once did (it is `[litellm]`). The scan reads **every tracked doc** - the glob is compared against `git ls-files docs`, so a doc can no longer fall out of scope by the docs tree gaining a subdirectory - and a line that names a path in order to warn it does *not* exist says so inline with `doc-path-ok: <why>` |
| REQ-HOOK-31 | The convergence signal: `new=N/M` counts new findings, `new=0` flags repeats with the judge-don't-refix hint, and the field is absent on a first or unreadable previous review | a count that never converges (repeats read as new), stops early (a new finding is misread as a repeat), or claims a signal it cannot support; the branch had no test at all, and its assertions sat inside a case that skips wherever pr-agent is absent - i.e. always, in CI |
| REQ-HOOK-33 | `commit` is the default scope (it reviews the pending change, not the branch), `worktree` still resolves a base and keeps the branch diff, and an unknown scope is refused with exit 2 | a silent regression of the default back to a branch scope, which would make every review a whole-branch review - the cost problem the scope exists to fix - while still producing a valid review, so nothing else would notice; or the branch machinery being lost while the scope name still claims it works |
| REQ-HOOK-32 | A hung shutdown still reports the counts, bounds its wait, stops the stalled process, and lets the run succeed with its sidecar written | the post-run hang swallowing `issues=`/`new=` (they were printed only after the call returned), blocking the loop forever, or - the subtler half - turning a complete, usable review into a failed run that then blocks the next commit. The case drives a fake `pr-agent` that writes the artifacts and hangs, so it needs no key or network; it runs the helper under its own watchdog, because a regression here hangs rather than fails, and a test that stalls the suite reports nothing |
| REQ-HOOK-30 | A real `review.md` renders the `</table>` the coverage marker's structural restriction relies on | plain-diff output no longer emitting the table, which would make that restriction inert on real reviews; a missing `review.md` fails rather than vanishing, so the requirement cannot retire silently (the case rides in the live run, so it is not exercised where no live review can run) |
| REQ-HOOK-34 | The summary line is **wired**: a run through the real helper prints `issues=` and claims no `new=` on a first review, then reports a repeated finding as `new=0/1` on the second | REQ-HOOK-31 testing the counting block in isolation and never the wiring around it - `emit_summary` not being called, or the previous review not being passed to the comparison, would leave a helper whose counting is perfect and which never reports a convergence signal at all. Driven by a stub `pr-agent` that writes the artifacts, so it needs no key or network and runs in CI |
| REQ-HOOK-35 | The summary line carries `merge_recommendation`, `risk_level`, effort and tokens (all reported, none enforced by the gate), and **every** field on the line degrades to `n/a` rather than printing a bare `None` | `merge_recommendation` appearing only in the gate's own output, so `preflight-code review` could report a change the gate would then refuse, discoverable only by running a second command; and an absent field printing an empty value or a literal `None`, which reads as a verdict rather than as "not reported". Reviewing this change with the tool itself found the leak **twice**: the first version handled `risk`/`merge` and missed `effort` (`effort=None`), and fixing that revealed `tokens` doing the same. Each time the missing assertion was why the case stayed green, so it now asserts the fields and sweeps for any literal `None`. This row deliberately does **not** call `risk_level` a gate input - it is not one (see [`docs/roadmap.md`](../docs/roadmap.md)) |
| REQ-HOOK-36 | The shipped `src/githooks/*` are executable on disk **and** committed as `100755` | git **ignores a non-executable hook** - it prints a hint and runs nothing - so a repo whose copied hook lost its bit enforces nothing while looking fully installed. Verified directly: a fresh clone of a repo with the hooks at `100644` accepts an unreviewed commit (exit 0). The documented recipe said `cp`, which preserves the source mode and so usually works, but the *committed* mode is what a clone obeys and a source file is one editor or patch tool away from losing its bit; `git add` also records `100644` under `core.fileMode=false`, which is why the recipe now forces the index mode with `update-index --chmod=+x`. The index half of this case **skips with a reason** when `$repo_root` is not a git working tree (a source tarball or "Download ZIP"), since `ls-files` there reports nothing and would otherwise be read as "not tracked" - a false defect instead of an unevaluated check |
| REQ-HOOK-37 | The `commit` scope hands the model every path a commit would contain, **including untracked files** | an untracked file is added to `reviewed_tree` by the snapshot's `git add -A`, so the hook compares against it - but a bare `git diff HEAD` never lists it, making a new file simultaneously unreviewed and accepted as reviewed. The diff handed to pr-agent is the only place this is observable, so the case records what the stub `pr-agent` received rather than what the sidecar says |

| REQ-HOOK-39 | The gate's policy is layered - the `[gate]` table of `$PREFLIGHT_HOME/settings.toml`, then a repo-local `./.preflight.toml`, then the `PREFLIGHT_GATE_*` env vars - and its ONE invalid-value rule holds for every key, driven from a table rather than per-key assertions: a value that is present but invalid is reported and the value already in force is KEPT (a malformed file and an unreadable file warn and fall back the same way), while an absent file leaves the built-in defaults | a policy that silently failed to load, leaving a repo believing its rules were in force while the built-in default decided its verdicts. This recurred once per key while each had its own setter - `doc_blocks = "ture"` falling back to the permissive default, `max_effort = true` coerced by `int(True)` into a ceiling of 1, an empty `doc_suffixes` entry making every path advisory, a bad value in the repo-local file masking the home file's - so the rows below are organised by the contract, and a new key needs a table row, not another bespoke assertion. A malformed config must also not crash: a non-zero exit is what the commit hook reads as "the review did not pass" |
| REQ-HOOK-38 | The gate derives a tier from each finding's file type: a documentation finding (`.md`, `.markdown`, `.rst`, `.adoc`) is tagged `[advisory]`, reported in the `advisory=` count, and does **not** fail the gate; a finding on code, or with no file, still blocks - **including code under `docs/` and a `requirements.txt`**; `PREFLIGHT_GATE_DOC_BLOCKS=1` makes documentation block again **and relabels it `[blocking]`** | a documentation typo blocking a commit as hard as a bug - the model's finding schema has no severity field, so before this every finding was fatal; a tier keyed on the directory rather than the file type, which a `conf.py` or build script under `docs/` would slip through; a `.txt` treated as prose, which would make a vulnerable dependency pin in `requirements.txt` advisory, or an `.mdx` treated as prose, which would make a component bug advisory (the reviewer raised each on this change); and, in strict mode, a promoted finding that still printed `[advisory]` while the gate exited 1, a label contradicting its own verdict. The case drives the **real gate** over fixtures with a real trailing newline in `relevant_file` (the shape real payloads carry), because a naive `endswith('.md')` classifies every doc finding as code and the advisory tier then never fires |
| REQ-HOOK-40 | The repository's review context reaches the model: a `Code review` heading in AGENTS.md is extracted and sent **alone**, a subsection stays with its section, a later top-level section is excluded, a heading or `#` inside a fenced block does not end it, the rest of the file is not sent alongside it; with no such heading the **whole file** is sent; with no file at all nothing is exported or claimed; the summary line reports which happened; and the prompt's artifact label names the file actually used, so it cannot disagree with `PREFLIGHT_CONTEXT_FILE` | a reviewer that never receives the repository's facts, so a deliberate, documented trade-off is reported as a defect (the `.preflight.toml` trust boundary was raised three times); OR a section rule that leaks the whole AGENTS.md into every prompt, defeating the point of the section; OR context claimed on the summary line when none was sent. The case drives a stub `pr-agent` that records what it was handed, because what the model was SHOWN is only observable there |
| REQ-HOOK-41 | Every run that SUCCEEDS AND PRODUCES OUTPUT is archived under `$dir/runs/<id>/` with a `run.json` carrying `started_at`, `finished_at`, `duration_seconds`, `stopped`, `artifacts` and the gate verdict; two runs leave two directories with the first **intact**; `describe` is archived with **only** its own `description.md` and `run.log`; a FAILED run is archived nowhere, including one that exited non-zero *after* writing its artifact; and a run that produced nothing leaves no directory. pr-agent's console output is captured to `run.log` and archived with the run as its **log records**, opening with the invocation the bundle made (config named by role, never by path) - ANSI colouring stripped and the rendered review dropped, since `review.md` carries it - the archived copy holds **this** run's output, a stream in no recognised shape is kept whole, and a FAILED run prints what it captured instead of swallowing it; the fixed top-level paths keep meaning "the latest run", and every archived artifact is provably this run's - including the sidecar, whose write is guarded | a run's output being destroyed by the next run: `preflight-code` removes `review.json`/`review.md` before launching (phase 1 polls for the file, so a stale one would report the previous run's counts), and that removal is load-bearing - so the run it removes has to be preserved elsewhere, or the history this case checks cannot exist. Also a constant run id, which would collapse every run into one directory; an empty run directory, which reads as a run whose artifacts went missing; and, the sharp edge, a FAILED run being credited with artifacts it did not write - the fixed paths are not deleted before a `describe`/`improve`/`ask` launch, so after a failed run they still hold the *previous* run's file, which archiving on "the artifact exists" filed under the failed run. Two rounds of reviewing this change with the tool found that one and the `describe` variant. Driven by a stub `pr-agent` that DRAINS STDIN - one that exits without reading kills the writing side with SIGPIPE, which the helper reads as a failed model call |
| REQ-HOOK-42 | The summary line reports `model=FALLBACK` when pr-agent's run details say a fallback model answered, in both the singular `Model: ... (fallback)` and plural `Models: ... (includes fallback)` shapes, and stays **quiet** when the configured model answered or no run details are present | the failure this exists to expose: a review answered by the fallback model is indistinguishable from one answered by the configured model - `issues=0` reads as clean, the gate passes, and the only other trace is prose at the bottom of `review.md`. It is the same shape the bundle guards against everywhere else, an inability to check that is indistinguishable from a pass. Both directions are asserted, because a marker that always fires would satisfy the positive cases alone (checked by making it fire unconditionally, when every quiet case fails). pr-agent's plain-diff JSON carries no model field, so the signal is read from `review.md`'s run-details block, after the last `</table>` so a finding quoting it cannot fire the marker |
| REQ-HOOK-43 | A pruned diff announces itself on the summary line in the **default `commit` scope**, not only the branch scopes - driven through the real helper with a stubbed `pr-agent` that writes pr-agent's own coverage footer | the marker was gated on the branch scopes on the reasoning that a pending-commit diff is far below the token budget, which holds for ordinary changes and fails for a large one; since the bundle does not chunk, pruning is what happens to an over-budget diff, so a commit-scope review of a slice printed a clean summary line with nothing saying the rest was unread. The gate was invisible because `REQ-HOOK-28` exercised the marker's matching with the branch flag set, and no case ran the default scope at all |
| REQ-HOOK-44 | A named model configuration is rendered into the single config pr-agent is launched with: driven through the real `src/preflight-code` with a stubbed `pr-agent` that copies the config it was handed, the case asserts the file is the rendered one and not empty, that it carries the named provider's endpoint, key and derived transport pin, that an unrelated provider's streaming workaround does not survive, and that the per-run file is 600-mode and deleted by the run that wrote it, with a 600-mode copy left at the fixed name for inspection | a run launched with no config at all looks identical in the output, and would answer on pr-agent's own defaults; a pin taken from anywhere but the provider entry routes the request to the wrong host, which LiteLLM resolves silently; an inherited streaming pair fires on a host the user never connected to it; a config dir inside a repository, with the rendered path not ignored, leaves the provider's credential in the diff the review is handed |
| REQ-HOOK-45 | Every configuration that cannot be applied is refused **by name**, and no review runs: a chain spanning two providers, a provider no `[providers.*]` table defines, a profile naming no provider, a profile-level `litellm` section, a transport pr-agent cannot route, an `api_base` on a transport that reads none, and an assignment with no resolver installed | each of these is answered by pr-agent without an error - the pinned provider's host serves the other model's request, or the profile's settings are dropped - so a run that proceeds is a review the user cannot tell apart from a correct one |
| REQ-HOOK-46 | `preflight-pr` removes the per-run rendered config its own EXIT trap owns, reports pr-agent's exit status rather than a cleanup failure, and passes the caller's stdin through to pr-agent - driven against a stub `pr-agent` that reads stdin and then exits 3 | the renderer's cases drive `src/preflight-code` and the renderer directly, so a trap in this helper that called a function the renderer no longer defines, or dropped its `rm`, leaked one credential-bearing 600-mode file per run and hid the real exit status behind 127, with the suite green |
| REQ-HOOK-50 | The per-run rendered config can be written outside a read-only config dir: with `PREFLIGHT_HOME` at mode 0555 the review still completes, the file pr-agent is handed is under a per-run temp directory, both the directory and `PREFLIGHT_RENDER_DIR` are named on stderr, the file is 600-mode and removed by the run; `PREFLIGHT_RENDER_DIR` is honoured and the config is still read from `PREFLIGHT_HOME`; an unwritable explicit render dir REFUSES rather than falling back; and a render dir inside the reviewed repository is refused unless that exact file is gitignored there | a read-only config dir (a sandbox, a shared checkout) failed every review, and the operator workaround was to copy the whole config dir somewhere writable - which lets the copy drift from the one being edited. The move must not reopen the key-leak either: a render dir inside the reviewed tree is handed to the model by the `git add -A` snapshot, and a DIRECTORY-level ignore check cannot see it, because an empty scratch dir holds nothing to find until the credential is written into it - so the check asks git about the file itself |
| REQ-HOOK-51 | A review pr-agent exits 0 having written nothing for is a FAILED run that names the cause and never claims to have written a file that is not there, while an ordinary run still reports the artifacts it wrote | pr-agent 0.49 returns success and writes neither artifact when every changed file is filtered out ("PR has no analyzable files ... skipping review"). The helper printed `wrote .preflight/review.md and .preflight/review.json` over files that did not exist, and the commit hook then blocked with "no review found" - an unexplained block after a run that looked clean. 0.47 raised on the same input instead of skipping it, so the upgrade had turned a loud failure into a false success. Both directions are asserted, because "never says wrote" is satisfied by a helper that says nothing at all |
| REQ-HOOK-52 | pr-agent's structured `coverage` object carries the two keys the helper reads (`files_not_reviewed`, `files_partially_reviewed`), and the shipped summary block still reads `review.json`'s `coverage` object - checked against the INSTALLED package's own emitter, and SKIPPED with a reason on a package that writes no object (0.48 and earlier) | pr-agent 0.49 added the object and the helper reads those two names, so a rename upstream would silently retire the structured half of `coverage=PARTIAL`; the footer fallback would keep this suite green, which is exactly the drift the case exists to catch |
| REQ-HOOK-47 | A review that has written nothing yet says so on stderr at `PREFLIGHT_PROGRESS_EVERY` intervals, and stays quiet once the artifact exists - a stub `pr-agent` that sleeps against one that writes its artifacts immediately | phase 1 waits up to `PREFLIGHT_REVIEW_WAIT`, so a wedged endpoint and a slow review were both an hour of silence: the operator had no output to tell them apart, and the only discovery was the bound expiring |
| REQ-HOOK-48 | A review killed by a signal leaves no `pr-agent` behind - the stub writes its own pid to a file and `exec`s a long sleep, so the case watches the exact child; the helper is killed with `TERM` and the case asserts that pid is gone | `cleanup()` removed the per-run rendered config but never reaped the child it launched, so an abnormal exit (a signal, an arithmetic error under `set -e`) left `pr-agent` running. It holds the caller's stdout pipe open, so `x="$(preflight-code review)"` blocks for the length of a model call after the script is gone: the bug reads as a hang in the wrong process, and no test covered an exit that is not the normal one |
| REQ-HOOK-49 | `preflight-pr` killed by a signal leaves no `pr-agent` behind - the same pid-file stub and `TERM` as REQ-HOOK-48, driven through `src/preflight-pr` | the twin leak in the sibling helper: it launched pr-agent as a child with no captured pid, and its EXIT trap removed only the rendered config, so a killed PR run blocked the caller's stdout for the length of a model call. REQ-HOOK-48 covered `preflight-code` only, and the two helpers share the launch shape, so fixing one left the other able to reproduce the same hang |

The selfcheck is its own requirement, since it checks the suite rather than the hook:

| Requirement | What it asserts | Guards against |
|---|---|---|
| REQ-SELF-01 | A neutered hook fails exactly the declared enforcement-sensitive cases, every case is classified, and the child run actually produced results | a case claiming to test enforcement that passes with the hook disabled; the insensitive set growing by default; the child suite silently running nothing |

## Mutation-checked

The suite is only worth its runtime if it actually fails when the behaviour breaks, so each fix was
reverted in turn and the expected case was confirmed to fail:

| Reverted | Case that failed |
|---|---|
| `--diff-filter=ACMRTU` back to `AM` | REQ-HOOK-05, REQ-HOOK-06 |
| the deletion (`D`) comparison dropped | REQ-HOOK-03, REQ-HOOK-04 |
| the `HEAD` discriminator dropped (every `D` is "real") | REQ-HOOK-07 |
| the slash-skip special case re-added | REQ-HOOK-04 |
| the verdict check removed | REQ-HOOK-12 |
| the fail-closed guards replaced with `\|\| ""` | REQ-HOOK-13 |
| the no-`HEAD` bootstrap allowance removed | REQ-HOOK-17 |
| the `PREFLIGHT_SKIP` bypass removed | REQ-HOOK-15 |
| the head-scope notice removed | REQ-HOOK-16 |
| the `-z` deletion listing replaced by the quoted one | REQ-HOOK-24 |
| the `ls-tree` discriminator replaced by per-path `cat-file` | REQ-HOOK-24, REQ-HOOK-25 |
| `${HOME:-}` reverted to a bare `$HOME` in the example hook | REQ-HOOK-26 |
| the `post-commit` advisory's unreadable-sidecar guards restored to `exit 0` | REQ-HOOK-27 |
| `COVERAGE_RE` weakened to a bare phrase, or the structural `<table>` gate dropped (so an in-table quote of the footer counts) | REQ-HOOK-28 |
| the keys the bundle sets moved out of `[pr_reviewer]`, or one renamed | REQ-HOOK-29 |
| a `[pr_reviewer]` knob dropped from the example file's list | REQ-HOOK-29 |
| a commented `[pr_reviewer]` entry for a key pr-agent does not declare (an orphan left by a key removed upstream), so the advice is a silent no-op | REQ-HOOK-29 |
| pr-agent reworded its run-details fallback marker (mutating `run_output.py`'s `(fallback)` literal), so the marker regex stops matching real output while its fixtures still pass | REQ-HOOK-29 |
| the docs scan made non-recursive again (so `docs/runbooks/troubleshooting.md` leaves its scope) | REQ-HOOK-29 |
| the `doc-path-ok:` escape ignored, so a doc that names a non-existent key to warn against it is read as advice | REQ-HOOK-29 |
| the live case's `review.md` presence turned back into a skip (so REQ-HOOK-30 can vanish instead of failing) | REQ-HOOK-30 |
| `key()` normalisation dropped, or the `new=` count no longer suppressed on a first review | REQ-HOOK-31 |
| the shutdown bound disabled (a plain blocking `wait`) | REQ-HOOK-32 |
| the exit status normalised on `stopped` alone (so a hang that wrote no review exits 0) | REQ-HOOK-32 |
| the default `PREFLIGHT_SCOPE` reverted to `worktree` | REQ-HOOK-33 |
| the `worktree` scope made to diff HEAD, losing the branch diff | REQ-HOOK-33 |
| an unknown `PREFLIGHT_SCOPE` silently accepted instead of exiting 2 | REQ-HOOK-33 |
| the previous review not passed to the comparison (`PREFLIGHT_PREV_JSON` never exported) | REQ-HOOK-34 |
| `risk_level` dropped from the summary line, or read but always degraded to `n/a` | REQ-HOOK-35 |
| `effort` interpolated raw with no fallback, so an omitted value prints `effort=None` | REQ-HOOK-35 |
| `tokens` interpolated raw with no fallback, so a payload without `usage` prints `tokens=None` | REQ-HOOK-35 |
| the executable bit stripped from `src/githooks/pre-commit` (on disk) | REQ-HOOK-36 |
| the `commit` scope made to diff `HEAD` instead of the snapshot tree, so untracked files leave the reviewed diff | REQ-HOOK-37 |
| `security_concerns` coerced with a raw `.strip()` again, so a boolean payload kills the summary line | REQ-HOOK-35 |
| `key_issues_to_review` left un-coerced, so a non-list reports a wrong count or loses the line | REQ-HOOK-35 |
| a non-object `review` or `usage` left unguarded, so the summary line is lost before any field is read | REQ-HOOK-35 |
| the documentation tier removed (every path blocking), or applied to every path | REQ-HOOK-38 |
| the doc suffix list emptied, so no file is documentation | REQ-HOOK-38 |
| `.txt` added back to the doc suffixes, so a `requirements.txt` finding becomes advisory | REQ-HOOK-38 |
| `.mdx` added back to the doc suffixes, so a component bug on an executable-Markdown file becomes advisory | REQ-HOOK-38 |
| the repo-local `.preflight.toml` not read | REQ-HOOK-39 |
| the environment no longer overriding the config files | REQ-HOOK-39 |
| a policy value from the config file ignored | REQ-HOOK-39 |
| **the invalid-value contract inverted** - an invalid value dropping the key to the hardcoded default instead of keeping the value in force (8 rows), the invalid value applied as-is (4 rows), or an empty `doc_suffixes` entry honoured (1 row) | REQ-HOOK-39 |
| a malformed repo-local `.preflight.toml` raising instead of warning and falling back | REQ-HOOK-39 |
| an unreadable config file (a directory in its place) ignored silently instead of warning | REQ-HOOK-39 |
| a `tomllib`-less interpreter ignoring a present config file silently | REQ-HOOK-39 (verified by injecting a failing import; the row is not exercised by the suite, which cannot remove tomllib from its own interpreter) |
| the retired `PREFLIGHT_GATE_MAX_EFFORT` restoring a ceiling the gate no longer has, **or** an unparseable value failing the run | REQ-HOOK-39 |
| a retired `max_effort` left in `[gate]` ignored silently instead of reported as an unknown key | REQ-HOOK-39 |
| the gate reading the whole settings file, so `[pr_reviewer]` keys are reported as unknown gate keys | REQ-HOOK-39 |
| the gate applying a retired `gate.toml`/`.preflight-gate.toml`, or staying silent about a keyed one (while an inert one stays quiet) | REQ-HOOK-39 |
| the repo-local `.preflight.toml` resolved from the cwd rather than the repository root, so a gate run from a subdirectory silently falls back to the machine defaults | REQ-HOOK-39 |
| the repo-local `.preflight.toml` not overriding the review settings, replacing a whole section instead of merging it, applying without a repository scope, or leaking `[gate]` into the rendered config | REQ-HOOK-44 |
| a config assertion that cannot discriminate - a stale review fixture making the gate exit non-zero for an unrelated reason, so "kept the value" and "dropped it" give the same exit code | REQ-HOOK-39 |
| no `ARTIFACT_PATH` exported, so the context never reaches the reviewer | REQ-HOOK-40 |
| the `Code review` pattern never matching, so the whole file is always sent | REQ-HOOK-40 |
| the section never ending (the next same-or-higher heading not honoured) | REQ-HOOK-40 |
| the framing instruction emptied, so the context reads as instructions to approve | REQ-HOOK-40 |
| fence-awareness removed, so a `#` inside a fenced block ends the section early and silently drops the facts after it (found by reviewing this change with the tool) | REQ-HOOK-40 |
| the artifact label not exported, so the prompt header falls back to the filename (found by reviewing this change with the tool - the label had been set in `preflight.toml`, where it is applied too late to matter) | REQ-HOOK-40 |
| the section label always reported, so whole-file and section modes are indistinguishable | REQ-HOOK-40 |
| the artifact label naming a fixed file, so it disagrees with `PREFLIGHT_CONTEXT_FILE` and with the summary line (found by reviewing this change with the tool) | REQ-HOOK-40 |
| the heading match allowing zero spaces after the `#`, so a column-0 `#!/bin/sh` or `#hashtag` line ends the section and silently drops the facts after it (found by reviewing this change with the tool) | REQ-HOOK-40 |
| a bare `#` line's `None` title passed to a regex, so the extractor raises and the `(unreadable)` branch silently disables the whole feature (found by reviewing this change with the tool) | REQ-HOOK-40 |
| headings anchored at column 0 while the fence scan allows leading whitespace, so an indented section is not found and an indented later heading does not end it (found by reviewing this change with the tool) | REQ-HOOK-40 |
| a fence line with an info string treated as a CLOSING fence (CommonMark allows only whitespace after it), so a nested example ends the block and a heading-looking line inside it truncates the section (found by reviewing this change with the tool) | REQ-HOOK-40 |
| the extractor failing, so the context is reported unreadable and the feature is silently disabled instead of extracting (checked on the summary line, where the marker actually appears) | REQ-HOOK-40 |
| the summary line always reporting no context | REQ-HOOK-40 |
| `doc_blocks = 1` (a TOML integer) falling through to the permissive default | REQ-HOOK-39 |
| a boolean key accepting any non-zero number, so `allow_issues = 2` silently disables the check (the integer mirror is restricted to 0/1) | REQ-HOOK-39 |
| the `archive_run` call dropped from the `cleanup` trap (no run directory at all) | REQ-HOOK-41 |
| a constant run id, so the second run lands in the first run's directory and overwrites it | REQ-HOOK-41 |
| the `rmdir` of a run directory that received no artifact dropped, so an empty run is archived | REQ-HOOK-41 |
| the sidecar archived on `run_ok` alone rather than only for a `review` run, so a `describe` archives the previous review's `review.meta.json` and claims it as its own (found by reviewing this change with the tool) | REQ-HOOK-41 |
| the `run_ok` guard dropped, so a FAILED run is archived anyway - crediting it with the previous run's still-present `description.md`, and filing a run that wrote an artifact and then exited non-zero (found by reviewing this change with the tool) | REQ-HOOK-41 |
| the `python3` check moved after the `mkdir` (or disabled), so a run directory with no `run.json` is left behind and the documented `cat .preflight/runs/*/run.json` fails for it (found by reviewing this change with the tool) | REQ-HOOK-41 |
| `run.json` written without real timestamps or a numeric duration, so the record cannot answer "how long did this run take" (found by reviewing this change with the tool - the assertion was dead until then, because the Python block `print`ed its findings and exited 0) | REQ-HOOK-41 |
| the shared pre-launch removal of the output path dropped, so a `describe` whose agent exits 0 having written nothing archives the PREVIOUS run's `description.md` as its own (found by reviewing this change with the tool) | REQ-HOOK-41 |
| the `run.json` write's status ignored and its emptiness unchecked, so an unwritable or failing write leaves a run directory with no record (found by reviewing this change with the tool) | REQ-HOOK-41 |
| the pre-WRITE removal of the sidecar dropped, so a review whose sidecar write fails archives the PREVIOUS review's `review.meta.json` - `run.json` then records this run's verdict beside a file holding the older one (found by reviewing this change with the tool) | REQ-HOOK-41 |
| a `mkdir` failure for the run directory swallowed without a warning, so the history is silently incomplete - the two neighbouring failure branches already warned (found by reviewing this change with the tool) | REQ-HOOK-41 |
| the stub writing constant bytes per invocation, which made the "the second run did not overwrite the first run's archived review" comparison unfalsifiable - reusing the first run's directory compared equal and passed (found by reviewing this change with the tool) | REQ-HOOK-41 |
| the sidecar archived regardless of `run_ok`, so a failed run is credited with the previous run's verdict | REQ-HOOK-41 |
| pr-agent's console output not redirected to `run.log`, so no run logs its output - and the archived `run.log` held nothing to prove the capture works (`>/dev/null` in place of `> "$run_log" 2>&1`, run and watched failing the case) | REQ-HOOK-41 |
| the log filter keeping every line, so the archived `run.log` filed the rendered review a second time beside `review.md` and buried the records (the record-shape `grep` replaced with `.`, run and watched failing the case) | REQ-HOOK-41 |
| ANSI escape sequences left in the archived `run.log`, so the colourised logger output was unreadable (the `sed` filter dropped, run and watched failing the case) | REQ-HOOK-41 |
| the saved log not opening with the call the bundle makes, so it does not say what produced the records (`printf` of the invocation dropped, run and watched failing the case) | REQ-HOOK-41 |
| the invocation naming the real rendered-config path instead of its role, which puts the provider's credential location in a file people paste into issues (run and watched failing the case) | REQ-HOOK-41 |
| the invocation omitting the command and scope, so the log does not say what was run (run and watched failing the case) | REQ-HOOK-41 |
| the invocation kept when pr-agent printed nothing, so a run that produced no output looked like one that did and was archived (run and watched failing the case) | REQ-HOOK-41 |
| a failed run's captured output not printed, so redirecting the agent's console output into `run.log` turned a loud failure into a silent one (the `dump_run_log` call dropped from the failure path, run and watched failing the case) | REQ-HOOK-41 |
| the `model=FALLBACK` marker removed from the summary line, so a fallback answer reads as the configured model's | REQ-HOOK-42 |
| the coverage marker gated on `PREFLIGHT_SCOPE_IS_BRANCH` again, so a pruned commit-scope review reports a clean summary line | REQ-HOOK-43 |
| the coverage marker keyed on the footer's literal sentence again, so the clipped-patch footer pr-agent emits for a second cause goes undetected and a partial review reads as complete (the regex widened back to the 0.47 sentence, run and watched failing the case) | REQ-HOOK-28 |
| the rendered config's transport pin taken from the default instead of the provider entry | REQ-HOOK-44 |
| the rendered config's endpoint taken from the pinned transport's default instead of the provider entry | REQ-HOOK-44 |
| the provider's key left out of the rendered config | REQ-HOOK-44 |
| the streaming pair inherited from settings.toml rather than scoped to the provider that asked for it | REQ-HOOK-44 |
| the in-repo guard narrowed back to enumerated file names, so an unignored `providers.toml.bak` holding the key is staged | REQ-HOOK-44 |
| the rendered config written world-readable instead of 600 | REQ-HOOK-44 |
| the renderer's "outside the repository" skip removed, so a `$TMPDIR` inside the repo is used (with a GNU-style `mktemp` shim, because macOS's own ignores `$TMPDIR` and the case would otherwise be unfalsifiable) | REQ-HOOK-44 |
| a file with profiles but no assignment ignored instead of refused | REQ-HOOK-44 |
| the mixed-provider refusal removed from the resolver | REQ-HOOK-45 |
| the `provider`-defined-nowhere refusal removed | REQ-HOOK-45 |
| the refusal for a missing resolver removed from `src/preflight-code` | REQ-HOOK-45 |
| the `api_base`-on-a-key-only-transport refusal removed | REQ-HOOK-45 |
| the `rm` removed from `preflight-pr`'s EXIT trap, so the per-run render outlives the run | REQ-HOOK-46 |
| the trap restored to calling the renderer's removed `__preflight_unlock`, so it reports 127 and masks pr-agent's status | REQ-HOOK-46 |
| the temp-dir fallback made silent (the two stderr lines dropped), so a credential-bearing file moves without a word | REQ-HOOK-50 |
| an unwritable `PREFLIGHT_RENDER_DIR` falling back to the temp dir instead of refusing, so the key lands where the operator did not choose | REQ-HOOK-50 |
| the render dir's in-repo check made DIRECTORY-level (or dropped), so an empty scratch dir inside the reviewed repo is accepted and the key is staged by `git add -A` | REQ-HOOK-50 |
| the fallback rendering kept in the config dir (the writability test inverted), so a read-only config dir fails the review again | REQ-HOOK-50 |
| the missing-artifact exit removed, so a review pr-agent never wrote exits 0 and the "wrote ..." line claims files that do not exist | REQ-HOOK-51 |
| the structured `coverage` reader dropped, so the marker depends on the footer text alone again | REQ-HOOK-52 |
| a stub `pr-agent` that exits without draining stdin (the `cat >/dev/null` removed from one), so `git diff` dies of SIGPIPE and the helper reports 141 instead of the review's status - caught by the `hooktests` stub scan, which named the line | the `hooktests` stage, before the suite runs |
| the progress note deleted, so a run that writes nothing waits silently | REQ-HOOK-47 |
| the interval test replaced with one that always fires, so every normal review is noisy | REQ-HOOK-47 |
| the numeric guard on `PREFLIGHT_PROGRESS_EVERY` removed, so a typo prints a shell error per iteration | REQ-HOOK-47 |
| the reap removed from `cleanup`, so a review killed mid-flight leaves `pr-agent` running | REQ-HOOK-48 |
| the reap removed from `cleanup_pr`, so a PR run killed mid-flight leaves `pr-agent` running | REQ-HOOK-49 |
| the `<&0` removed from `preflight-pr`'s launch, so a backgrounded pr-agent reads /dev/null instead of the caller's stdin | REQ-HOOK-46 |
| the mode fix changed to an unconditional `chmod 600`, so a file the operator made stricter is widened | install |
| the in-repo guard's pre-snapshot call removed, so the refusal comes after `git add -A` and the key is already a blob in `.git/objects` | REQ-HOOK-44 |
| the copy command removed from the missing-profiles refusal, so a half-created config dir names a file it never says how to create | models |
| the providers.toml copy command made unconditional again, so the half-configured state is told to overwrite its keyed file with the empty-key template | REQ-HOOK-45 |
| the settings.toml copy command made unconditional again, so a configured settings.toml is told to overwrite itself with the template | install |
| the copy commands removed from the install's NEXT block, so a bare install names no way to create the files it requires | install |
| the `FALLBACK_RE.search` guard replaced with an unconditional marker, so every review claims a fallback answered | REQ-HOOK-42 |
| a dotless suffix (`["txt"]`) matched raw by `endswith`, so `notes.baktxt` becomes advisory | REQ-HOOK-39 |
| a path fragment (`["docs/"]`) accepted as a suffix, matching anything under a directory of that name | REQ-HOOK-39 |
| the suffix whitelist weakened to "any non-empty string", so a path fragment, `.`, or a non-string entry is accepted | REQ-HOOK-39 |
| a non-string suffix entry coerced by `str()` into a plausible-looking extension (`1` -> `.1`) | REQ-HOOK-39 |
| a boolean key returning to "any non-zero int is true", so `allow_issues = 2` disables the check | REQ-HOOK-39 |
| an empty `doc_suffixes` entry dropped while valid ones are applied (partial application of a wrong list) | REQ-HOOK-39 |
| a waived key issue still labelled `[blocking]`, so a PASS contradicts the label (the same rule the `doc_blocks` override follows) | REQ-HOOK-39 |
| an unknown config key ignored silently (a typo'd key looks configured but is not) | REQ-HOOK-39 |
| the shipped `[gate]` reference uncommented, freezing today's defaults into every install and silently overriding a later change to the built-in default | CI (the config stage asserts the template sets no `[gate]` keys) |
| `case_gate_doc_advisory` exporting a scratch `PREFLIGHT_HOME` into the top-level shell, leaking it into later cases | REQ-HOOK-23 (the live case skips when it points at the scratch home) |
| `case_gate_doc_advisory` reading the developer's real `$HOME/.config/preflight/settings.toml` instead of a scratch home | REQ-HOOK-38 |
| the finding path left unnormalised at both sites, so the trailing newline in `relevant_file` makes a doc finding block | REQ-HOOK-38 |
| the strict-mode override adjusts the counts but not the per-finding label, so a blocking doc finding still prints `[advisory]` | REQ-HOOK-38 |

This table is per-fix: it records which case guards which repair. It is **not** the same property as the
selfcheck below, which asks about the whole hook at once.

**Every row here must have been run**: apply the mutation, watch the case fail, revert, watch it pass. An
earlier version of this table listed mutations no case could distinguish - claimed coverage that did not
exist - which is the same "an inability to check is indistinguishable from a pass" failure this repo guards
against elsewhere. Keep the table short and true rather than complete and aspirational.

## The selfcheck, and why "all cases pass" is not enough

A passing suite does not by itself mean the hook enforces anything. Stub the hook out entirely
(`#!/bin/sh` + `exit 0`) and the suite is still green for a large share of its offline cases, because
those cases do not depend on the hook refusing something:

| Group | Cases | Why a neutered hook still passes them |
|---|---|---|
| permissive by design | REQ-HOOK-07, 08, 09, 10 | they assert something is **not** blocked (`commit -a` with a scratch file, a reviewed deletion, a reviewed rename, an empty commit), so blocking nothing satisfies them |
| bypass hatches | REQ-HOOK-14, 15 | they assert `--no-verify` / `PREFLIGHT_SKIP=1` work |
| orthogonal | REQ-HOOK-20, 22, 26, 27, 28, 29, 31 | they do not test the hook at all: `20` checks a file's presence, `22`, `26` and `27` exercise the *example* hooks in `src/githooks/`, and `28`/`29`/`31` exercise the review helper - different files, which stubbing `src/preflight-hook` cannot affect |

That is correct per case, but it leaves a hole: nothing stopped the **enforcement-sensitive** set from
silently losing its teeth. A case could be added that is meant to catch an unreviewed commit, pass with
the hook disabled, and no one would find out - the suite would report green either way.

`./tests/run.sh selfcheck` closes it. It runs this whole suite against a neutered hook and requires that
**exactly** the declared enforcement-sensitive cases fail, which has three consequences:

- **Every case must be classified.** The sensitive and insensitive lists live in `run.sh` next to the
  selfcheck. A new case that is in neither list fails the selfcheck, so its author has to state which kind
  it is instead of joining the insensitive set by default.
- **A sensitive case that passes** with the hook neutered fails the selfcheck, naming the case.
- **A sensitive case that *skips*** also fails, because a guard that did not run proves nothing - the same
  reasoning as `expect_commit` refusing a case that staged nothing. This is why `skip` takes
  `skip NAME REQ REASON`: the REQ id is required, not optional, so a skipped enforcement case is visible to
  the selfcheck rather than silently recorded as a pass.

It reports the split, so drift is visible in the output:

```
  PASS  a neutered hook fails exactly the enforcement-sensitive cases  [REQ-SELF-01]
        <n> enforcement-sensitive, <n> insensitive, <n> ids exercised
```

The selfcheck is itself mutation-tested: adding a temporary case that passes with the hook neutered must
fail it while unclassified, must still fail once marked sensitive, and must pass once marked insensitive.

## Every stub drains stdin

`preflight-code` streams the diff into pr-agent with `git diff … | pr-agent … &` and then `wait`s on the
**pipeline**. Under `set -o pipefail` that status is the pipeline's, so a child that exits without reading
its stdin kills the writer with `SIGPIPE` and `wait` returns **141** — not the child's own status. The
helper reports 141 as a failed run, and a case that expected a review then fails for a reason that has
nothing to do with what it tests.

Which side wins the race decides whether it happens at all, so the same commit passed on macOS and failed
on Ubuntu: the writer had not yet reached the pipe when the child exited there.

So **every stub that can exit must drain stdin** — `cat >/dev/null` after the argument loop, or `cat >
"$SOME_FILE"` when the case records what it was handed. The `hooktests` stage fails, naming the line, if a
stub in `run.sh` can exit without one; that check is a property of the file rather than a fix at the stubs
that happened to flake, because a stub added later would reintroduce it and a one-leg flake is invisible
locally. A stub that deliberately never exits (it `exec`s a sleep, so a case can test the wait or the reap)
is exempt: its writer is blocked rather than dead, and every case using one asserts a **non-zero** status,
which a `SIGPIPE` could not turn into a false pass.

Do not "fix" a `SIGPIPE` by dropping `pipefail` or by retrying in `src/preflight-code`: a real pr-agent
that exits on a closed stdin is a real condition, and the helper should keep reporting it.

## A trap worth knowing

Two cases originally passed **for the wrong reason**: git refused the commit itself ("nothing to commit,
working tree clean") because the test staged nothing, and a non-zero exit is indistinguishable from the
hook blocking. A removed verdict check went unnoticed that way. `expect_commit` now fails any case that
stages nothing, so this class of false pass cannot come back silently. When adding a case that expects a
block, make sure something is staged **and** that the thing under test is the only reason to block.

## Adding a case

1. Write `case_<name>()` following the existing shape, and give it the next `REQ-HOOK-nn`.
2. Add it to the `run_group` list in `run.sh` and to the table above.
3. **Classify it** in the `sensitive` or `insensitive` list near `case_selfcheck`. The selfcheck fails on
   an unclassified case, so this is enforced rather than optional - and a case that claims to catch an
   unreviewed commit but passes with the hook neutered will be caught here.
4. If it guards a fix, revert the fix and confirm the case fails.

Note the helper signatures the selfcheck depends on: `expect_commit NAME REQ EXPECTED_EXIT REPO` and
`skip NAME REQ REASON`. The REQ id is part of the contract, not a comment.
