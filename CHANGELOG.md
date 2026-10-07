# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **CI** (`.github/workflows/ci.yml`): on every pull request and on pushes to `main`, on both Ubuntu and
  macOS, it checks shell syntax (`bash -n` for the helpers/installer, `sh -n` for the hooks and tests),
  dry-runs `install.sh` into a throwaway prefix (including that it never clobbers an existing
  `.secrets.toml`), validates the generated config as TOML, and runs the offline commit-hook suite. A
  separate job lints the workflows with a pinned `actionlint`. The live-endpoint test is deliberately
  excluded: it needs a paid key, and CI must not depend on one.
- **Dependabot** (`.github/dependabot.yml`) keeps the workflow actions current, weekly and grouped into a
  single pull request. The pins had already gone stale once (CI shipped with `actions/checkout@v5` and
  `actionlint` 1.7.7), so this replaces "someone notices" with an automated bump whose PR is checked by
  the CI it changes.
- **A commit hook that refuses an unreviewed commit.** An agent (or human) could previously skip the review
  entirely; now a repo can make the commit itself fail. Copy the bundled `files/githooks/*` into the repo's
  own `.githooks/` and run `git config core.hooksPath .githooks` (relative - an absolute path breaks git
  worktrees). The hook is opt-in per repo and covers every worktree.
  - It **verifies** that the content being committed is exactly what `preflight review` reviewed, and never
    runs a review itself (a review cannot be graded before the commit it describes exists).
  - The binding is **content-based, not time-based**: an edit after the review, or a newly staged unreviewed
    file, blocks the commit and names the paths.
  - Reviewed-but-uncommitted content is ignored, so `git commit -a` keeps working with untracked scratch
    files. This is `containment` - deliberately not strict equality, which would break `commit -a`, and not
    a superset check, which would let a brand-new unreviewed file - or the deletion of a reviewed one -
    through. Deleting a whole reviewed file is blocked (`D` records that `HEAD` knows), while an untracked
    scratch file that is merely not being committed is ignored. Renaming a reviewed file (`git mv`) and
    swapping one for a symlink are blocked too - with rename detection on those are `R`/`T`, which an
    `AM`-only filter reports as no change at all.
  - The **first** commit in a repository with no history is allowed but not enforced: `preflight review`
    cannot run before a first commit exists, so blocking would make the hook impossible to adopt.
  - It is **strictly read-only**: it never modifies the index, `HEAD`, the working tree, or the artifacts,
    and it fails closed when the helper is missing.
  - `PREFLIGHT_SCOPE=head` reviews cannot be enforced (they cover already-committed content), so the hook
    says so on stderr rather than pretending; a `post-commit` companion warns when enforcement did not apply.
  - `preflight review` now also writes `.preflight/review.meta.json`, recording the tree it reviewed and the
    `preflight-gate` verdict. `.preflight/` is left in place on a block so the findings can be inspected.
- New `preflight hook` subcommand and `preflight-hook` helper; `install.sh` installs both plus the example
    hooks into `~/.config/preflight/`.
  - Covered by an integration suite in `tests/` (`./tests/run.sh`): real repositories, the real hook
    files, no framework and no network. 26 cases (25 offline plus one live end-to-end), one per
    requirement (`REQ-HOOK-01`..`26`, mapped in `tests/README.md`), each protecting a specific behaviour -
    including the seven bypasses found while building this (unreviewed deletions, renames, symlink
    typechanges, `git rm --cached`, reviewed files whose names git quotes, gitlinks, and an unset `HOME`).
    Every fix was reverted in turn to confirm the matching case fails without it; a neutered hook turns 16
    offline cases red.
  - Path listings use `-z` and the paths are handled as raw bytes. `--name-only` without `-z` wraps any
    path that needs quoting in double quotes and backslash-escapes it, and `core.quotePath` cannot
    disable that for the characters that matter. Handing such a name back to git asks about a path that
    does not exist, which made a reviewed file named `a"b.py`, `c\d.py` or `café.py` indistinguishable
    from an untracked scratch file - so deleting it committed unreviewed.
  - The tracked paths at `HEAD` are read with `git ls-tree` rather than by asking git about each
    candidate path. `git cat-file -e "HEAD:sub"` fails for a **gitlink**, so a submodule removal was
    classified as "not tracked at HEAD" and slipped through unreviewed.
- **A selfcheck for the hook test suite** (`./tests/run.sh selfcheck`, wired into CI). A green suite was
  not evidence that the hook enforced anything: stubbing the hook out entirely still satisfied 9 of the 25
  offline cases, because those assert *acceptance* (a reviewed deletion, `commit -a`, a reviewed rename),
  exercise a deliberate bypass, or test the separate example hook. Nothing kept the enforcement-sensitive
  cases sensitive, so a case claiming to catch an unreviewed commit could have passed with the hook
  disabled and nobody would have known. The selfcheck re-runs the whole suite against a neutered hook and
  requires exactly the declared enforcement-sensitive cases to fail, reports the split
  (16 sensitive / 9 insensitive), and **requires every case to be classified** - an unclassified case, or
  a sensitive case that passes or skips, fails it. The check is itself mutation-tested.

