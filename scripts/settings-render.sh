#!/usr/bin/env bash
# Turn $PREFLIGHT_HOME/settings.toml + providers.toml into the ONE config file pr-agent is launched with,
# written to $PREFLIGHT_HOME/.pragent.settings.<pid>.toml (600-mode, one per run).
# Sourced by BOTH helpers, so `preflight` and `preflight-pr` resolve the same files the same way and
# cannot disagree about which model answers.
#
# settings.toml says what the review does: the assignment ([selection]) and pr-agent's own sections, of
# which [pr_reviewer] is the one this bundle sets. Per-model budgets are NOT here - they belong to a
# [profiles.<name>.config] table in providers.toml, beside the model they describe.
#
# Why a rendered file rather than pr-agent's env-var layer: a run's endpoint and credential have to reach
# the section pr-agent reads them from, and the transport can only be PINNED by a settings key
# (`litellm.custom_llm_provider`). Deriving both from one provider entry is what makes a pin that
# disagrees with the endpoint - which LiteLLM resolves silently, to the wrong host - unrepresentable.
# The rendered file is 600-mode at $PREFLIGHT_HOME/.pragent.settings.<pid>.toml, one per run. Mechanism:
# docs/architecture.md.
#
# Nothing here puts a credential in the environment: the key goes into the rendered file only.

# Two files, two jobs: settings.toml says what the REVIEW does (which profiles are assigned, and the
# run-wide knobs), and providers.toml says which MODELS exist, what each one needs, and where its endpoint
# is. Keeping a profile beside the provider it names is deliberate - the two halves of "how this model is
# reached" cannot drift apart, and a rename lands in one file.
#
# INTERNAL, not a setting: the channel by which __preflight_render_settings hands the rendered config's
# path to its caller. It is written and read only by the preflight helpers, never by a user - a review that
# set it by hand would point pr-agent at a file this process does not own or clean up. Empty means no
# render was produced, which the caller treats as a refusal (settings.toml missing, or assigning no profile).
PREFLIGHT_RENDERED_CONFIG=''

# The command that sourced this file, for the messages below: the two helpers share this resolver, and a
# refusal has to name the command the operator actually ran. Set by the caller before sourcing. The
# fallback is the bundle's own command, because the gate and a direct `. scripts/settings-render.sh`
# source this file without one - and the retired bare name must never appear in output.
__preflight_caller_name="${__preflight_caller_name:-preflight-code}"

# The rendered path is PER RUN: `$PREFLIGHT_HOME/.pragent.settings.<pid>.toml`. Two runs sharing one config
# dir therefore never touch the same file, so no lock is needed - and a lock was the wrong shape anyway,
# because it made correctness depend on every caller releasing it (the gate and a direct call to
# `__preflight_render_settings` do not, which left a lock the next run waited out).
#
# The suffix is the SHELL's pid (`$$`), so it is unique per run without `mktemp`, and the name still ends
# in `.toml` - which pr-agent's settings loader requires ("Only .toml files are allowed. Skipping").
#
# A per-run file cannot be "the latest render to inspect" without accumulating one file per run, so the
# caller removes its own from the EXIT trap and the copy at the fixed name is the one that survives.

# Refuse when the config dir is inside the repository BEING REVIEWED and the files that hold the key
# are not ignored there. Called TWICE: once by each helper BEFORE it stages the working tree, because
# that staging runs `git add -A` on the reviewed tree - so an unignored providers.toml would be hashed
# into .git/objects before the render could refuse - and again here, so a caller that skips the
# pre-check still refuses rather than rendering beside a file the snapshot already took.
#
# Scoped to the repo under review deliberately: the config dir living in SOME git tree (a `$HOME` kept
# in version control, a shared dotfiles checkout) is not the same hazard, because the reviewed repo's
# snapshot never sees it. Comparing the two roots is what keeps that from blocking every review.
__preflight_refuse_in_repo_config() {
  local cfgdir="${1:-${PREFLIGHT_HOME:-${HOME:-}/.config/preflight}}"
  local _abs _root _reviewed _untracked _prefix
  _abs="$(cd "$cfgdir" 2>/dev/null && pwd -P)" || _abs=''
  _root="$(cd "$cfgdir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || _root=''
  _reviewed="$(git rev-parse --show-toplevel 2>/dev/null)" || _reviewed=''
  if [ -n "$_root" ] && [ "$_root" = "$_reviewed" ]; then
    # The DIRECTORY is the unit, never a list of known file names: the snapshot is `git add -A`, which
    # stages whatever the directory holds, and a key survives in a backup or an editor copy
    # (`providers.toml.bak`, `providers.toml~`, `.providers.toml.swp`) whose name no list can predict.
    # `.` is the pathspec, not the repo-relative prefix: with `-C "$_abs"` a pathspec is resolved from
    # _abs, so passing the prefix asks for `_abs/<prefix>` and matches nothing.
    _prefix="$(git -C "$_abs" rev-parse --show-prefix 2>/dev/null)"
    _untracked="$(git -C "$_abs" ls-files -o --exclude-standard -- . 2>/dev/null | sed "s|^| $_prefix|")"
    if [ -n "$_untracked" ]; then
      printf '%s: %s is inside the repository being reviewed, and these are not ignored there:%s\n' "$__preflight_caller_name" \
        "$cfgdir" "$_untracked" >&2
      printf '%s: they carry the model configuration and the API key, and this review stages the\n' "$__preflight_caller_name" >&2
      printf '%s: working tree - so they would be handed to the model. Ignore the whole directory\n' "$__preflight_caller_name" >&2
      if [ -n "$_prefix" ]; then
        printf '%s: (%s), or move PREFLIGHT_HOME (default ~/.config/preflight) outside it\n' "$__preflight_caller_name" \
          "$_prefix" >&2
      else
        printf '%s: - it is the repository root here, so no directory rule can cover it, and no\n' "$__preflight_caller_name" >&2
        printf '%s: .gitignore rule names every file the directory may ever hold. Move\n' "$__preflight_caller_name" >&2
        printf '%s: PREFLIGHT_HOME (default ~/.config/preflight) outside the repository\n' "$__preflight_caller_name" >&2
      fi
      return 2
    fi
  fi
  return 0
}

