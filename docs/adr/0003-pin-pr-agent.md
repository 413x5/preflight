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

Pin. `install.sh` installs a fixed version (default `0.49.0`) and exposes `PREFLIGHT_PR_AGENT_VERSION`
to override it, because a pin that cannot be moved is a pin that blocks an urgent upgrade.

CI asserts the pin cannot drift silently: that the `uv tool install` line carries it,
that the spec names the `github` extra, and that its value is the version the coverage-footer fixture in
`tests/run.sh` was copied from. A bump therefore has to come with a re-check of that fixture rather than a
silent edit. `install.sh` also *verifies* the version that landed, and fails with the exact re-run command
if the installed package is not the pin: trusting the installer's own command is how a machine ends up
running a pr-agent this bundle was never checked against.

`uv tool install` on an existing install converges on the spec - it upgrades AND downgrades to match - so
the pin is enforced on every reinstall, not only on a fresh machine. What it will not do is add an extra
that the spec does not name: it prints `already installed` for an identical spec, and re-running a plain
pin after an extra was added prunes that extra again. The extra therefore belongs in the SAME spec as the
version, which is what makes the install idempotent in both directions.

## Consequences

Good: an installed bundle behaves the way the bundle was tested; the coupling between this repo and
upstream's output format is explicit and checked, rather than discovered when a review stops reporting
partial coverage.

Bad: bug fixes and model support from upstream arrive only when someone bumps the pin and re-verifies the
fixture.

**Corrected 2026-10-31.** An earlier version of this record claimed `uv tool install` on an existing
install "reports already installed and does not upgrade". That is false for the uv versions this bundle
supports (measured on uv 0.12.23, both directions): a reinstall moves to the pinned version, so the pin
reaches machines that installed an earlier release. The *decision* to pin is unchanged; only that claim
about the installer was wrong, and it was wrong in the direction that made the pin look weaker than it is.

**What enforces it:** the `install` stage of [`../../scripts/verify`](../../scripts/verify), which fails if
the pin line changes without the fixture being re-checked. CI runs that stage through the gate rather than
repeating it as a step of its own.
