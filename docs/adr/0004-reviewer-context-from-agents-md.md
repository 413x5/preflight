# 0004. Give the reviewer the repository's own facts, from its AGENTS.md

- **Status:** accepted
- **Date:** 2026-10-10
- **Deciders:** 413x5
- **Supersedes / amends:** nothing

## Context and problem statement

An automated reviewer cannot tell a deliberate, documented trade-off from an oversight, so it reports the
trade-off as a defect. This was measurable, not hypothetical: the `.preflight-gate.toml` trust boundary -
a committed policy file may relax enforcement, accepted because the hook is a local pre-commit check on
the committer's own work - came back as a finding **three times**, and each time the answer was the same
sentence. A finding that has already been answered costs a round of the loop, which is a full model call.

The remedy has to put the facts in front of the reviewer, and it has to put them somewhere a repository
already maintains - a second file that must be kept in step with the first is a file that drifts.

## Considered options

- **A dedicated context file for this tool.** Buys full control of the format. Costs a file nobody else
  reads, which therefore goes stale exactly when it matters. Rejected: it duplicates a convention that
  already exists.
- **`AGENTS.md`, via pr-agent's `repo_context_files`.** Buys the file every agent tool already reads.
  Costs nothing in upkeep - and, as a probe showed, does not work: the plain-diff provider implements
  neither `get_repo_file_content` nor `get_repo_context_ref`, so `build_repo_context` is empty for a
  `--stdin` run.
- **`AGENTS.md`, via pr-agent's `[artifacts]` channel.** Buys the same single source of truth *and* a
  channel that actually reaches the model in plain-diff mode. Costs a smaller bound on how much can be
  sent, and couples the bundle to the artifact mechanism.

## Decision

Send the repository's own `AGENTS.md`, through `[artifacts]`. A heading whose text starts with
`Code review` is extracted and sent **alone**, so a long `AGENTS.md` does not follow the reviewer into
the prompt; when there is no such heading the whole file is sent, because how much context to hand over
is the repository's choice. A section is facts only, never suppression instructions - suppression is what
the gate's tier and opt-outs are for.

Two implementation constraints follow from the channel and are load-bearing:

- Every artifact setting comes from the **environment**, not `preflight.toml`. pr-agent injects the
  artifact before it loads `--extra_config_url`, so an `[artifacts]` section there is read too late. CI
  asserts the section stays out of that file.
- The file is read from the **working tree**, unlike pr-agent's and Codacy's config files, because this is
  a local pre-commit harness where the file is committed and therefore part of the diff under review.

## Consequences

Good: a documented trade-off stops arriving as a finding; the facts live in the one file every other
coding agent already reads, so there is no second copy to maintain; and `context=<file>` on the summary
line makes a review given the repo's facts distinguishable from one that was not.

Bad: the bound is real - a `Setext` heading (text underlined with `===`) is not matched at all, and in
every unmatched case the whole file is sent, so the extraction can silently fail to bound anything. And
the mechanism addresses only missing facts: a model that misreads context it already has is a different
failure that no amount of added context fixes.

**What enforces it:** `REQ-HOOK-40` in [`../../tests/README.md`](../../tests/README.md), which asserts
that a `Code review` heading is extracted and sent alone, that a subsection is not mistaken for the
boundary, and that fenced code cannot end the section early.
