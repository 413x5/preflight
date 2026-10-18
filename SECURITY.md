# Security

## Reporting a vulnerability

Report privately, through GitHub's **Security → Report a vulnerability** form on
<https://github.com/413x5/preflight>. Do not open a public issue for anything exploitable.

This is a personal, local-first project with no release cadence, so there is no response-time commitment.
A report that includes what you ran and what it printed is far more useful than a description alone.

## What this is, and what it deliberately is not

`preflight` is a **local pre-commit harness**. It reviews a working tree with an LLM and refuses a commit
whose content was not reviewed. Every one of its checks runs on the committer's own machine, against the
committer's own work.

That framing decides what counts as a vulnerability here, so it is stated plainly rather than implied:

- **The commit hook is not a boundary against a hostile repository.** It is bypassed by design with
  `git commit --no-verify` or `PREFLIGHT_SKIP=1`, and a committed `.preflight-gate.toml` may relax
  enforcement without the operator setting anything. Both are accepted: the hook exists to catch *your own*
  unreviewed commit, not to stop someone who already has write access to the repository. Do not deploy it
  as a control that gates untrusted contributors.
- **The recorded verdict is not tamper-evident.** `.preflight/review.meta.json` is a plain file that the
  hook reads. Someone who can write to it can make an unreviewed commit look reviewed. Reported as
  "by design" rather than as a vulnerability - but worth knowing before relying on the artifact as
  evidence.
- **There is no server and no listening port.** Nothing in this bundle binds to the network. If a
  deployment adds one, that is a new security decision, not a configuration tweak.
- **Nothing is posted to GitHub.** This is the local layer; no finding, comment or artifact leaves the
  machine.

## Secrets

- The API key lives in `~/.config/preflight/providers.toml`, `chmod 600`, and is **never** placed in the
  shell environment. It reaches pr-agent only through the rendered config, which is 600-mode and outside the
  repository: one file per run, deleted by the run that wrote it.
- Only the `config/*.toml.example` templates are committed - settings has no credential field, and the
  providers example carries placeholders, never a real key.
  A real key is never committed, including in a fixture, a test, a doc or a commit message.
- If you do find a key committed, treat it as compromised: rotate it first, then report.
- **The key is never passed to a command, and `install.sh` never takes one.** It is typed into
  `providers.toml` by the operator, in a file created 600-mode from the moment it exists. It is then read
  by the renderer and written into a per-run file, `$PREFLIGHT_HOME/.pragent.settings.<pid>.toml`, which is
  600-mode. Two runs never share one, so concurrent runs cannot read each other's credential; each run
  removes its own on exit, and a copy of the last is kept at `.pragent.settings.toml` for inspection. The
  default config dir is outside any repository; a config dir
  inside one is accepted only when the directory itself is gitignored there, because the
  review's `git add -A` snapshot would otherwise hand the key to the model - including from a backup or an
  editor copy, which is why the check is the directory and not a list of file names. The renderer refuses
  that layout and names the unignored files, and the resolver also refuses a key in any shadowed or
  derived position.

## Outbound traffic

The only outbound traffic is to the OpenAI-compatible endpoint you configure, which is the service the
product exists to call. There is no telemetry, no analytics, and no remote asset fetching: the bundle
works with the network unplugged apart from the review call itself.

## Scope

In scope: anything that leaks a credential, executes unintended code from repository content, or makes a
check report success it did not earn. The last one is this project's most important class - a guard that
silently passes is worse than no guard - so it is treated as a security report and not a bug report.
