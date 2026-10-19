# Contributing

This repo is a **portable bundle**: `install.sh` plus the files under `src/` are the source of truth for
the machine-local PR-Agent setup. Keep it portable and keep it provider-agnostic: no endpoint, model id or
host is named in the code, and the configuration happens after the install.

## Setup

```sh
git clone https://github.com/413x5/preflight ~/preflight
cd ~/preflight
./install.sh

# the install ships references only - create your config from them, then edit it
cp ~/.config/preflight/settings.toml.example  ~/.config/preflight/settings.toml
( umask 077; cp ~/.config/preflight/providers.toml.example ~/.config/preflight/providers.toml )
$EDITOR ~/.config/preflight/providers.toml     # endpoint, API key and model id
$EDITOR ~/.config/preflight/settings.toml      # [selection] main = that profile's name
```

Requirements are in [`README.md`](README.md). There is no variable that seeds an endpoint or a model, and
`install.sh` creates neither config file: it knows no endpoint, model id or budget, so a file it wrote could
only be a guess.

`install.sh` is testable without touching your real setup - point it at throwaway directories and skip the
parts that need `uv` or the network:

```sh
T="$(mktemp -d)"
PREFLIGHT_HOME="$T/cfg" PREFLIGHT_BIN_DIR="$T/bin" \
PREFLIGHT_SKIP_TOOL_INSTALL=1 \
  ./install.sh
ls "$T/bin"        # preflight  preflight-pr  preflight-gate
rm -rf "$T"
```

## Before you change anything

Read [`AGENTS.md`](AGENTS.md). It is the operational rules file - the layout, the invariants that must
survive a change, the commands, and the traps that have each cost someone an afternoon. It is written for
whoever works on the code next, human or agent, and it is deliberately the only place those facts live.

Rules worth repeating here because they are the ones most easily broken by accident:

- **No secrets, ever.** Only the `config/*.toml.example` templates are committed, with placeholder keys.
- **No machine-specific paths.** Everything derives from `$HOME` or the documented env vars.
- **Provider-agnostic.** No endpoint, model id or host belongs in the code or the tests. The templates
  carry placeholders, and a user sets the real values in `providers.toml` after installing.
- **Idempotent installs.** `install.sh` must be safe to re-run and must never clobber an existing
  `~/.config/preflight/providers.toml`.
- **`pr-agent` means only the upstream tool.** This bundle is `preflight`; do not reintroduce
  `pra`/`pral`/`pral-gate` or a `pr-agent`-named config file.

## How to propose a change

Work on a short-lived branch (`type/slug`), open a pull request, and squash-merge. Commits follow
[Conventional Commits](https://www.conventionalcommits.org/); the rules are in [`AGENTS.md`](AGENTS.md).
Call out breaking changes (renamed commands, renamed env vars) in both the commit body and
[`CHANGELOG.md`](CHANGELOG.md).

Work not yet done is in [`docs/roadmap.md`](docs/roadmap.md); a decided question is an
[ADR](docs/adr/), and the reasoning behind the current design is in
[`docs/architecture.md`](docs/architecture.md).

## Testing changes

**The gate is one command: `./scripts/verify`.** It composes every check in cost order, cheapest first, and
CI calls it rather than re-listing the steps - so a green local run means a green CI run.

```sh
./scripts/verify            # the gate: everything
./scripts/verify --list     # the stages, if you want to run one while working
```

The live-endpoint case (`./tests/run.sh e2e`) is **not** run in CI: it needs a paid key, and CI must not
depend on one.

Test the commit hook in a **throwaway** repo, never in a working checkout - `core.hooksPath` is clone-wide,
so setting it here would apply to every worktree of this clone:

```sh
R="$(mktemp -d)"; cd "$R"; git init -q -b main .
printf '# x\n' > README.md; git add README.md; git -c commit.gpgsign=false commit -q -m init
mkdir -p .githooks && install -m 0755 "${PREFLIGHT_HOME:-$HOME/.config/preflight}"/githooks/* .githooks/
git add .githooks
git update-index --chmod=+x .githooks/pre-commit .githooks/post-commit   # git IGNORES a non-executable hook
git config core.hooksPath .githooks

git -c commit.gpgsign=false commit --allow-empty -m should-block   # no review -> blocked
preflight-code review && preflight-gate                             # must be a pass
git -c commit.gpgsign=false commit -m "feat: ok"                    # now accepted
```

`tests/run.sh` is the integration suite: real repositories, the real hook files, no framework and no
network. [`tests/README.md`](tests/README.md) maps each requirement to the case that guards it, and
explains why a green suite is not on its own proof that the hook enforces anything.

Workflow actions are pinned to a **moving major tag** (`actions/checkout@v7`), and Dependabot
(`.github/dependabot.yml`) proposes bumps weekly, grouped into one PR. If you add an action, pin the same
way; Dependabot will pick it up. Its PRs run this CI, so a bump that breaks something fails the same checks
a hand-written change would.
