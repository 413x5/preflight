# 0003. Pin pr-agent to a version the bundle is verified against

- **Status:** accepted
- **Date:** 2026-10-11
- **Deciders:** 413x5
- **Supersedes / amends:** nothing

## Context and problem statement

The bundle is a thin configuration and harness layer over upstream pr-agent, and several of its
mechanisms read pr-agent's *output* rather than a stable interface. The sharpest example is the
`coverage=PARTIAL` marker: it matches the exact structure and wording of pr-agent's "files were not
included" footer in `review.md`. An upstream reword retires that marker, and the failure is invisible in
the direction that matters - a review that silently covered a slice of the tree still reports real
findings, so partial coverage reads as a clean review. That is the failure mode this bundle exists to
prevent, reintroduced by an upgrade nobody chose.

The installer previously tracked the latest release.

## Considered options

- **Track the latest release.** Buys upstream fixes with no maintenance. Costs an uncontrolled variable
  under a mechanism that silently degrades when upstream changes - and the degradation is undetectable
  from the bundle's own output.
- **Pin, with an environment override.** Buys a tested floor and a reproducible install. Costs a
  deliberate bump: upgrading is now an act someone performs and verifies rather than something that
  happens on its own.
- **Vendor pr-agent.** Buys total control. Costs the reason this bundle is small in the first place -
  maintaining a fork of a tool whose behaviour is the dependency.

## Decision

Pin. `install.sh` installs a fixed version (default `0.47.0`) and exposes `PREFLIGHT_PR_AGENT_VERSION`
to override it, because a pin that cannot be moved is a pin that blocks an urgent upgrade.

CI asserts two things so the pin cannot drift silently: that the `uv tool install` line carries the pin,
and that its value is the version the coverage-footer fixture in `tests/run.sh` was copied from. A bump
therefore has to come with a re-check of that fixture rather than a silent edit.

## Consequences

Good: an installed bundle behaves the way the bundle was tested; the coupling between this repo and
upstream's output format is explicit and checked, rather than discovered when a review stops reporting
partial coverage.

Bad: bug fixes and model support from upstream arrive only when someone bumps the pin and re-verifies the
fixture. Note also that `uv tool install` on an existing install reports "already installed" and does not
upgrade, so installations predating this change were already effectively frozen - the pin closes the gap
for fresh installs rather than changing behaviour for existing ones.

**What enforces it:** the `install` stage of [`../../scripts/verify`](../../scripts/verify), which fails if
the pin line changes without the fixture being re-checked. CI runs that stage through the gate rather than
repeating it as a step of its own.
