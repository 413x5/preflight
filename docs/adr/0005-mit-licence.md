# 0005. Release under the MIT licence

- **Status:** accepted
- **Date:** 2026-10-12
- **Deciders:** 413x5
- **Supersedes / amends:** nothing

## Context and problem statement

The repository was published at <https://github.com/413x5/preflight> with **no licence at all**. An
unlicensed repository is not "undecided" to anyone reading it: by default it is all rights reserved, so a
reader has no permission to use, copy or modify the code, however public it looks. The roadmap had
carried the choice as an open item ("decide: MIT vs proprietary") without settling it.

## Considered options

- **No licence (the status quo).** Costs clarity in the wrong direction: a public bundle that nobody may
  legally use. Rejected.
- **MIT.** Buys the widest possible reuse with the fewest obligations, and matches what this artifact
  actually is - a small harness over a permissively licensed upstream tool. Costs nothing in
  enforceability and gives up any control over derivative works.
- **Proprietary / all rights reserved, stated explicitly.** Buys control. Costs the audience: the bundle
  is most useful when someone can install it and adapt the provider config, which is exactly what a
  proprietary notice forbids. Rejected as the wrong trade for a config-plus-hooks artifact.
- **A copyleft licence (GPL/AGPL).** Costs compatibility with the ecosystem this sits in and adds
  obligations to a bundle whose product is a shell script and two git hooks.

## Decision

MIT, with the copyright holder recorded as **413x5** (the repository owner, and the `user.name` on every
commit here). The licence text is the verbatim MIT licence in [`../../LICENSE`](../../LICENSE).

Note the interaction with ADR [0003](0003-pin-pr-agent.md): this bundle *installs* pr-agent but does not
distribute it, so upstream's licence is not inherited here and does not constrain this choice.

## Consequences

Good: the permissions are unambiguous and machine-readable; GitHub and package tooling can identify the
licence; and the roadmap item that had been open since publication is closed with a reason rather than a
default.

Bad: anyone may sell or relicense a derivative, with no obligation to contribute back. That is accepted -
this is a personal, local-first tool, and being usable matters more than being controlled.

**What enforces it:** nothing mechanical. The `LICENSE` file is the record, and this ADR is the reason.
