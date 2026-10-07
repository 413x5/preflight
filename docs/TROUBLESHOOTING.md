# Troubleshooting

Symptoms we actually hit, and the fix.

## `pral review` fails with a 401 / authentication error

The key is missing or in the wrong place. It belongs in `~/.config/pr-agent/.secrets.toml` under
`[openai]`, as `key = "..."` (the setting is **`key`**, not `api_key`):

```toml
[openai]
api_base = "https://api.cline.bot/api/v1"
key      = "..."
```

Then confirm the symlink exists in the package `settings/` dir (`pra --help` re-links it).

## `pral review` fails with "Failed to generate prediction with gpt-5.6-terra"

That is the **fallback** model. The upstream default fallback is an OpenAI id, which does not exist on
the ClinePass endpoint. Set `config.fallback_models` to a ClinePass model (or `[]`). See
[ROADMAP](../ROADMAP.md).

## The review keeps finding 3 new issues every round (the "cascade")

`pr_reviewer.num_max_findings` defaults to 3, so each run only reports 3 findings and the agent fixes
3 and re-runs to find 3 more. It is set to 20 here so one review reports everything.

## `pral review` says the repository has no commits yet

`pral` snapshots from `HEAD`, and an empty repo has none. Make one commit first.

## The review includes my `.pr-agent/` output

`pral` adds `.pr-agent/` to the repo's `.git/info/exclude`. If you changed `PRAL_DIR`, the new dir is
added on the next run. If you set `PRAL_DIR` to an absolute or escaping path, the exclude is skipped
on purpose.

## Output is cut off / summaries stop around 32k tokens

`max_model_tokens` was not raised. It is set to 1,000,000 here so the packing clamp does not cut the
diff.

## `git commit-tree` fails with a GPG error

A global `commit.gpgsign = true` was applied to the synthetic snapshot commit. `pral` passes
`-c commit.gpgsign=false`; make sure you are running the bundled `pral`, not a modified copy.

## `pra`/`pral` print "relinked secrets" on every run

Normal after a `uv tool upgrade` (the venv, and the symlink, are recreated). It is a one-time message
per upgrade; if it happens every run, the symlink target is being deleted - check
`~/.config/pr-agent/.secrets.toml` exists.
