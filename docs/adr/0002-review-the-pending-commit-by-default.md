# 0002. Review the pending commit by default, not the branch

- **Status:** accepted
- **Date:** 2026-10-11
- **Deciders:** 413x5
- **Supersedes / amends:** nothing. The earlier default (a branch scope) is recorded in
  [`../history.md`](../history.md).

## Context and problem statement

`preflight-code review` has to choose what to diff. The tool's purpose is to review a change *before* it
becomes a pull request, so the natural default is the change about to be committed - but the first
shipped default was the branch scopes, which diff against a resolved base.

That default carried three costs that all fell on the common case. It needed a **base**, so it needed a
remote and a fetch, and it could fail the way base resolution fails (exit 4). It failed offline. And it
made every review a whole-branch review, so the cost grew with the branch's age while the *change* under
the reviewer's eye was one commit - and because reviews are token-heavy, that cost was paid per round of
a loop that runs repeatedly.

## Considered options

- **`worktree` (branch since the default branch).** Buys complete branch coverage in one call. Costs a
  fetch, a base resolution that can fail, and a review whose size grows with the branch; the branch
  diff is roughly an order of magnitude larger than a commit's.
- **`head` (`base...HEAD`, committed content only).** Buys the smallest diff and no snapshot build.
  Costs the ability to review uncommitted work at all - the case the tool exists for - and, decisively,
  the hook **cannot enforce it**: it grades the *parent*, so a commit is never actually verified.
- **`commit` (`HEAD` → the snapshot, untracked files included).** Buys a cheap, local, offline default
  that needs no base and no fetch, and that the hook can enforce exactly. Costs complete branch coverage
  in a single call.

## Decision

`commit` is the default. It is the case the tool exists for - reviewing a change before it is submitted -
and it is the only scope whose content the hook can bind a commit to.

The branch coverage that `worktree` bought is not lost, which is what makes the trade acceptable:
reviewing commit by commit *covers* a multi-commit branch completely, because the hook checks each commit
against the tree reviewed for it, so the union of the per-commit reviews covers the branch. Both branch
scopes remain available as opt-ins.

## Consequences

Good: the default works offline, needs no remote and cannot fail base resolution; every review is small,
so the loop stays affordable; and the enforced scope and the default scope are the same, so the common
path is the verified one.

Bad: a single call no longer shows a reviewer the whole branch, so cross-commit interactions in one
branch are the caller's job to surface (by using a branch scope deliberately). And a machine that never
sets a base can no longer accidentally discover that its base resolution is broken.

**What enforces it:** `REQ-HOOK-33` (the default is `commit`; `worktree` still resolves a base and keeps
the branch diff; an unknown scope exits 2) and `REQ-HOOK-37` (the `commit` scope hands the model every
path a commit would contain, including untracked files) in [`../../tests/README.md`](../../tests/README.md).
