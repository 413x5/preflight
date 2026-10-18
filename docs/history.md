# History

The narrative of what changed and what it replaced. Long-form, append-oriented, and **never copied back
out**: a fact that belongs in a reader's day-to-day document lives there, and this file is where the arc
is reconstructed.

Per-version detail - what shipped, grouped by kind - is in [`../CHANGELOG.md`](../CHANGELOG.md). Current
mechanics are in [`architecture.md`](architecture.md). The dated numbers are in
[`measurements.md`](measurements.md).

## The names

The bundle was first built under the names `pra`, `pral` and `pral-gate`, with configuration in
`~/.config/pr-agent/`. All three were replaced by `preflight`, `preflight-pr` and `preflight-gate`, with
configuration in `~/.config/preflight/`.

The rename was not cosmetic: `pr-agent` is the *upstream tool* this bundle configures, so a bundle command
named after it made every sentence ambiguous - "pr-agent is pinned" was true and "pr-agent failed with a
401" was also true, about two different things. The old names are retired rather than aliased, and the
rule is that `pr-agent` means only the upstream tool.

## Base resolution: a fallback that turned into a silent block

The `worktree` and `head` scopes diff against a resolved base. The first implementation resolved it
loosely and fell through to a bare `main` **unchecked**.

In any repository whose default branch was not `main`, `git diff main...HEAD` was fatal, pr-agent exited 2
with "No diff content received", and the artifact directory was left **empty**. The commit hook reads an
empty artifact directory as "no review found" - so a base-resolution problem (a command that could not
work out what to compare against) surfaced as a block on *every subsequent commit*, with nothing in the
error to suggest the cause.

The replacement verifies each candidate before accepting it (`PREFLIGHT_BASE`, `origin/HEAD`, the remote's
own `HEAD` via `ls-remote --symref`, then `origin/main`, `origin/master`, `main`, `master`) and fails with
exit 4 naming the candidates. Two lessons were generalised beyond this bug, and both appear elsewhere in
the bundle: a check that cannot run must fail loudly rather than return a plausible default, and an
inability to check is indistinguishable from a pass.

## The review context: two attempts before one worked

A reviewer cannot distinguish a deliberate, documented trade-off from an oversight, so it reported the
`.preflight-gate.toml` trust boundary as a finding three separate times. Handing it the repository's own
facts was the fix, and it took three attempts:

1. **`repo_context_files`**, pr-agent's own feature for this. Architecturally dead in plain-diff mode: the
   provider implements neither `get_repo_file_content` nor `get_repo_context_ref`, so `build_repo_context`
   returns empty for a `--stdin` run.
2. **The `[artifacts]` channel, configured in `preflight.toml`.** The section was read and had no effect:
   pr-agent calls `inject_artifact_context()` from `cli.py` *before* `apply_repo_settings()` loads
   `--extra_config_url`. The prompt still read `CI Artifact: context.md`. The settings therefore come from
   the environment, and CI now asserts the section stays out of the config file, so a future edit cannot
   reintroduce a setting that looks configured and does nothing.
3. **The same channel, configured from the environment**, which reaches `pr_reviewer`.

The decision is recorded in [ADR 0004](adr/0004-reviewer-context-from-agents-md.md). The discarded
attempts are kept here because they are the reason the environment - not the config file - is the
interface, and that constraint looks arbitrary from the code alone.

## The reasoning budget: pinned, then reverted

The bundle once set `[config] reasoning_effort = "low"` together with
`additional_reasoning_effort_models`, on the strength of an interleaved A/B on a synthetic 525-line diff
(`~18.6s` / `~4,051` completion tokens against `~9.2s` / `~1,689`). See
[`measurements.md`](measurements.md) for the figures.

It did not reproduce. Four consecutive reviews of this repository's own branch at `low` spent 23k-34k
completion tokens, 60-68% of each run's total. The synthetic number had never been evidence about real
content, and the pin was removed rather than weakened.