__preflight_render_settings() {
  local cfgdir="${1:-${PREFLIGHT_HOME:-${HOME:-}/.config/preflight}}"
  local settings="$cfgdir/settings.toml" out rc=0
  # The repository whose `.preflight.toml` may override the machine settings. Passed by the caller, never
  # guessed here: `preflight-code` has already resolved the reviewed repository's root, and this function is
  # also called with fixtures that must not pick up the checkout's own file.
  local repo_root="${2:-}" repo_override=''
  if [ -n "$repo_root" ]; then
    repo_override="$repo_root/.preflight.toml"
  fi

  # No settings.toml means no model, and there is no other config to fall back to.
  if [ ! -f "$settings" ]; then
    printf '%s: %s was not found\n' "$__preflight_caller_name" "$settings" >&2
    printf '%s: it names the profiles to review with, and %s defines them\n' "$__preflight_caller_name" "$cfgdir/providers.toml" >&2
    printf '%s: create it from the example installed beside it:\n' "$__preflight_caller_name" >&2
    printf '%s:   cp "%s/settings.toml.example"  "%s/settings.toml"\n' "$__preflight_caller_name" "$cfgdir" "$cfgdir" >&2
    # Named only when it is also absent: copying it over an existing providers.toml would replace a keyed
    # file with the empty-key template, so this line is a remedy only in the state it applies to.
    if [ ! -f "$cfgdir/providers.toml" ]; then
      printf '%s: %s is missing too, and nothing defines the profiles without it:\n' "$__preflight_caller_name" "$cfgdir/providers.toml" >&2
      printf '%s:   cp "%s/providers.toml.example" "%s/providers.toml"   # then chmod 600\n' "$__preflight_caller_name" "$cfgdir" "$cfgdir" >&2
    fi
    return 2
  fi

  # Readability is checked BEFORE the content test below, because that test's `grep` exits non-zero both
  # for "no uncommented line" and for "could not read the file" - and reading the second as the first
  # would review on some other model while the user's configuration sat there ignored, which is the
  # silent-wrong-model failure this whole resolver exists to prevent.
  if [ ! -r "$settings" ]; then
    printf '%s: %s is present but cannot be read, so its assignment cannot be applied\n' "$__preflight_caller_name" "$settings" >&2
    printf '%s: refusing to review with a model configuration that was not applied\n' "$__preflight_caller_name" >&2
    return 2
  fi

  # A file with no uncommented line assigns no profile, so there is NO MODEL - and with no fallback config
  # left, the caller would launch pr-agent with an empty `--extra_config_url` and it would answer on its own
  # defaults. That is the silent-wrong-model failure this resolver exists to prevent, so this refuses
  # (rather than the `return 0` it used to do, when preflight.toml could still supply a model).
  #
  # Decided WITHOUT a parser, so the message is the same on a machine with no python3: the test is
  # one-directional - a line is "content" unless its first non-blank character is `#` - so a `#` inside a
  # quoted value can never make a real assignment look like a comment.
  if ! grep -qE '^[[:space:]]*[^[:space:]#]' "$settings"; then
    printf '%s: %s assigns no model profile (every line is blank or a comment)\n' "$__preflight_caller_name" "$settings" >&2
    printf '%s: set [%s] main to a [profiles.<name>] table in %s\n' "$__preflight_caller_name" \
      "selection" "$cfgdir/providers.toml" >&2
    printf '%s: refusing to review on pr-agent default settings\n' "$__preflight_caller_name" >&2
    return 2
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s: %s is present, but python3 is not on PATH to read it\n' "$__preflight_caller_name" "$settings" >&2
    printf '%s: refusing to review with a model configuration that was not applied\n' "$__preflight_caller_name" >&2
    return 2
  fi

  # A FIXED path, in the config dir, beside the two files it is rendered from. It was a `mktemp` file
  # outside the repository, deleted from an EXIT trap - and every problem in that design was the
  # indirection: the credential could outlive a run that died before its trap, a caller had to propagate
  # the path (a subshell lost it, so a test leaked the operator's real key), and macOS and GNU `mktemp`
  # disagree about trailing Xs, so a `.toml` name needed a rename.
  #
  # None of it is needed. The path is derivable from the pid, outside any repository, and 600-mode from the
  # moment it exists, so no caller has to propagate a random name. The renderer also writes a copy at the
  # fixed `.pragent.settings.toml` for inspection; that copy is what a run is inspected through, not the
  # per-run file.
  #
  # The `.toml` SUFFIX is load-bearing, not cosmetic: pr-agent's settings loader skips any file that is not
  # named `*.toml` ("Only .toml files are allowed. Skipping"), so a config under another name would be
  # accepted as `--extra_config_url` and then silently ignored - the run answering on another model while
  # everything looked normal.
  # PER RUN, from the shell's pid: no two runs share a file, so there is nothing to serialise.
  out="$cfgdir/.pragent.settings.$$.toml"

  __preflight_refuse_in_repo_config "$cfgdir" || return 2

  # Removed first, then created 600 by the redirect below: overwriting in place would keep whatever mode
  # the old file had, and a file restored from a backup at 0644 is exactly the case that matters.
  rm -f "$out"
  if ! ( umask 077; : > "$out" ) 2>/dev/null; then
    printf '%s: could not create %s to render the model configuration into\n' "$__preflight_caller_name" "$out" >&2
    printf '%s: refusing to review with a model configuration that was not applied\n' "$__preflight_caller_name" >&2
    return 2
  fi
  chmod 600 "$out" 2>/dev/null || true

  # Not inside `$( )`: the heredoc body sits in a command substitution otherwise, which is the macOS
  # bash 3.2 mis-parse AGENTS.md documents. The status is captured by `if`, so a config error reaches
  # the caller as a refusal rather than as a review run with the wrong model.
  #
  # Exit codes are the channel: 0 means a rendered config is in $PREFLIGHT_RENDERED_CONFIG, and anything
  # else is a REFUSAL the caller propagates. There is no third status: a file that assigns no profile is a
  # refusal like any other (there is no fallback config to review with), so a caller only has to check
  # "non-zero means stop" and never has to tell two kinds of success apart.
  # The repository's own override file, resolved at the repository root so a review started from a
  # subdirectory finds the same file the commit does. Empty outside a repository, where there is nothing
  # to override.
  if ! python3 - "$settings" "$cfgdir/providers.toml" "$out" "$repo_override" "$__preflight_caller_name" <<'PY'
import copy, json, os, re, sys

# The command that sourced this file (`preflight-code` or `preflight-pr`); every message below names
# it, because a refusal has to identify the command the operator actually ran.
PROG = sys.argv[5] if len(sys.argv) > 5 else "preflight-code"

try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write(
        f"{PROG}: this python3 has no tomllib (Python 3.11+), so settings.toml cannot be read\n"
        f"{PROG}: refusing to review with a model configuration that was not applied\n"
    )
    sys.exit(2)

settings_path, providers_path, out_path = sys.argv[1:4]
repo_path = sys.argv[4] if len(sys.argv) > 4 else ""

# transport -> (section pr-agent reads, key name inside it, whether it reads the endpoint from config).
# Generated from pr-agent's own PROVIDER_SETTING_PATHS. A transport pr-agent does not read would take the
# pin without complaint and then serve the request from the provider's default host, with this entry's
# credential - the silent wrong-endpoint failure this renderer exists to
# make unrepresentable. So an unknown transport is refused by name, and scripts/verify asserts this table
# against the installed pr-agent, so an upgrade that moves a provider fails the gate rather than
# redirecting a request.
TRANSPORTS = {
    "openai": ("openai", "key", True),
    "openrouter": ("openrouter", "key", True),
    "moonshot": ("moonshot", "key", True),
    "ollama": ("ollama", "api_key", True),
    "huggingface": ("huggingface", "key", True),
    "databricks": ("databricks", "api_key", True),
    "anthropic": ("anthropic", "key", False),
    "codestral": ("codestral", "key", False),
    "cohere": ("cohere", "key", False),
    "cohere_chat": ("cohere", "key", False),
    "compactifai": ("compactifai", "key", False),
    "dashscope": ("dashscope", "key", False),
    "deepinfra": ("deepinfra", "key", False),
    "deepseek": ("deepseek", "key", False),
    "gemini": ("google_ai_studio", "gemini_api_key", False),
    "groq": ("groq", "key", False),
    "mistral": ("mistral", "key", False),
    "replicate": ("replicate", "key", False),
    "sambanova": ("sambanova", "key", False),
    "text-completion-codestral": ("codestral", "key", False),
    "xai": ("xai", "key", False),
    "xiaomi_mimo": ("xiaomi_mimo", "key", False),
    "zai": ("zai", "key", False),
}
ENDPOINT_TRANSPORTS = ", ".join(sorted(t for t, (_, _, reads) in TRANSPORTS.items() if reads))
# The settings sections an endpoint and its credential can live in, per the transport table above. Used to
# refuse a credential left in ANY of them, not only the one this run writes.
_ENDPOINT_SECTIONS = {section for section, _, _ in TRANSPORTS.values()} | {"openai"}
# ...and every name a credential can be written under. Derived from the table rather than listed: `gemini`
# uses `gemini_api_key`, so a hard-coded ("key", "api_key") quietly left one spelling unrefused.
_CREDENTIAL_KEYS = {name for _, name, _ in TRANSPORTS.values()} | {"key", "api_key"}

# A profile carries its model, its provider, and `config` - the settings that ARE a property of that model:
# the token budgets it needs, and knobs like `reasoning_effort`. Two models genuinely differ here, which is
# what profiles exist for, so these stay per profile and follow whichever profile is assigned.
#
# It deliberately does NOT carry `pr_reviewer`: pr-agent applies those to the whole run, so a copy per
# profile is one answer written as many times as there are profiles, free to drift - which is how two
# profiles ended up with identical review blocks. That one section is general, at the top level.
PROFILE_SECTIONS = ("config",)
PROFILE_KEYS = ("provider", "model")
PROVIDER_KEYS = ("api_base", "key", "transport", "stream", "litellm")
# The `[litellm]` keys a provider may set. Each is genuinely per endpoint - a callback, a timeout, a
# caching policy, a model_id ARN - so it belongs with the provider rather than on the run.
PROVIDER_LITELLM_KEYS = (
    "enable_callbacks", "success_callback", "failure_callback", "service_callback",
    "turn_off_message_logging", "callback_timeout_seconds", "cache_control_injection_points",
    "drop_params", "model_id",
)
# The three the renderer DERIVES, and therefore refuses here: accepting them would be a second answer to
# a question the provider entry already answers, and the pin already has a silent-mismatch failure mode.
DERIVED_LITELLM_KEYS = (
    "custom_llm_provider", "force_streaming_custom_llm_provider", "force_streaming_api_base_substrings",
)
# Config keys the renderer DERIVES from a configured reasoning_effort, so a value written here (or in a
# profile, or in a repo override) would be a second answer that the render overwrites silently. Refused
# by name in every position, then derived when reasoning_effort is actually set - which is what makes a
# configured effort reach the provider instead of being dropped.
DERIVED_CONFIG_KEYS = ("additional_reasoning_effort_models",)
# settings.toml is the ONLY general source: it IS the config pr-agent receives,
# through a render that adds the model, its endpoint and the litellm keys derived from the provider. So its
# sections are pr-agent's own, passed through unchanged - there is no allow-list to keep in step with
# upstream, because refusing a section pr-agent understands would only block a real setting.
#
# `selection` is the one section preflight invents, and it exists because `[config]` is now pr-agent's:
# `main` and `fallback` name PROFILES, which is not a pr-agent key, so they cannot live in `[config]`
# without being written into pr-agent's own section and read as settings it does not have.
SELECTION_SECTION = "selection"
SELECTION_KEYS = ("main", "fallback")
# The gate's policy, read by `preflight-gate` rather than by pr-agent: the section is stripped from the
# rendered config, because writing it there would look configured and do nothing. It lives in the same
# file so a repository has ONE file for everything preflight can be told.
GATE_SECTION = "gate"
# Written by the render from the assignment, so a value here would be a second answer.
ASSIGNMENT_KEYS = ("model", "fallback_models")


def refuse(*lines):
    for line in lines:
        print(f"{PROG}: {line}", file=sys.stderr)
    sys.exit(2)


def plain_name(key):
    """True for a key that can name a pr-agent setting."""
    return re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) is not None


