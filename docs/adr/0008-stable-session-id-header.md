# 0008. Inject a stable session-id header into the rendered config

- **Status:** accepted
- **Date:** 2026-11-10
- **Deciders:** 413x5
- **Supersedes / amends:** nothing

## Context and problem statement

pr-agent 0.50.0 added `litellm.add_session_id_to_requests`, which derives an
`x-litellm-session-id` from a PR URL so a LiteLLM gateway can group every
request for one PR into a single session. Preflight runs plain-diff reviews with
no PR URL, so that built-in path never fires and local reviews are not grouped
at all. The goal here is spend-log grouping (and, where the gateway supports it,
cache locality) for a body of work that spans several reviews on one branch.

## Considered options

- **Do nothing.** Local reviews stay ungrouped. Zero code, but the feature
  pr-agent added is unusable from preflight and the header the gateway could use
  is never sent.
- **Use pr-agent's built-in `add_session_id_to_requests`.** One setting, but it
  returns an empty string without a PR URL, so it does nothing in preflight's
  mode. Verified against `_get_request_session_id` in 0.50.0.
- **Derive a stable id in preflight and inject it as `litellm.extra_headers`.** <!-- doc-path-ok: preflight-derived, not a pr-agent key -->
  Works in plain-diff mode, reuses the existing pass-through for `[litellm]`,
  and keeps the id stable across reviews on one branch. Costs: a new derived
  value in the renderer, and the usual obligation to preserve a user's own
  `extra_headers` rather than overwriting it.

## Decision

Derive the id from the reviewed repository's **origin URL** and its current branch
(falling back to the commit hash on a detached HEAD), hash it to a deterministic
UUID, and inject it under the header name configured by `session_id_name` in the
`[preflight]` section of settings.toml (default `session-id`). The origin URL, not
the on-disk path, is the key, so two clones of the same work group together and
credentials embedded in that URL are stripped first; with no origin remote it keys
on the root commit, which is stable across clones. An empty `session_id_name`
disables the injection. The branch, not `HEAD`, is the key so a session survives
commits on the same piece of work. An explicit user value for
that header (or any other header) wins: existing dict and JSON-string forms are
merged; a value that is neither a dict nor a JSON object refuses the render rather
than being silently ignored or overwritten.

## Consequences

- Every local review on a branch now carries the same `session-id` header, so a
  gateway that reads it can group the spend.
- The id changes when the branch changes and on a detached HEAD it tracks the
  commit, which is the honest behaviour there.
- The renderer gains a derived value it must keep consistent with the rest of its
  "refuse rather than silently collide" discipline; the merge logic handles both
  dict and JSON-string forms and refuses to clobber a non-dict value.

**Configuration:** `[preflight] session_id_name` in `settings.toml` only (host-side), default `session-id`; <!-- doc-path-ok: preflight's own table -->
an empty value disables the injection.

**The header name belongs to a gateway, and the default is one gateway's name.** `session-id` is
underclass's generic ingress name: the proxy reads it once and each backend emits its own
(`x-opencode-session` for OpenCode Go, a session header on the Claude path). Shipping that as the default
means a gateway reading it groups from the first run with nothing to configure, and a plain
OpenAI-compatible endpoint ignores the header harmlessly. The cost is that the default is opinionated
rather than universal, and the template says so: **change it to the header your gateway reads.** Shipping
it off was considered and rejected - a configuration that works for nobody until edited is worse than a
default that works for one gateway and is ignored by the rest. It is deliberately NOT settable from a
repository's `.preflight.toml`, because the header name would otherwise be chosen by the reviewed
repository and could collide with authentication headers. The `[preflight]` section is consumed by
the renderer and stripped from the config handed to pr-agent, so pr-agent never sees it.

**The key is an account binding, not just a spend label:** underclass uses the same value as its sticky
`cache_key`, so it decides which upstream account serves a request and holds it there for 24h. That is why
the unit is the branch rather than something coarser: binding every branch of one repository to a single
account would pin unrelated concurrent work together.

**Precedence when a provider sets its own key:** underclass reads `prompt_cache_key` from the request body
BEFORE the session header, so a value the client or provider computes from the actual prompt wins over the
one derived here. <!-- doc-path-ok: `prompt_cache_key` is a gateway/body key, not a pr-agent setting -->
That is the correct order - a prompt-derived key is more accurate than one derived from a branch - and this
record says so only to stop a reader assuming the header is the last word.

**Guessability and branch renames:** the id is a deterministic uuid5 of the origin URL
(or root commit) plus the branch name, so renaming a branch starts a new group and an
observer who can guess the inputs can recompute it. This is an accepted trade-off:
the value is a grouping key, not a secret, and the raw path/URL is never transmitted
(only the hash). A random id would break grouping; a secret salt would require
operator configuration the bundle does not have.

**What enforces it:** the render path in `scripts/settings-render.sh`, plus a
`models`-stage assertion that the injected `session-id` header reaches the rendered
config. The review that settled this record ran with `issues=0`.
