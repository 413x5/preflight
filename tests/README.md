# Tests

Integration tests for the preflight commit hook. No framework, no network, no API key:

```sh
./tests/run.sh           # everything (~1–4 min; the live case needs a configured key)
./tests/run.sh hook      # hook enforcement only, fully offline (seconds)
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

So the tests drive **real repositories** through the **real hook files** in `files/`, and assert on the
commit's exit code. Each test builds a throwaway repo from `tests/sample/`.

## How a review is simulated

A worktree-scope review records the tree it handed to the model. `review_here` reproduces that using
the same scratch-index method `preflight` itself uses (`read-tree HEAD` + `add -A` + `write-tree`) and
writes the sidecar a passing review would have written. That keeps the suite offline and deterministic
while still exercising the real comparison, and the scratch index is kept **outside** the repo so it can
never appear in a snapshot.

## Traceability

Each case declares the requirement it guards. The mapping is one-to-one with the behaviour it protects,
and every previously-fixed bug has a case that fails if the fix is reverted.

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

## A trap worth knowing

Two cases originally passed **for the wrong reason**: git refused the commit itself ("nothing to commit,
working tree clean") because the test staged nothing, and a non-zero exit is indistinguishable from the
hook blocking. A removed verdict check went unnoticed that way. `expect_commit` now fails any case that
stages nothing, so this class of false pass cannot come back silently. When adding a case that expects a
block, make sure something is staged **and** that the thing under test is the only reason to block.

## Adding a case

1. Write `case_<name>()` following the existing shape, and give it the next `REQ-HOOK-nn`.
2. Add it to the `run_group` list in `run.sh` and to the table above.
3. If it guards a fix, revert the fix and confirm the case fails.
