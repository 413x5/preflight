# 0007. Rename the bare command to `preflight-code`, and nothing else

- **Status:** accepted
- **Date:** 2026-10-19
- **Deciders:** 413x5
- **Supersedes / amends:** nothing

## Context and problem statement

This bundle installs three commands on `PATH`: `preflight`, `preflight-gate` and `preflight-pr`. An
unrelated project, [`ghuntley/preflight`](https://github.com/ghuntley/preflight), ships a binary called
`preflight` as well - a Rust proxy that inspects outbound LLM requests and attachments for secrets. The two
tools read their subcommand from the same argument position, so a machine with both installed resolves the
name by `PATH` order: whichever comes first answers, and the other one's subcommand (`review`, `describe`,
`improve`, `ask`) is not a command it has.

The shadowing is not symmetric in consequence. This bundle is invoked constantly - by a person and by the
coding agent following `AGENTS-review-snippet.md` - while the other tool is a long-running proxy started
once. Losing the name therefore costs this bundle far more than it costs the other project, and a review
that cannot be started is indistinguishable from an enforcement step nobody runs.

Nothing else collides. The config directories differ (`~/.config/preflight` against the other project's
`~/.cache/preflight`), the artifacts differ (`.preflight/` against none), the two sets of `PREFLIGHT_*`
variables are disjoint, and `preflight-gate`/`preflight-pr` have no counterpart there.

## Considered options

- **Keep the name and guard the `PATH`.** Detect a shadowing binary at install time and at review time, and
  warn. *Buys:* no breaking change. *Costs:* the collision is still there on every machine, and the guard is
  a check that has to keep being right about another project's binary; a warning printed during an install
  is read once, while the failure it warns about happens every time the command is typed.
- **Rename everything** - commands, config directory, artifact directory and variables. *Buys:* one clean
  namespace. *Costs:* a far larger breaking change with no collision behind most of it;
  `preflight-gate`, `preflight-pr`, `PREFLIGHT_*` and `~/.config/preflight` are unique already, so renaming
  them costs every consumer an edit and buys nothing.
- **Rename the command and install a compatibility alias.** *Buys:* existing snippets keep working.
  *Costs:* it reinstalls a `preflight` binary, which is the collision this record exists to remove. The
  alias would be the only thing at that path that could be either tool, and no `PATH` guard can fix it.
- **Rename the bare command to `preflight-code`, and retire the old name.** *Buys:* the collision is gone
  for good, the project keeps its name, and only the one colliding identifier changes. *Costs:* a breaking
  change for every consumer that has the old snippet pasted, and prose must now distinguish the project
  (`preflight`) from its command (`preflight-code`).

`preflight-code` was chosen over the alternatives after checking that it is unclaimed on Homebrew,
crates.io, PyPI and npm: a name that merely looks free is how this problem started.

## Decision

The bare command is `preflight-code`, and the source file moves with it so no `src/...` path names a
command that no longer exists. `preflight-gate`, `preflight-pr`, `preflight-hook`, every `PREFLIGHT_*`
variable, `~/.config/preflight` and `.preflight/` are unchanged, and the project is still called
`preflight`. The old name is retired rather than forwarded.

Output follows the command it belongs to: the summary line and every helper, hook and gate message say
`preflight-code:` where they used to say `preflight:`. `preflight-gate:` and `preflight-pr:` keep their
own prefixes. The resolver that both helpers share takes the name of its caller rather than hardcoding
one, so a refusal under `preflight-pr` still says `preflight-pr` - the alternative was duplicating its
messages or misattributing them.

## Consequences

Good: the name is unambiguous on any machine, so a review cannot be routed to the other project at all.
The change is confined to one identifier, so the config, the artifacts and the committed hooks a consumer
already has all keep working; only the command name in a pasted snippet goes stale, and that fails loudly
as `command not found` rather than passing silently.

Bad, and worth naming:

- **A breaking rename for consumers.** A repository whose `AGENTS.md` carries the old snippet calls a
  command that no longer exists. The changelog entry records it, and the snippet's own version check is how
  an operator notices the copy is stale.
- **Prose gets harder.** "preflight" now means the project in some sentences and used to mean the command
  in others, so every sentence that says what to *run* needs the longer name. The distinction is real but
  it is carried by the reader.
- **`uninstall.sh` now deletes something it must first identify.** The old helper and another project's
  binary occupy the same path, so the removal is conditional on a marker carried by every release that
  shipped the old name - a test fixture proves both directions.

**What enforces it:** `scripts/verify`'s `install` stage runs the installer and the uninstaller against a
`$bindir` seeded with a foreign `preflight` binary and with a copy of the old helper, and requires that
the first is left intact and reported while the second is recognised as this bundle's. The `syntax`,
`version` and `envhelp` stages name `src/preflight-code`, so a path left behind fails the gate rather than
sitting in the tree unbuilding. `AGENTS.md` carries the rule not to reintroduce the retired name.