### Fixed

- `files/githooks/pre-commit` aborted with `HOME: unbound variable` when `HOME` was unset, because it ran
  under `set -u` and expanded a bare `$HOME`. The commit was still refused - it failed closed - but with a
  confusing shell error instead of the documented "the preflight helper is missing" message. Now
  `${HOME:-}`, so an unset `HOME` degrades to the intended message. The live review of this repo reported
  it, which is a good argument for running `preflight review` on the bundle itself.
- `README.md` claimed "Python 3.12/3.13"; `install.sh` defaults to `PREFLIGHT_PY=3.13`.
- `docs/TROUBLESHOOTING.md` told you to re-record a failed verdict with
  `PREFLIGHT_GATE_ALLOW_ISSUES=1 preflight-gate`. That cannot work: the gate only prints and never rewrites
  `.preflight/review.meta.json`, so the verdict stayed `fail` and the commit stayed blocked. It now shows
  the command that does work (`PREFLIGHT_GATE_ALLOW_ISSUES=1 preflight review`) and notes that the opt-out
  relaxes key issues only - security concerns and `merge_recommendation=changes_required` still fail.
- `ROADMAP.md` referenced a `github-action.example.yml` staged for Layer 3 that has never existed in any
  commit.

### Changed

- **Added `AGENTS.md`** and linked it from `README.md` and `CONTRIBUTING.md`. It is instructions for agents
  *changing this repo* - the hook's invariants, the checks to run, the traps that have already caught
  someone - as opposed to `AGENTS-review-snippet.md`, which is the block pasted into a *consuming* repo.

- CI actions updated to current: `actions/checkout` v5 to v7 and `actionlint` 1.7.7 to 1.7.12. They stay
  pinned to a moving major tag, so patch releases arrive without an edit. Note that `checkout` v6 and later
  run on Node 24, which the `ubuntu-latest` and `macos-latest` runner images already provide.
- **Renamed the bundle from `pr-agent` to `preflight`**, so it no longer collides with the upstream
  PR-Agent project it wraps. After this change `pr-agent` means exactly one thing: the upstream tool.
  - Commands: `pra` → `preflight-pr`, `pral` → `preflight`, `pral-gate` → `preflight-gate`.
  - Config: `~/.config/pr-agent/pr-agent.toml` → `~/.config/preflight/preflight.toml`.
  - Artifacts: `.pr-agent/` → `.preflight/`.
  - Env: `PRAGENT_*`/`PR_AGENT_*` → `PREFLIGHT_*`, and `PRAL_DIR`/`PRAL_SCOPE`/`PRAL_GATE_*` →
    `PREFLIGHT_DIR`/`PREFLIGHT_SCOPE`/`PREFLIGHT_GATE_*`.
  - Repo: `413x5/pr-agent` → `413x5/preflight` (GitHub redirects the old name).
  - **Breaking.** Any repo whose `AGENTS.md` carries the old snippet calls `pral`, which no longer
    exists - re-paste `AGENTS-review-snippet.md`. The secrets file is *moved*, not regenerated (a
    fresh install would create an empty key). `uninstall.sh` cleans up the old names.
- **Decoupled the bundle from ClinePass.** It now documents and supports any OpenAI-compatible
  endpoint, with ClinePass as the built-in default rather than the premise. `install.sh` gains
  `PREFLIGHT_MODEL`, `PREFLIGHT_FALLBACK_MODELS`, `PREFLIGHT_CUSTOM_MODEL_MAX_TOKENS`,
  `PREFLIGHT_MAX_MODEL_TOKENS`, and `PREFLIGHT_FORCE_STREAMING_HOST`.
- The ClinePass force-streaming workaround is now keyed on the `api.cline.bot` literal instead of
  whatever `api_base` is configured. Previously a non-ClinePass endpoint silently inherited a
  ClinePass-specific quirk; now the block is inert unless the endpoint really is ClinePass.
- `AGENTS-review-snippet.md` now points at this bundle's repository, so an agent working in another
  repo can read current guidance (README, ROADMAP, design, troubleshooting, changelog) as the bundle
  evolves.
- `custom_model_max_tokens = 0` / `max_model_tokens = 0` are now documented as meaningful: `0` means
  "let LiteLLM resolve the window" and "no clamp" respectively, rather than being unexplained.

### Fixed

- `config.fallback_models` no longer points at a model the ClinePass endpoint cannot route. The
  upstream default (`["gpt-5.6-terra"]`) is a bare id, which the endpoint rejects (ids must be
  `provider/model`), so a failed primary model retried against a dead one; it is now
  `["openai/cline-pass/glm-5.3-flash"]`.

## [0.1.0] - 2026-10-07

Initial release: a deployable, machine-local PR-Agent review setup for the ClinePass endpoint.

> The command/file/env names below are the ones this version shipped with; they were renamed in the
> `[Unreleased]` entry above.

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

[Unreleased]: https://github.com/413x5/preflight/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/413x5/preflight/releases/tag/v0.1.0