What replaced it is an honest statement of the mechanism instead of a value: pr-agent forwards
`reasoning_effort` **only** to a model its bundled litellm metadata calls reasoning-capable, the model ids
in use were not in that table, and the bundle sets neither key - so no effort reached the endpoint at all,
not even pr-agent's own `medium` default. A probe of the constructed request confirmed it: adding `reasoning_effort`
produced a byte-identical payload.

The measuring standard got sharper in the process. A reasoning-budget experiment must run **on a real
branch diff, interleaved, and be read against `new=N/M` as well as wall clock** - because a cheaper round
that reports fewer findings has not saved anything, it has moved the cost to a later round.

## Detecting partial coverage: four markers that each failed

`coverage=PARTIAL` is the signal that a review saw only a slice of the tree, and the whole point is that
`issues=1` on such a review means "the rest was not looked at", not "nearly clean". The marker had to
search model-generated prose that may legitimately *discuss* coverage - and a review of this feature did
exactly that.

In order: a single phrase false-positived; two independent substrings were too weak; the contiguous
sentence failed; searching only after the review table failed; each version was replaced after a real
review defeated it. What finally held was matching the footer **as pr-agent emits it** - horizontal rule,
header, sentence, then the generated file bullets - and additionally restricting the search to the text
after the review's last `</table>`.

Deliberate choices shape the survivor. The match spans the rule and the bold header with a wildcard
rather than naming pr-agent's emoji, because the read is deliberately lenient (so counts survive a
non-UTF-8 `review.md`) and that same leniency rewrites an invalid emoji as U+FFFD - requiring the emoji
meant the marker could never fire on exactly the file it was written to tolerate. And the pinned pr-agent
version ([ADR 0003](adr/0003-pin-pr-agent.md)) exists in part because this marker reads upstream's output
structure: an upstream reword would retire it *silently*, and a review that covered a slice of the tree
still reports real findings.

## The scope default

The first default was a branch scope: diff the branch against a resolved base. It was replaced by the
`commit` scope - `HEAD` to the working-tree snapshot - for the reasons in
[ADR 0002](adr/0002-review-the-pending-commit-by-default.md).

The change looks small and was not: it removed the fetch and the base resolution from the common path, and
it aligned the default with the only scope the hook can enforce. `docs/architecture.md` kept up; `README.md`
did not, and went on describing the old scope for a release. It was caught by reviewing this repository
with its own tool, which is the argument for the loop being used on the bundle itself.

## The commit hook, by the escapes it has had

The hook's history is best read as a list of ways a commit got through unreviewed, because that is what
each rule replaced. Every one of these was a real escape before it was a case:

- a **rename** is status `R`, neither `A` nor `M`, so an `AM`-only filter reported no change at all;
- a changed **file type** is `T`, with the same consequence;
- a **gitlink** (submodule) is not a blob, so a `cat-file -e "HEAD:sub"` test failed for it and its removal
  counted as "not tracked at HEAD";
- `--name-only` without `-z` **quotes** any path that needs it, so a name handed back to git belonged to no
  file at all - and a reviewed tracked file with such a name looked like an untracked scratch file, so its
  **deletion committed unreviewed**;
- `git rm --cached` removes a path from the index while leaving the file on disk;
- deleting a reviewed file, renaming one away, or swapping one for a symlink each removed reviewed content
  without any review seeing the change.

Two more were about the hook's own failure modes rather than an attacker: a **missing helper** could fail
open, and the **first commit** of an empty repository could deadlock adoption (a review needs `HEAD`, and
the hook cannot be installed before the commit that installs it - so that one case is allowed unenforced,
by design).

The current rules and the cases that hold them are in [`architecture.md`](architecture.md) and
[`../tests/README.md`](../tests/README.md).

## The repository's own restructure

`files/` became `src/`, the checked-in config examples moved to `config/`, the dev helpers to `scripts/`,
and the docs acquired a tree with an index, decision records and a history of their own - see
[ADR 0006](adr/0006-adopt-the-playbook-layout.md). Recorded here because it is the change that separated
this file from the others: before it, the explanation, the history and the remediation advice all shared
`docs/DESIGN.md`, and the changelog carried the arc.
