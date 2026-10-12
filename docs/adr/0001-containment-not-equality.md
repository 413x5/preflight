# 0001. Containment, not equality, binds a commit to its review

- **Status:** accepted
- **Date:** 2026-10-07
- **Deciders:** 413x5
- **Supersedes / amends:** nothing

## Context and problem statement

The commit hook's whole job is to refuse a commit whose content was never reviewed, so it needs a rule
for "the content being committed is the content that was reviewed". The reviewed content is not the
committed content: `preflight review` snapshots the **worktree**, and that snapshot includes untracked
files, while a commit contains only what is staged. Any rule has to bridge that gap without either
letting unreviewed content through or refusing an ordinary workflow.

The obvious formulations (strict equality, superset) each fail, and they fail in *opposite* directions -
one is unsafe, one is unusable - which is why the choice is not a matter of taste.

## Considered options

All three were measured on a real repository, not reasoned about. The table in
[`../architecture.md`](../architecture.md) is the empirical record; the outcomes:

- **Strict equality** (reviewed tree must equal the staged tree). Costs an ordinary workflow: `git
  commit -a` stages tracked modifications but not untracked files, so any non-ignored scratch file or
  build artifact present at review time makes the trees differ and the commit fails. That is a common
  idiom, not a corner case.
- **Superset** (reviewed tree need only cover the staged tree). Costs safety, in four separate ways: a
  brand-new never-reviewed file passes, and reviewed content can be deleted, renamed or retyped without
  any review having seen the change - each of which is how a guard is removed unnoticed.
- **Containment** (every path being *committed* must equal that path in the *reviewed* tree; reviewed
  content that is not being committed is ignored). Costs the ability to commit only part of a reviewed
  *file*, and requires one refinement to work - see below.

**The refinement.** The comparison runs reviewed → staged, where status `D` means "in the reviewed tree,
absent from the staged tree". Two different situations produce it, and they must be told apart: a
tracked file being deleted (reviewed content going away - block), and an untracked scratch file that was
in the snapshot and is simply not being committed (blocking it breaks `git commit -a` - allow). The
discriminator is `HEAD`: a `D` path `HEAD` knows is tracked content genuinely being deleted.

## Decision

Containment. It is the only one of the three that is both safe (unreviewed additions, deletions,
renames and retypechanges all block) and usable (`git commit -a` keeps working). Where a rule must
choose between blocking something legitimate and admitting something unreviewed, this bundle blocks -
but here the choice does not have to be made.

## Consequences

Good: the failure direction is *more* blocking, which is the visible direction; the rule has a single
sentence ("every path being committed must match the reviewed tree"); and `git commit -a`, newly staged
files and empty commits all behave.

Bad: committing a subset of a reviewed *file*, or a deletion whose removal was not part of the review, is
refused and needs a re-review. That is deliberate - re-reviewing is the intended way to accept a removal -
but it is friction on a legitimate act, and it is the cost the other two options were trading against.

**What enforces it:** `REQ-HOOK-01`-`09` (the three-way comparison table, both directions), `REQ-HOOK-24`
(a deletion whose path git would quote) and `REQ-HOOK-25` (a gitlink removal) in
[`../../tests/README.md`](../../tests/README.md).
