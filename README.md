# pr-agent-bundle — a local, deployable PR-Agent review setup

One command deploys a **machine-local** PR-Agent that reviews your **working tree** (no commit, no GitHub round
 trip) and hands the findings back to whatever coding agent is editing the code. It talks to the ClinePass
endpoint by default (`openai/cline-pass/deepseek-v4.1-flash`).

## What you get

| Command | What it does |
|---|---|
| `pral review` | Reviews the current branch's **working tree** vs the remote default branch; writes `.pr-agent/review.md` + `.pr-agent/review.json` |
| `pral-gate` | Machine check over `review.json` (exit 0 = pass) |
| `pra …` | PR-Agent with the global config (hosted/PR mode, needs a token) |

- Reviews include committed **plus uncommitted and untracked** changes — a review never needs a commit.
- Secrets live in `~/.config/pr-agent/.secrets.toml` (chmod 600), symlinked into the PR-Agent package. **Nothing
  secret ever goes into your shell environment.**

## Requirements

- macOS or Linux, and `git`.
- [`uv`](https://astral.sh/uv) — installs PR-Agent in an isolated venv:
  `curl -LsSf https://astral.sh/uv/install.sh | sh`
- Python 3.12/3.13 (uv can fetch one).
- Network access to the ClinePass endpoint (or your own OpenAI-compatible one).

## Install

```sh
git clone <this-bundle> ~/pr-agent-bundle    # or just copy the folder
cd ~/pr-agent-bundle
./install.sh
$EDITOR ~/.config/pr-agent/.secrets.toml      # paste the API key between the quotes
```

Non-interactive:

```sh
PR_AGENT_KEY=... ./install.sh
```

Different endpoint or model? Set `PR_AGENT_API_BASE=...` (the installer also derives the streaming host from it),
and edit `~/.config/pr-agent/pr-agent.toml` for `config.model`.

## Use

```sh
cd /any/repo
pral review            # -> .pr-agent/review.md + .pr-agent/review.json
pral-gate              # exit 0 = pass; 1 = changes required/issues; 2 = security concerns; 3 = no review
pral describe          # or: pral improve ; pral ask "<question>"
```

## Teach your coding agents

Paste `AGENTS-review-snippet.md` into the repo's `AGENTS.md` so every agent follows the loop: review → fix all
findings in one pass → re-review → commit once when the gate is green.

## What install.sh writes

- `~/.local/bin/{pra,pral,pral-gate}` — the helpers.
- `~/.config/pr-agent/{pr-agent.toml,ensure-link.sh,AGENTS-review-snippet.md}` — config + helpers.
- `~/.config/pr-agent/.secrets.toml` — created only if missing, chmod 600.
- A symlink from that secrets file into the PR-Agent package's `settings/` dir.

## Uninstall

```sh
./uninstall.sh                         # helpers + config (keeps the uv tool)
PRAGENT_REMOVE_TOOL=1 ./uninstall.sh   # also removes the uv tool
```

## Notes

- `pral` adds `.pr-agent/` to each repo's `.git/info/exclude` automatically, so review output is never committed.
- PR-Agent needs `custom_model_max_tokens` for `cline-pass/*` (not in LiteLLM's model table) and a **force-streaming**
  workaround because ClinePass returns a wrapped non-streaming envelope LiteLLM cannot parse — both are pre-set in
  `pr-agent.toml`.
- Upgrading PR-Agent (`uv tool upgrade pr-agent`) recreates the venv; the wrappers re-link the secrets automatically.
