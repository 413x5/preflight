# 0006. Adopt the development playbook's layout, docs tree and gate

- **Status:** accepted
- **Date:** 2026-10-12
- **Deciders:** 413x5
- **Supersedes / amends:** nothing

## Context and problem statement

[`../../PLAYBOOK.md`](../../PLAYBOOK.md) is this project's development standard: one gate command
referenced from everywhere, a docs tree with one home per fact, decision and incident records, and a
repository layout a newcomer can guess. The repository predates it and diverges in several places at once.

The divergences are not cosmetic, and one of them is the playbook's own central failure mode:

- **No single gate command.** The checks (shell syntax, installer, TOML, version consistency, the hook
  tests, the selfcheck) exist only as inline CI steps and as a prose list in two documents. That is
  precisely the shape the playbook forbids - if CI and the local instructions list the steps separately,
  they drift, and a change passes one and fails the other.
- **The same fact in more than one file.** [`../../AGENTS.md`](../../AGENTS.md) and
  [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) each carry the layout table, the ground rules and the
  test commands. Duplicated facts disagree eventually; a reader cannot tell which copy is right.
- **No decision or incident records.** The reasoning exists - it is scattered through
  [`../architecture.md`](../architecture.md) and [`../../CHANGELOG.md`](../../CHANGELOG.md) - but there is
  no place to answer "why is this like this, and does it still hold".
- **Missing root documents.** No licence (see [0005](0005-mit-licence.md)) and no security posture.
- **Layout.** The shipped scripts live in `files/`, which names nothing; there is no `scripts/` for dev
  helpers and no `config/` for the checked-in config examples.

## Considered options

- **Leave the layout, add only the records.** Costs the convergence problem: two lists of steps keep
  drifting, and the next change has to check both by hand.
- **Rename to match the playbook exactly.** Buys guessability. Costs churn - the reference count is in
  [`../measurements.md`](../measurements.md) - including a GitHub API URL inside the consumer-facing snippet.
- **A partial rename - keep `files/`, add `scripts/verify` and the docs tree.** Buys the gate and the docs
  with the least churn. Costs one permanent exception to explain: a directory name that no reader guesses
  and that the playbook explicitly warns against (`files` names nothing, like `util` or `helpers`).

## Decision

Adopt the playbook's shape, with the naming divergence accepted rather than hidden:

1. The shipped bundle moves to `src/` (see the consequence below for what that name does and does not
   mean here), the templates `install.sh` writes to `config/`, and dev helpers to `scripts/`.
2. **One gate command, [`../../scripts/verify`](../../scripts/verify),** composing the existing checks in
   cost order, cheapest first. CI invokes it rather than re-listing steps.
3. The docs tree: `docs/README.md` as the index, `docs/adr/` for decisions, `docs/runbooks/` for
   operations, plus `docs/roadmap.md`, `docs/history.md` and `docs/measurements.md`.
4. **One home per fact.** `AGENTS.md` owns the layout, the invariants and the commands, because every
   coding agent reads it by convention; `CONTRIBUTING.md` keeps the human on-ramp and points at the rules
   instead of restating them.
5. `LICENSE` (MIT) and `SECURITY.md` join the root document set.

**One deliberate departure, named rather than left implied:** there is no `CODE_OF_CONDUCT.md`. The
playbook asks for one "for any project with contributors from outside", and this repository has a single
committer. Adding one now would be a document with no reader.

## Consequences

Good: a change has one command to run and CI runs the same one; every fact has exactly one home, so a
correction happens once; the reasoning behind each load-bearing decision is answerable from a record
instead of reconstructed from a changelog; and the license and security posture are stated rather than
implied.

Bad, and worth naming:

- **`src/` means something weaker here than the playbook intends.** Upstream, `src/` is "the only
  hand-written, shipped code", built into artifacts. This bundle has no build step at all - `src/preflight-code`
  and its siblings *are* the product, copied to `$PREFLIGHT_HOME` by `install.sh`. The playbook's
  `src/` conformance buys guessability and costs a small lie in the name. `files/` was the alternative
  lie ("files" names nothing), and a guessable name was judged worth more than a literal one.
- The rename touches documentation and CI only. **Installed machines are unaffected**: `install.sh` copies
  into `$PREFLIGHT_HOME`, and nothing on disk records the repository path, so no installed helper, hook or
  config needs to change.
- Adding `scripts/verify` creates a second way to run the checks for as long as the commands also exist
  individually. The gate composes them rather than absorbing them, so the individual commands stay
  runnable - but a new check must be added to the gate or it will not run in CI, which is a discipline
  cost rather than a detected failure.

**What enforces it:** `.github/workflows/ci.yml` calls [`../../scripts/verify`](../../scripts/verify), so
the gate is the definition of done for every pull request and the local run and the CI run cannot diverge.
