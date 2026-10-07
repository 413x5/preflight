# Troubleshooting

Symptoms we actually hit, and the fix. Most of these apply to any OpenAI-compatible endpoint; the
ones that are ClinePass-specific are labelled.

## `preflight review` fails with a 401 / authentication error

The key is missing or in the wrong place. It belongs in `~/.config/preflight/.secrets.toml` under
`[openai]`, as `key = "..."` (the setting is **`key`**, not `api_key`). The section is `[openai]`
because that is the OpenAI-compatible transport, not because the provider must be OpenAI:

```toml
[openai]
api_base = "https://api.cline.bot/api/v1"   # your endpoint
key      = "..."
```

Then confirm the symlink exists in the package `settings/` dir (`preflight-pr --help` re-links it).

## Using a different provider (not ClinePass)

Re-run `install.sh` with overrides — no hand-editing needed. See the README table for the full list:

```sh
PREFLIGHT_API_BASE=https://api.openai.com/v1 \
PREFLIGHT_KEY=sk-... \
PREFLIGHT_MODEL=gpt-4o \
PREFLIGHT_CUSTOM_MODEL_MAX_TOKENS=0 \
PREFLIGHT_MAX_MODEL_TOKENS=0 \
  ./install.sh
```

The two token knobs are the ones that bite: `0` means "let LiteLLM resolve the context window", which
is what you want for a model LiteLLM already knows (otherwise you override its real window with a
guess). The ClinePass streaming workaround keys on the request host, so it goes inert automatically —
you do not need to delete it.

## `preflight review` fails with "Failed to generate prediction with gpt-5.6-terra" (ClinePass)

That is the **fallback** model. The upstream default fallback is the bare OpenAI id
`gpt-5.6-terra`, which an endpoint can reject outright - ids must be in `provider/model`
form, so a bare id fails with `400 invalid model format. Expected format: modelType/model` (the
endpoint serves this model as `openai/gpt-5.6-terra`). The config here pins a working fallback
instead:

```toml
[config]
fallback_models = ["openai/cline-pass/glm-5.3-flash"]
```

Set it to your own model, or to `[]` to disable fallback (a primary-model failure then fails hard
rather than silently retrying). The id must be in the endpoint's `provider/model` form; `cline-pass/...`
works too, while the `openai/` prefix above routes through LiteLLM's OpenAI-compatible transport.

## The review keeps finding 3 new issues every round (the "cascade")

`pr_reviewer.num_max_findings` defaults to 3, so each run only reports 3 findings and the agent fixes
3 and re-runs to find 3 more. It is set to 20 here so one review reports everything.

## `preflight review` says the repository has no commits yet

`preflight` snapshots from `HEAD`, and an empty repo has none. Make one commit first.

## The review includes my `.preflight/` output

`preflight` adds `.preflight/` to the repo's `.git/info/exclude`. If you changed `PREFLIGHT_DIR`, the new dir is
added on the next run. If you set `PREFLIGHT_DIR` to an absolute or escaping path, the exclude is skipped
on purpose.

## Output is cut off / summaries stop around 32k tokens

`max_model_tokens` was not raised (or was set to a low value). The default here is 1,000,000 so the
packing clamp does not cut the diff; set it to `0` to disable the clamp entirely. For a model LiteLLM
already knows, `custom_model_max_tokens = 0` lets LiteLLM declare the real window instead.

## `git commit-tree` fails with a GPG error

A global `commit.gpgsign = true` was applied to the synthetic snapshot commit. `preflight` passes
`-c commit.gpgsign=false`; make sure you are running the bundled `preflight`, not a modified copy.

## `preflight-pr`/`preflight` print "relinked secrets" on every run

Normal after a `uv tool upgrade` (the venv, and the symlink, are recreated). It is a one-time message
per upgrade; if it happens every run, the symlink target is being deleted - check
`~/.config/preflight/.secrets.toml` exists.
