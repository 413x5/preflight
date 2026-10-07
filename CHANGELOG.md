# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet. Planned work lives in [ROADMAP.md](ROADMAP.md).

## [0.1.0] - 2026-10-07

Initial release: a deployable, machine-local PR-Agent review setup for the ClinePass endpoint.

### Added

- `install.sh` - one-command, idempotent deploy: installs PR-Agent via `uv`, writes the config,
  creates the secrets file (`chmod 600`, never overwriting an existing one), installs the helpers,
  and links the secrets into the PR-Agent package. Honors `PR_AGENT_KEY`, `PR_AGENT_API_BASE`,
  `PRAGENT_PY`, `PRAGENT_SKIP_TOOL_INSTALL`, `PRAGENT_SKIP_PACKAGE_LINK`, `PRAGENT_HOME`,
  `PRAGENT_BIN_DIR`.
- `uninstall.sh` - removes the helpers and config (and the uv tool with `PRAGENT_REMOVE_TOOL=1`).
- `files/pra` - run PR-Agent with the global config (hosted/PR mode).
- `files/pral` - review the **working tree** (committed + uncommitted + untracked) against the
  remote default branch, with no commit and no history changes; writes `.pr-agent/review.md` and
  `.pr-agent/review.json`. `PRAL_SCOPE=head` limits it to committed content.
- `files/pral-gate` - machine-checkable gate over `review.json` (exit `0`/`1`/`2`/`3`).
- `files/ensure-link.sh` - re-links the secrets file after `uv tool upgrade` recreates the venv.
- `files/pr-agent.toml` - the ClinePass model, the 1M-token budget, the LiteLLM **force-streaming**
  workaround, `num_max_findings = 20`, and the risk/merge signals.
- `files/secrets.toml.example` - the secrets template (no real key).
- `AGENTS-review-snippet.md` - the per-repo instruction block for `AGENTS.md`.
- `README.md`, `CONTRIBUTING.md`, `docs/DESIGN.md`, `docs/TROUBLESHOOTING.md`, this changelog and
  the roadmap.

### Fixed

- The review -> fix -> review "cascade" (fix 3 findings, the next run reveals 3 more) by raising
  `num_max_findings` from the default 3 to 20.
- Snapshotting the working tree for review without touching the index or `HEAD`, using a temporary
  `GIT_INDEX_FILE` plus `git commit-tree` with `commit.gpgsign=false`, so a global `gpgsign = true`
  cannot break it.