def quote_key(key):
    return key if re.fullmatch(r"[A-Za-z0-9_-]+", key) else json.dumps(key)


def fmt(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        # json.dumps emits a TOML basic string: every escape it produces (\\, \", \n, \t, \uXXXX) is a
        # TOML escape, and it escapes non-ASCII rather than leaving the encoding to the locale.
        return json.dumps(value)
    if isinstance(value, list):
        return "[" + ", ".join(fmt(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{quote_key(k)} = {fmt(v)}" for k, v in value.items()) + " }"
    refuse(f"a {type(value).__name__} cannot be written into the rendered configuration")


def emit(table, path, lines):
    """Write a table as TOML: its scalars first, then its sub-tables, which TOML requires."""
    if path:
        lines.append(f"[{'.'.join(quote_key(part) for part in path)}]")
    for key, value in table.items():
        if not isinstance(value, dict):
            lines.append(f"{quote_key(key)} = {fmt(value)}")
    for key, value in table.items():
        if isinstance(value, dict):
            if lines and lines[-1] != "":
                lines.append("")
            emit(value, path + [key], lines)


def load(path, label):
    """Parse a config file. An unreadable or unparseable one is a refusal, never a silent default."""
    if not os.access(path, os.R_OK):
        refuse(f"{label} {path} is present but cannot be read",
               "refusing to review with a model configuration that was not applied")
    try:
        with open(path, "rb") as handle:
            data = tomllib.load(handle)
    except Exception as exc:
        refuse(f"{label} {path} cannot be read as TOML ({exc})")
    if not isinstance(data, dict):
        refuse(f"{label} {path} does not contain a table at the top level")
    return data


# ------------------------------------------------------------------ settings.toml + .preflight.toml
data = load(settings_path, "settings.toml")

# A repository may override any setting in ONE committed file, `.preflight.toml` (the name avoids
# `.preflight/`, which pr-agent owns through `--output`/`--json-output`). The merge is by SECTION, then by
# KEY: a repo that sets [pr_reviewer] num_max_findings keeps every other [pr_reviewer] value from
# settings.toml, so an override says one thing and not a copy of the whole review. `[profiles.*]` and
# `[providers.*]` and `[selection]` are refused there: naming a provider, directly or through a profile
# assignment, is choosing which machine credential a review spends, and a repository does not do that.
if repo_path and os.path.exists(repo_path):
    repo_data = load(repo_path, ".preflight.toml")
    for key in sorted(repo_data):
        if not isinstance(repo_data[key], dict):
            refuse(f".preflight.toml '{key}' is not a table",
                   "every section of .preflight.toml is a [table] of settings")
    # `[selection]` is refused with them: naming a profile is how a model - and therefore a provider and
    # its key - is chosen, so a committed file that assigned one would decide which credential a review
    # spends on every machine that clones the repository. It is the same hazard as naming a provider
    # directly, one indirection away.
    for _stray in ("providers", "profiles", SELECTION_SECTION):
        if _stray in repo_data:
            refuse(f".preflight.toml defines [{_stray}], which a repository cannot override",
                   "the profiles, the providers and the assignment decide a model and a credential entry,",
                   "and a committed file choosing one would spend that key on every machine that clones it",
                   "override review settings and the [gate] policy here; keep the models in "
                   "settings.toml/providers.toml")
    for _dk in DERIVED_CONFIG_KEYS:
        if isinstance(repo_data.get("config"), dict) and _dk in repo_data["config"]:
            refuse(f".preflight.toml [config] sets '{_dk}', which preflight derives",
                   "it is derived from the assigned profile's reasoning_effort, so a value here would be",
                   "overwritten and silently ignored",
                   "remove it from .preflight.toml [config]")
    for section, values in repo_data.items():
        base = data.get(section)
        if base is None:
            data[section] = copy.deepcopy(values)
        elif isinstance(base, dict):
            # A deep merge: a nested table (a provider's litellm quirk, a future nested setting) is
            # overridden key by key too, so a repo changing one callback keeps its siblings.
            for key, value in values.items():
                if isinstance(base.get(key), dict) and isinstance(value, dict):
                    base[key].update(copy.deepcopy(value))
                else:
                    base[key] = copy.deepcopy(value)
        else:
            data[section] = copy.deepcopy(values)

# Every top-level section is a table (a scalar at the top level is a TOML mistake, not a setting).
for key in sorted(data):
    if not isinstance(data[key], dict):
        refuse(f"settings.toml '{key}' is not a table",
               "every section of settings.toml is a [table] of settings")
# The other file's tables, pasted here. `[providers.*]` carries `keys`, and `[profiles.*]` carries the model
# and budgets - none of it means anything to pr-agent, so it would be written into the rendered config
# (credential included) and left in a settings.toml nothing mode-checks. Refused by name.
if "providers" in data or "profiles" in data:
    _stray = "providers" if "providers" in data else "profiles"
    refuse(f"settings.toml defines [{_stray}.*], which belongs in providers.toml",
           "settings.toml says what the REVIEW does; providers.toml holds the endpoints, their keys and",
           "the profiles that use them - a table in the wrong file reads as configured and does nothing",
           f"move that table to providers.toml and remove it from settings.toml")

root_config = data.get(SELECTION_SECTION) or {}
if not isinstance(root_config, dict):
    refuse(f"settings.toml [{SELECTION_SECTION}] is not a table")
for key in sorted(set(root_config) - set(SELECTION_KEYS)):
    refuse(f"settings.toml has unknown key '{key}' in [{SELECTION_SECTION}]",
           f"expected one of {list(SELECTION_KEYS)} - the profiles to use, by name")

# A [config] value for either of these would be overwritten by the assignment, so it is refused rather
# than silently ignored: the reader would otherwise think it chose the model.
for key in ASSIGNMENT_KEYS:
    if key in (data.get("config") or {}):
        refuse(f"settings.toml [config] sets '{key}', which [{SELECTION_SECTION}] decides",
               "which model answers is the assignment's job; a second place to name it is a second answer")

# A [config] value for any of these would be overwritten by the render's derivation, so it is refused
# rather than silently ignored: the reader would otherwise think they registered the model, while the
# render replaces it with the model that is actually being asked.
for key in DERIVED_CONFIG_KEYS:
    if key in (data.get("config") or {}):
        refuse(f"settings.toml [config] sets '{key}', which preflight derives",
               "it is derived from the assigned profile's reasoning_effort, so a value here would be",
               "overwritten and silently ignored",
               "remove it from settings.toml [config] and set reasoning_effort on the profile instead")

main_name = root_config.get("main", "")
if not isinstance(main_name, str):
    refuse("settings.toml [selection] main must be a profile name in quotes")
main_name = main_name.strip()

fallback_value = root_config.get("fallback", [])
if isinstance(fallback_value, str):
    refuse("settings.toml [selection] fallback must be a list of profile names, in the order pr-agent should try them")
if not isinstance(fallback_value, list) or not all(isinstance(n, str) for n in fallback_value):
    refuse("settings.toml [selection] fallback must be a list of profile names")
fallback_names = [n.strip() for n in fallback_value if n.strip()]

# ------------------------------------------------------------------ providers.toml
#
# This file holds both the endpoints AND the profiles: a profile is only meaningful against the provider
# it names, so keeping them together means the two halves of "how this model is reached" cannot drift
# apart, and a rename lands in one file instead of two.
provider_table = {}
profile_table = {}
if os.path.exists(providers_path):
    # The mode is enforced HERE, not only by install.sh: a file created by hand in an editor or restored
    # from a backup is exactly when the credential is world-readable, and an install-time fix does not
    # cover it. Warn-and-tighten rather than refuse - the content is valid and the key is about to be
    # handled anyway, so stopping the review would punish the operator for a permission bit.
    _mode = os.stat(providers_path).st_mode & 0o777
    if _mode & 0o077:
        try:
            os.chmod(providers_path, 0o600)
            sys.stderr.write(
                f"{PROG}: warning: providers.toml was {oct(_mode)}, so its API key was readable by other "
                f"users\n{PROG}: warning: it is now 600; set that mode yourself when you restore the file\n")
        except OSError as _exc:
            refuse(f"providers.toml is mode {oct(_mode)}, readable by other users, and could not be tightened ({_exc})",
                   "it holds the API key, so refusing rather than rendering a credential that stays exposed")
    providers = load(providers_path, "providers.toml")
    for key in sorted(set(providers) - {"providers", "profiles"}):
        refuse(f"providers.toml has unknown top-level key '{key}'; expected 'providers' or 'profiles'")
    provider_table = providers.get("providers") or {}
    if not isinstance(provider_table, dict):
        refuse("providers.toml [providers] is not a table")
    profile_table = providers.get("profiles") or {}
    if not isinstance(profile_table, dict):
        refuse("providers.toml [profiles] is not a table")

# The profiles this file also carries. `settings.toml` names them; their definitions live here.
profiles = profile_table
if not profiles and (main_name or fallback_names):
    # Both files, with the copy command, because the likely state here is having created one and not the
    # other: a message that names only the missing file leaves the operator to guess where it comes from.
    # Same hazard as the missing-settings message: a copy command is a remedy only when the file is
    # absent, and an existing providers.toml here holds the key even though it defines no profiles.
    if os.path.exists(providers_path):
        refuse("settings.toml assigns a model configuration, but providers.toml defines no [profiles.<name>] table",
               "add the [profiles.<name>] tables to it; the example installed beside it shows their shape")
    refuse("settings.toml assigns a model configuration, but providers.toml defines no [profiles.<name>] table",
           "the tables live in providers.toml, which is created from the example installed beside it:",
           f'  cp "{os.path.dirname(providers_path)}/providers.toml.example" "{providers_path}"   # then chmod 600')

# Every profile is validated, assigned or not: a typo caught here is a typo caught before it is relied on.
settings_by_profile = {}
model_by_profile = {}
provider_by_profile = {}
for name, body in sorted(profiles.items()):
    where = f"[profiles.{name}]"
    if not isinstance(body, dict):
        refuse(f"providers.toml {where} is not a table")
    for key in sorted(set(body) - set(PROFILE_KEYS) - set(PROFILE_SECTIONS)):
        if key == "litellm":
            refuse(f"providers.toml {where} sets [profiles.{name}.litellm]",
                   "the transport keys are derived from the provider this profile names, so a streaming",
                   "quirk belongs on that provider in providers.toml (its 'stream' key); a litellm key that",
                   "is specific to this endpoint belongs in [providers.*.litellm], and only one that is the",
                   "same for every endpoint belongs in settings.toml")
        if key == "pr_reviewer":
            refuse(f"providers.toml {where} sets [profiles.{name}.pr_reviewer], but the review knobs are not",
                   "per model: pr-agent applies them to the whole run, so a copy in each profile is the same",
                   "answer written twice and free to drift",
                   "move the table to the top level, as a single [pr_reviewer] section")
        # A profile name is a TOML KEY, and a bare key containing a dot is a table SEPARATOR: the header
        # `[profiles.acme-large-v4.1-flash]` silently defines `profiles.acme-large-v4` with
        # a child table named `1-flash`, so the profile the file meant does not exist at all. The signature
        # is an unknown key whose value is a TABLE - which no real profile key is - because TOML splits at
        # the FIRST dot, leaving a fragment like `1-flash` with no dot of its own to test for.
        if isinstance(body.get(key), dict):
            refuse(f"providers.toml has unknown key '{key}' in {where}",
                   "this is almost certainly a profile name containing a dot, split by TOML: a bare key",
                   f"cannot contain one, so this header defined a profile '{name}' with a sub-table",
                   f"'{key}' instead of the profile '{name}.{key}' the file meant",
                   "quote such a name both where it is DEFINED and where it is ASSIGNED:",
                   f'  [profiles."{name}.{key}"]   and   main = "{name}.{key}"')
        refuse(f"providers.toml has unknown key '{key}' in {where}; expected 'provider', 'model' or a "
               f"[{where[1:-1]}.config] table")
    model = body.get("model")
    if not isinstance(model, str) or not model.strip():
        refuse(f"providers.toml {where} has no 'model'; every profile names the model id its endpoint serves")
    model_by_profile[name] = model.strip()
    provider = body.get("provider")
    if not isinstance(provider, str) or not provider.strip():
        refuse(f"providers.toml {where} has no 'provider'; every profile names the provider - in providers.toml -",
               "that serves it. Which host answers is never inferred from the model id's prefix: a prefix",
               "that disagrees with the pinned transport is resolved silently, to the wrong endpoint")
    provider_by_profile[name] = provider.strip()
    sections = {}
    for section in PROFILE_SECTIONS:
        contents = body.get(section)
        if contents is None:
            continue
        if not isinstance(contents, dict):
            refuse(f"providers.toml [{where[1:-1]}.{section}] is not a table")
        if section == "config" and "model" in contents:
            refuse(f"providers.toml {where}.config sets 'model'; a profile names its model as 'model' in {where} itself",
                   "so that the profile identity has exactly one spelling")
        if section == "config" and "fallback_models" in contents:
            refuse(f"providers.toml {where}.config sets 'fallback_models'; the fallback chain comes from [selection] fallback",
                   "and a second place to name it is a second answer to the same question")
        if section == "config":
            for _dk in DERIVED_CONFIG_KEYS:
                if _dk in contents:
                    refuse(f"providers.toml {where}.config sets '{_dk}', which preflight derives",
                           "it is derived from this profile's reasoning_effort, so a value here would be",
                           "overwritten and silently ignored",
                           "remove it and rely on reasoning_effort instead")
        # Each key is written as the name of a pr-agent setting, so a key that is not a setting name would
        # sit in the rendered file looking configured and be read by nothing.
        for key in sorted(contents):
            if not plain_name(key):
                refuse(f"providers.toml [{where[1:-1]}.{section}] has a key that is not a setting name: {key!r}",
                       "a key reaches pr-agent as a setting name, so it may contain only letters, digits and",
                       "underscores, and may not start with a digit")
        sections[section] = contents
    settings_by_profile[name] = sections

for name in ([main_name] if main_name else []) + fallback_names:
    if name not in profiles:
        defined = ", ".join(sorted(profiles)) if profiles else "none"
        slot = "main" if name == main_name else "fallback"
        refuse(f"settings.toml [{SELECTION_SECTION}] {slot} names '{name}', which no [profiles.{name}] table defines (defined: {defined})")

# pr-agent holds ONE config per process: get_max_tokens() and the output-cap resolver read the settings
# and ignore which model is asking (both were checked against the installed pr-agent). So the assigned
# profile's settings govern the whole run - including when a fallback answers - and taking them from every
# assigned profile would make the review depend on the order of a fallback list.
#
# A fallback profile MAY carry settings: they describe that model, and they apply the moment it is
# assigned as `main`. What they cannot do is apply while it is a fallback, and dropping that silently is
# the failure this bundle exists to prevent - so it is reported, not refused. Refusing would also block
# the ordinary case of keeping a profile fully described for later use, which the resolver allows while
# that profile is unassigned; an inconsistent rule is its own bug.
# `main_name` alone: a fallback-only file is refused below, and refusing it AFTER this loop would print a
# warning naming `[profiles.]` and claiming the run uses its values. So the loop only speaks for a file that
# has a main model to attribute to; a fallback never stands in as the supplier, because that would attribute
# the run's budgets to a backup.
supplier = main_name
for name in [n for n in fallback_names if supplier and n != supplier]:
    declared = sorted(
        key for section, contents in settings_by_profile.get(name, {}).items() for key in contents
    )
    if declared:
        print(
            f"{PROG}: warning: [profiles.{name}] sets {', '.join(declared)}, but pr-agent holds one "
            f"config per run\n"
            f"{PROG}: warning: so this run uses [profiles.{supplier}]'s values for every model, "
            f"including when '{name}' answers the\n"
            f"{PROG}: warning: fallback. Assign '{name}' as [selection] main to review with its own "
            f"settings.",
            file=sys.stderr,
        )

# The endpoint is a property of the RUN, not of one model: pr-agent holds one pinned transport and one
# section of credentials per process. A chain that spans two providers therefore cannot be served - the
# other model would be answered by the pinned provider's host and key, silently - so it is refused here,
# by name, rather than half-served.
assigned = ([main_name] if main_name else []) + fallback_names
assigned_providers = sorted({provider_by_profile[n] for n in assigned})
if len(assigned_providers) > 1:
    refuse(f"settings.toml assigns {len(assigned_providers)} providers ({', '.join(assigned_providers)}),",
           "but pr-agent holds ONE endpoint per run, so the fallback chain would be answered by whichever",
           "provider is pinned - a different host, with that provider's key",
           "assign configurations from one provider, and use the other by changing [selection] main")
chosen_provider = assigned_providers[0] if assigned_providers else ""

provider_entry = {}
for name, body in sorted(provider_table.items()):
    where = f"[providers.{name}]"
    if not isinstance(body, dict):
        refuse(f"providers.toml {where} is not a table")
    for key in sorted(set(body) - set(PROVIDER_KEYS)):
        refuse(f"providers.toml has unknown key '{key}' in {where}; expected one of {list(PROVIDER_KEYS)}")
    transport = body.get("transport", "openai")
    if not isinstance(transport, str) or transport.strip() not in TRANSPORTS:
        refuse(f"providers.toml {where} names transport {transport!r}, which is not one pr-agent can route",
               f"known transports: {', '.join(sorted(TRANSPORTS))}")
    transport = transport.strip()
    section, key_name, reads_endpoint = TRANSPORTS[transport]
    api_base = body.get("api_base", "")
    if not isinstance(api_base, str):
        refuse(f"providers.toml {where} 'api_base' must be a URL in quotes")
    api_base = api_base.strip()
    if api_base and not reads_endpoint:
        refuse(f"providers.toml {where} sets api_base, but pr-agent reads no endpoint for transport '{transport}'",
               f"it reads only {section}.{key_name} from a config file, and takes its endpoint from an",
               "environment variable or from the provider's own default - so this value would be ignored",
               f"name a transport that reads an endpoint ({ENDPOINT_TRANSPORTS}), or set that provider's",
               "api-base variable in the environment that runs preflight")
    if not api_base and reads_endpoint:
        refuse(f"providers.toml {where} has no 'api_base', and transport '{transport}' reads its endpoint from config",
               "without it pr-agent would use its own default host while taking this provider's key - a request",
               "to one host with another's credential, so state the endpoint")
    credential = body.get("key", "")
    if not isinstance(credential, str):
        refuse(f"providers.toml {where} 'key' must be a string")
    if not credential.strip():
        refuse(f"providers.toml {where} has no 'key'",
               "every provider states its credential - nothing else supplies one, and an endpoint that",
               "ignores the key still takes a non-empty string")
    # Stripped on the way in: a key pasted with a trailing space or newline is written verbatim, sent
    # verbatim, and refused by the endpoint as a bad credential - an authentication failure that the key
    # itself does not explain. Surrounding whitespace is never part of a credential.
    credential = credential.strip()
    stream = body.get("stream", False)
    if not isinstance(stream, bool):
        refuse(f"providers.toml {where} 'stream' must be true or false")
    if stream and not api_base:
        refuse(f"providers.toml {where} sets stream, but its endpoint is not in this file",
               "the streaming workaround is scoped to this provider's own api_base, so an endpoint this file",
               "cannot see is one the workaround cannot be scoped to")
    litellm_table = body.get("litellm") or {}
    if not isinstance(litellm_table, dict):
        refuse(f"providers.toml [{where[1:-1]}.litellm] is not a table")
    for key in sorted(litellm_table):
        if key in DERIVED_LITELLM_KEYS:
            refuse(f"providers.toml {where}.litellm sets '{key}', which preflight derives",
                   "the transport comes from this provider's 'transport', and the streaming pair from its",
                   "'stream' key - writing them here would be a second answer, free to disagree with the",
                   "endpoint, which LiteLLM resolves silently to the wrong host")
        if key not in PROVIDER_LITELLM_KEYS:
            refuse(f"providers.toml {where}.litellm has an unknown key '{key}'",
                   f"a provider may set: {', '.join(PROVIDER_LITELLM_KEYS)}",
                   "a [litellm] key that is the same for every provider belongs in settings.toml instead")
        if not plain_name(key):
            refuse(f"providers.toml {where}.litellm has a key that is not a setting name: {key!r}")
    provider_entry[name] = {
        "transport": transport, "section": section, "key_name": key_name,
        "api_base": api_base, "key": credential, "stream": stream,
        "litellm": litellm_table,
    }

if chosen_provider and chosen_provider not in provider_entry:
    defined = ", ".join(sorted(provider_entry)) if provider_entry else "none"
    refuse(f"settings.toml names provider '{chosen_provider}', which no [providers.{chosen_provider}] table defines (defined: {defined})",
           "an unresolved provider is not a missing default: pr-agent would fall back to another section's",
           "host and key, so this is refused rather than guessed")

# A valid file that assigns nothing means there is no model, and with preflight.toml gone there is no
# second config to fall back to - so it is a refusal that names the section to fill in, not a no-op.
#
# `main` specifically, not "any assignment": a fallback list alone is NOT a model choice. Treating its
# first entry as the primary would review on a profile the user intended only as a backup, and the summary
# line would not say a fallback answered - the silent-wrong-model failure this resolver exists to prevent.
if not main_name:
    _why = ("[%s] main is empty" % SELECTION_SECTION) if fallback_names else \
           ("[%s] main was not set" % SELECTION_SECTION)
    refuse("settings.toml assigns no model profile",
           f"{_why}, so there is nothing to review with" +
           (" - a fallback chain is not a main model" if fallback_names else ""),
           f"set [{SELECTION_SECTION}] main to the name of a [profiles.<name>] table in providers.toml")

# ------------------------------------------------------------------ render
#
# settings.toml IS the config, minus what a run decides: the model (from the assignment), its endpoint and
# credential (from the provider), and the three litellm keys derived from that provider. So the render
# starts from a copy of settings.toml with the preflight-only [selection] table removed and layers those
# on. Nothing else is rewritten: a section preflight does not understand is pr-agent's business, and
# passing it through is what makes this file the config rather than a subset of one.
# A deep copy that does not go through JSON: `tomllib` returns `datetime.date`/`time`/`datetime` for TOML
# date values, which `json.dumps` raises `TypeError` on - a traceback where a refusal (or a pass-through)
# belongs. `copy.deepcopy` handles every type the parser can produce.
rendered = copy.deepcopy(data)
rendered.pop(SELECTION_SECTION, None)
# The gate's policy is preflight's, not pr-agent's: leaving it in would be a section pr-agent reads nothing
# from, which is the "looks configured, does nothing" shape refused everywhere else in this file.
rendered.pop(GATE_SECTION, None)

config = rendered.setdefault("config", {})
if not isinstance(config, dict):
    refuse("settings.toml [config] is not a table")

primary = main_name
config["model"] = model_by_profile[primary]
# The chain is deduped by RESOLVED MODEL ID, not by profile name: two profiles may name the same model, and
# a repeated name inside `fallback` is the same id twice. Either would make pr-agent retry the model that
# just failed. Written even when empty: the assignment IS the chain, so a [config] value cannot leak into a
# run that named its own.
_chain = []
for _name in fallback_names:
    _id = model_by_profile[_name]
    if _id != model_by_profile[primary] and _id not in _chain:
        _chain.append(_id)
config["fallback_models"] = _chain

# The assigned profile's own settings - its token budgets and model knobs - follow the model that is
# actually being asked, which is the reason profiles carry them. They land in pr-agent's [config], which
# has no `selection` siblings, so `config` here means the same section pr-agent reads.
#
# A key the profile sets AND settings.toml sets is REFUSED rather than overwritten: the settings.toml
# value would be dead, and a setting that reads as configured while nothing applies it is the failure this
# whole file exists to prevent. One place per key - the profile's, because it is the model's property.
for section in PROFILE_SECTIONS:
    profile_settings = settings_by_profile.get(supplier, {}).get(section, {})
    for key in sorted(profile_settings):
        if key in rendered.get(section, {}):
            where = f"[{SELECTION_SECTION}] main names a profile that sets it" if section == "config" else ""
            refuse(f"'{key}' is set in both settings.toml [{section}] and [profiles.{supplier}.{section}]",
                   "the profile's value would overwrite settings.toml's, leaving that one looking set and",
                   "doing nothing",
                   f"keep it in [profiles.{supplier}.{section}] - it describes the model - and remove it",
                   f"from settings.toml [{section}]" + (f"; {where}" if where else ""))
    # DERIVED_CONFIG_KEYS are refused here too: a profile that sets one would have it copied into
    # the rendered [config] and then silently replaced by the derivation block below. Only the primary
    # profile's settings are merged here (supplier == main_name), so a fallback profile's setting
    # would never be copied - but refusing it keeps the claim "refused in every position" honest.
    if section == "config":
        for _dk in DERIVED_CONFIG_KEYS:
            if _dk in profile_settings:
                refuse(f"settings.toml [profiles.{supplier}.config] sets '{_dk}', which preflight derives",
                       "it is derived from this profile's reasoning_effort, so a value here would be",
                       "overwritten and silently ignored",
                       "remove it and rely on reasoning_effort instead")
    for key, value in profile_settings.items():
        target = rendered.setdefault(section, {})
        if not isinstance(target, dict):
            refuse(f"settings.toml [{section}] is not a table")
        target[key] = value

# Derive additional_reasoning_effort_models from the configured reasoning_effort: pr-agent
# forwards config.reasoning_effort to the provider ONLY for models it considers reasoning-capable
# (litellm metadata or this list), so a configured effort on a model litellm does not know is
# otherwise silently dropped. Registering the assigned model here makes the lever reach the provider.
# Only the primary profile's reasoning_effort can trigger this: pr-agent holds one config per process,
# so only the primary profile's settings are merged into the rendered [config] (fallback profiles'
# settings are reported but never applied while they are fallbacks). A fallback profile that sets
# reasoning_effort therefore cannot make it reach the provider while it is a fallback - consistent with
# every other profile knob, and it applies the moment that profile is assigned as `main`.
# Derived, not configured: a value written anywhere is refused by name above, and the render's value wins.
_rendered_cfg = rendered.setdefault("config", {})
if isinstance(_rendered_cfg, dict) and _rendered_cfg.get("reasoning_effort") not in (None, ""):
    _existing = _rendered_cfg.get("additional_reasoning_effort_models")
    if not isinstance(_existing, list):
        _existing = []
    # Register every model that can actually answer this run: the primary AND any fallback named in
    # [selection] fallback. pr-agent retries the fallback models on a primary failure, and those calls
    # use the same rendered [config] (one config per process), so a fallback that litellm does not
    # consider reasoning-capable would otherwise drop the configured effort on the fallback call.
    # Only the primary profile's reasoning_effort can trigger this (fallback profiles' settings are
    # never merged), but the registration covers all models the run may use.
    for _name in ([primary] + fallback_names):
        _mid = model_by_profile.get(_name)
        if isinstance(_mid, str) and _mid.strip() and _mid not in _existing:
            _existing = list(_existing) + [_mid.strip()]
    _rendered_cfg["additional_reasoning_effort_models"] = _existing

entry = provider_entry[chosen_provider]
transport = entry["transport"]
litellm = rendered.setdefault("litellm", {})
if not isinstance(litellm, dict):
    refuse("settings.toml [litellm] is not a table")
# The three derived keys are refused here for the same reason they are refused inside a provider's
# [litellm]: a value written here is overwritten below, so it would read as configured and do nothing -
# and a pin that disagreed with the endpoint is resolved by LiteLLM silently, to the wrong host.
for _key in DERIVED_LITELLM_KEYS:
    if _key in litellm:
        refuse(f"settings.toml [litellm] sets '{_key}', which preflight derives from the provider",
               "the transport comes from the provider's 'transport', and the streaming pair from its",
               "'stream' key, so a value here would be overwritten and silently ignored",
               "remove it from settings.toml [litellm]")
# The pin, and the reason a model id needs no provider prefix: with it set, pr-agent routes every model
# to this transport and LiteLLM strips a matching prefix, so the id reaches the endpoint as the endpoint's
# own name. It is written from the provider entry, so it cannot disagree with the endpoint below - the
# disagreement LiteLLM resolves silently, to the wrong host.
litellm["custom_llm_provider"] = transport
if entry["stream"]:
    # Scoped to this provider's own host. The gate also requires the force-streaming provider to equal the
    # pin, so this cannot leak onto a transport the pin does not name.
    # The HOST, not the authority: an api_base may carry userinfo (`https://user@host/v1`) or a port, and
    # the gate compares this substring against the request URL - `user@host` appears in no request, so the
    # workaround would silently never fire. Strip the userinfo and keep host[:port], which does appear.
    authority = entry["api_base"].split("//", 1)[-1].split("/", 1)[0]
    host = authority.rsplit("@", 1)[-1]
    litellm["force_streaming_custom_llm_provider"] = transport
    litellm["force_streaming_api_base_substrings"] = [host]
else:
    # Empty rather than absent: an empty provider name cannot equal the pin (the gate requires a non-empty
    # match) and an empty substring list cannot match anything, so a provider that does not stream cannot
    # inherit the workaround for a host it does not use.
    litellm["force_streaming_custom_llm_provider"] = ""
    litellm["force_streaming_api_base_substrings"] = []

# This provider's own [litellm] settings, applied AFTER the derived three, which are refused above and so
# cannot be shadowed from here.
#
# A key set in BOTH settings.toml [litellm] and this provider's table is REFUSED, for the same reason as a
# duplicate in [config]: the provider's value would win silently, leaving the settings.toml one looking
# configured and doing nothing. Which one is right is a judgement only the author can make, so the message
# says what the choice is rather than picking.
for key in sorted(entry["litellm"]):
    if key in litellm:
        refuse(f"'{key}' is set in both settings.toml [litellm] and [providers.{chosen_provider}.litellm]",
               "the provider's value would overwrite settings.toml's, leaving that one looking set and",
               "doing nothing",
               "keep it on the provider if it describes THIS endpoint, or in settings.toml [litellm] if it",
               "is the same for every endpoint - but only one of them")
for key, value in entry["litellm"].items():
    litellm[key] = value

endpoint_table = rendered.setdefault(entry["section"], {})
if not isinstance(endpoint_table, dict):
    refuse(f"settings.toml [{entry['section']}] is not a table")
# The provider supplies this section's endpoint and credential. A user-written copy in settings.toml would
# be overwritten below without a word - the same silent-collision failure refused everywhere else here.
# EVERY spelling, not only this transport's: a stale value under another name would be copied into the
# rendered file unrefused (or overwritten silently, which is the collision refused everywhere else here).
for _key in sorted(_CREDENTIAL_KEYS | {"api_base"}):
    if _key in endpoint_table:
        refuse(f"settings.toml [{entry['section']}] sets '{_key}', which the provider supplies",
               f"the endpoint and credential come from [providers.{chosen_provider}] in providers.toml",
               f"remove '{_key}' from settings.toml [{entry['section']}], so the provider's value is the",
               "only one")
# EVERY endpoint-shaped section is checked, not just the one being written: a `key` left under another
# provider's section (a migration remnant, say) would be copied into the rendered file verbatim, so the
# credential would be sent - and would sit in a settings.toml nothing mode-checks. That is the
# "refused in any shadowed position" SECURITY.md promises.
for _name in sorted(_ENDPOINT_SECTIONS):
    _tbl = rendered.get(_name)
    if not isinstance(_tbl, dict):
        continue
    for _key in sorted(_CREDENTIAL_KEYS | {"api_base"}):
        if _key in _tbl and _name != entry["section"]:
            refuse(f"settings.toml [{_name}] sets '{_key}', which belongs in providers.toml",
                   "every endpoint and credential is a property of a [providers.*] entry - a second copy",
                   "in settings.toml is one that reaches pr-agent and is never mode-checked",
                   f"remove settings.toml [{_name}] and put it in providers.toml")
if entry["api_base"]:
    endpoint_table["api_base"] = entry["api_base"]
endpoint_table[entry["key_name"]] = entry["key"]

lines = ["# Generated by preflight from settings.toml and providers.toml. Do not edit: it is rewritten before",
         f"# every run. Edit those two files instead. Generated {__import__('time').strftime('%Y-%m-%dT%H:%M:%SZ', __import__('time').gmtime())}.", ""]
emit(rendered, [], lines)
while lines and lines[-1] == "":
    lines.pop()

try:
    with open(out_path, "w") as handle:
        handle.write("\n".join(lines) + "\n")
except OSError as exc:
    refuse(f"could not write the rendered configuration ({exc})")
if os.path.getsize(out_path) == 0:
    refuse("the rendered configuration came out empty, so it is not passed on as a configuration at all")

shown = []
if main_name:
    shown.append(f"main={main_name}")
if fallback_names:
    shown.append("fallback=" + ",".join(fallback_names))
shown.append(f"provider={chosen_provider}")
sections = len([k for k in rendered if isinstance(rendered[k], dict) and rendered[k]])
tail = f" ({sections} sections)" if sections else ""
print(f"{PROG}: settings: {' '.join(shown)}{tail}", file=sys.stderr)
PY
  then
    # The `if` around the invocation is what keeps this cleanup reachable: the helpers run under
    # `set -e`, so a bare non-zero `python3` would abort the shell THERE, before the `rm`, and
    # this run's rendered file would keep whatever the failed render had already written.
    rm -f "$out"
    return 2
  fi

  # A render that produced no bytes must never be handed on as a configuration: pr-agent would read an
  # empty file, silently changing nothing. Checked here as well as inside the parser, because this is the
  # last point before the path is used.
  if [ ! -s "$out" ]; then
    printf '%s: the rendered model configuration is empty; refusing to review with it\n' "$__preflight_caller_name" >&2
    rm -f "$out"
    return 2
  fi
  # The name must end in `.toml`, because pr-agent's settings loader SKIPS every other extension without
  # failing - so a wrongly-named file is a config that is passed on and then ignored, which is the silent
  # wrong-endpoint failure this resolver exists to prevent. Asserted rather than assumed, because it is a
  # property of pr-agent, not of this script.
  case "$out" in
    *.toml) ;;
    *)
      printf '%s: the rendered configuration is named %s, which pr-agent will not load (it skips non-.toml files)\n' "$__preflight_caller_name" "$out" >&2
      rm -f "$out"
      return 2
      ;;
  esac
  # A COPY at the fixed name, left behind for inspection. It is NOT what pr-agent reads - that is the
  # per-run path, so two runs never share a file - and it is not load-bearing for anything. Written
  # atomically (temp + rename inside the same dir), so a reader never sees a half-written config, and
  # 600-mode like the source. A failure here is reported but not fatal: the run's own config is already
  # complete, and refusing a valid run over a convenience copy would be the wrong trade.
  _latest="$cfgdir/.pragent.settings.toml"
  _tmp_latest="$cfgdir/.pragent.settings.part.$$.toml"
  if ( umask 077; cp "$out" "$_tmp_latest" && mv -f "$_tmp_latest" "$_latest" ) 2>/dev/null; then
    chmod 600 "$_latest" 2>/dev/null || true
  else
    rm -f "$_tmp_latest" 2>/dev/null
    printf '%s: could not update %s (the run uses %s)\n' "$__preflight_caller_name" "$_latest" "$out" >&2
  fi
  PREFLIGHT_RENDERED_CONFIG="$out"
  return 0
}
