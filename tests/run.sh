#!/usr/bin/env bash
# Integration tests for the preflight commit hook.
#
#   tests/run.sh              # run everything (a few minutes)
#   tests/run.sh hook         # only the hook cases
#   tests/run.sh e2e          # only the live-endpoint cases
#   tests/run.sh selfcheck    # only the selfcheck: the suite re-run against a neutered hook
#
# They exercise the REAL hook files from src/, against real git repositories, with no network and no
# API key. That matters: everything here was written to catch a specific regression that a unit test
# of the comparison logic would have missed, because the bugs lived in how git reports a staged change
# (a rename is not "A" or "M", a gitlink is not a blob, a scratch file shows up as a deletion).
#
# A small scratch index per case replaces a real `preflight-code review`: the tests write the sidecar that
# a worktree-scope review would have written, using the same scratch-index method preflight-code itself
# uses. That keeps the suite offline and deterministic, and keeps the tested logic the real thing.
#
# Traceability: every case declares the requirement it guards - `[REQ-HOOK-nn]` for a hook case,
# `[REQ-SELF-nn]` for the selfcheck itself - and the mapping is listed in tests/README.md. A case that
# fails names its requirement in the output.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
hook="${PREFLIGHT_TEST_HOOK:-$repo_root/src/preflight-hook}"

which_cases="${1:-all}"
pass=0; fail=0; skipped=0

# Reject an unrecognized group rather than running nothing and reporting success. A typo in a CI step
# (`./tests/run.sh hok`) would otherwise exit 0 with "0 passed" and look green.
case "$which_cases" in
  all|hook|e2e|selfcheck) ;;
  *) echo "tests: unknown case group '$which_cases' (expected one of: all, hook, e2e, selfcheck)" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "tests: at most one case group is accepted" >&2; exit 2; }

if [ ! -r "$hook" ]; then echo "tests: cannot read $hook" >&2; exit 2; fi
command -v git >/dev/null 2>&1 || { echo "tests: git is required" >&2; exit 2; }

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# settings.toml is the ONLY config source now (there is no preflight.toml to fall back to), so a case that
# points PREFLIGHT_HOME at a bare directory would stop at "settings.toml was not found" rather than
# exercising what it means to. Seed every config dir the suite uses with a working pair, once, here - a
# case that wants a different pair writes over these.
#
# The provider and profile are named "main" and the model is deliberately one no endpoint serves: these
# cases drive a stubbed `pr-agent`, so nothing calls out, and the values never matter beyond resolving.
seed_cfg() {
  local cfg="$1"
  mkdir -p "$cfg"
  printf '[selection]\nmain = "main"\n\n[config]\nmax_output_tokens = 384000\ncustom_model_max_tokens = 1000000\nmax_model_tokens = 616000\n\n[pr_reviewer]\nreview_heading = "Preflight - PR Reviewer Guide"\nnum_max_findings = 10\n' > "$cfg/settings.toml"
  printf '[providers.main]\napi_base = "https://example.invalid/v1"\nkey = "test-key"\n\n[profiles.main]\nprovider = "main"\nmodel = "test-model"\n' > "$cfg/providers.toml"
  # 600-mode, like a configured install: `printf` inherits the suite's umask (typically 0644), and every
  # render would then take the loose-mode path - chmod-ing the fixture and adding its warning to each run's
  # stderr. The warning has its own case; the default path must be the clean one.
  chmod 600 "$cfg/providers.toml"
  cp "$repo_root/scripts/settings-render.sh" "$cfg/settings-render.sh"
}
for _d in ctx fallback history partial-scope scope shutdown untracked verdict wiring; do
  seed_cfg "$work/${_d}-cfg"
done
unset _d

# The fixtures make real commits, so they need an identity. Set it in the environment rather than
# relying on the machine's git config: a CI runner has none by default, and the suite must not depend
# on how the machine is set up. This also keeps the tests from touching the user's config.
GIT_AUTHOR_NAME="preflight tests"
GIT_AUTHOR_EMAIL="preflight-tests@localhost"
GIT_COMMITTER_NAME="preflight tests"
GIT_COMMITTER_EMAIL="preflight-tests@localhost"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
# A developer's global hooksPath or gpgsign must not leak into the fixtures either.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

# ---------------------------------------------------------------------------- helpers

say()  { printf '%s\n' "$*"; }

# Colour only when writing to a terminal, so CI logs stay plain text.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  c_pass='\033[32m'; c_fail='\033[31m'; c_skip='\033[33m'; c_off='\033[0m'
else
  c_pass=''; c_fail=''; c_skip=''; c_off=''
fi

# Machine-readable per-case results, for the selfcheck. Off unless PREFLIGHT_TEST_RESULTS names a
# file; the human output below is unchanged either way.
record() {
  [ -n "${PREFLIGHT_TEST_RESULTS:-}" ] || return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$PREFLIGHT_TEST_RESULTS"
}

ok()   { printf '  %sPASS%s  %s  [%s]\n' "$c_pass" "$c_off" "$1" "$2"; pass=$((pass+1)); record PASS "$2" "$1"; }
bad()  { printf '  %sFAIL%s  %s  [%s]\n        expected exit %s, got %s\n%s' \
           "$c_fail" "$c_off" "$1" "$2" "$3" "$4" "${5:-}"; fail=$((fail+1)); record FAIL "$2" "$1"; }
# `skip NAME REQ REASON`. The REQ id is required so the selfcheck can tell that an enforcement case was
# skipped - a guard that did not run proves nothing, which is the same reasoning that makes
# `expect_commit` refuse a case that staged nothing.
skip() { printf '  %sSKIP%s  %s  (%s)\n' "$c_skip" "$c_off" "$1" "$3"; skipped=$((skipped+1)); record SKIP "$2" "$1"; }

# A fresh repository with the sample project committed and the hook enabled.
new_repo() {
  local d="$work/$1"
  mkdir -p "$d/.githooks"
  cp -R "$here/sample/." "$d/"
  printf '#!/bin/sh\nexec sh %s\n' "$hook" > "$d/.githooks/pre-commit"
  chmod +x "$d/.githooks/pre-commit"
  # The hooks are COMMITTED, so the repository starts clean. If they were left untracked, git would
  # refuse a commit that stages nothing ("nothing added to commit but untracked files present"), and
  # a case expecting the hook to block would pass for that reason instead of the hook's.
  ( cd "$d" && git init -q -b main . \
      && git -c commit.gpgsign=false add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m "chore: sample" \
      && git config core.hooksPath .githooks ) >/dev/null 2>&1
  echo "$d"
}

# Record the tree a worktree-scope review would have handed to pr-agent, and write the sidecar.
# The scratch index lives outside the repo so it can never appear in the snapshot.
review_here() {
  local d="$1" idx tr
  idx="$(mktemp)"; rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$d" read-tree HEAD
  GIT_INDEX_FILE="$idx" git -C "$d" add -A
  tr="$(GIT_INDEX_FILE="$idx" git -C "$d" write-tree)"
  rm -f "$idx"
  mkdir -p "$d/.preflight"
  python3 - "$d/.preflight/review.meta.json" "$tr" <<'PY'
import json, sys
json.dump({
    "scope": "worktree", "dir": ".preflight", "head": "test",
    "reviewed_tree": sys.argv[2], "generated_at": "test",
    "gate": {"verdict": "pass", "exit": 0},
}, open(sys.argv[1], "w"), indent=2)
PY
}

# Run a commit and report. `expect_commit NAME REQ EXPECTED_EXIT`
expect_commit() {
  local name="$1" req="$2" want="$3" d="$4" staged out got
  staged="$(git -C "$d" diff --cached --name-only)"
  # A case that expects a block is only meaningful if there is something staged. If nothing is
  # staged, git refuses the commit on its own ("nothing to commit, working tree clean") and its
  # non-zero exit is indistinguishable from the hook blocking - the case then passes for the wrong
  # reason. That is exactly how a removed verdict check once slipped through this suite.
  if [ -z "$staged" ]; then
    bad "$name" "$req" "$want" "nothing staged" \
        "        | the test staged nothing, so git refused on its own and the hook never decided\n"
    return
  fi
  out="$(git -C "$d" -c commit.gpgsign=false commit -m "test: $name" 2>&1)"; got=$?
  if [ "$got" = "$want" ]; then ok "$name" "$req"
  else bad "$name" "$req" "$want" "$got" "$(printf '%s\n' "$out" | sed 's/^/        | /')"; fi
}

# `reset_case REPO` returns the repo to its committed state for the next case.
reset_case() { git -C "$1" reset -q --hard HEAD; rm -rf "$1/.preflight"; }

# ---------------------------------------------------------------------------- cases
# Each case: set up a change, declare what the review covered, then try to commit.

case_block_edit_after_review() {
  local d; d="$(new_repo edit)"
  reset_case "$d"
  review_here "$d"
  printf '\n# edited after the review\n' >> "$d/util.py"
  git -C "$d" add util.py
  expect_commit "edit after review is blocked" "REQ-HOOK-01" 1 "$d"
}

case_block_new_file() {
  local d; d="$(new_repo newfile)"
  reset_case "$d"
  review_here "$d"
  printf 'x = 1\n' > "$d/extra.py"
  git -C "$d" add extra.py
  expect_commit "new unreviewed file is blocked" "REQ-HOOK-02" 1 "$d"
}

case_block_git_rm() {
  local d; d="$(new_repo rm)"
  reset_case "$d"
  review_here "$d"
  git -C "$d" rm -q auth.py
  expect_commit "git rm of a reviewed file is blocked" "REQ-HOOK-03" 1 "$d"
}

case_block_cached_remove() {
  # `git rm --cached` leaves the file on disk, so it is only visible as a deletion. A previous
  # implementation special-cased "path contains a slash and still exists" for submodules, and that
  # let this case through - the file was skipped instead of reported.
  local d; d="$(new_repo cached)"
  reset_case "$d"
  mkdir -p "$d/src"; printf 'guard = True\n' > "$d/src/guard.py"
  git -C "$d" add -A; git -C "$d" -c commit.gpgsign=false commit -q --no-verify -m "chore: guard"
  reset_case "$d"
  review_here "$d"
  git -C "$d" rm -q --cached src/guard.py
  [ -f "$d/src/guard.py" ] || { skip "git rm --cached of a nested reviewed file is blocked" "REQ-HOOK-04" "fixture"; return; }
  expect_commit "git rm --cached of a nested reviewed file is blocked" "REQ-HOOK-04" 1 "$d"
}

case_block_rename() {
  # With rename detection on this is status R - neither A nor M - so an AM-only filter saw NO change
  # at all and let a guard be renamed out of existence.
  local d; d="$(new_repo rename)"
  reset_case "$d"
  review_here "$d"
  git -C "$d" mv auth.py auth_disabled.py
  expect_commit "renaming a reviewed file away is blocked" "REQ-HOOK-05" 1 "$d"
}

case_block_typechange() {
  # Status T. Contents can be identical while the meaning changes completely.
  local d; d="$(new_repo typechange)"
  reset_case "$d"
  review_here "$d"
  rm -f "$d/util.py"; ln -s /etc/passwd "$d/util.py"
  git -C "$d" add util.py
  expect_commit "swapping a reviewed file for a symlink is blocked" "REQ-HOOK-06" 1 "$d"
}

case_block_quoted_name_deletion() {
  # `--name-only` without `-z` QUOTES any path that needs it (double-quoted, backslash-escaped),
  # and core.quotePath cannot disable that for the characters that matter. The hook once fed those
  # quoted names back into `git cat-file -e "HEAD:$p"`, which then asked about a path that does not
  # exist - so a reviewed tracked file with a quoting-needing name was mistaken for an untracked
  # scratch file and its deletion committed unreviewed.
  local d; d="$(new_repo quoted)"
  printf 'guard = True\n' > "$d/quote\"d.py"
  printf 'guard = True\n' > "$d/back\\slash.py"
  ( cd "$d" && git add -A && git -c commit.gpgsign=false commit -q --no-verify -m "chore: quoted" ) >/dev/null 2>&1
  reset_case "$d"
  review_here "$d"
  git -C "$d" rm -q 'quote"d.py' 'back\slash.py'
  expect_commit "deleting a reviewed file with a quoted name is blocked" "REQ-HOOK-24" 1 "$d"
}

case_block_gitlink_removal() {
  # A submodule (gitlink) is not a blob, so `git cat-file -e "HEAD:path"` FAILS for it. An earlier
  # per-path discriminator therefore classified a removed gitlink as "not tracked at HEAD" and let the
  # removal through unreviewed. HEAD is now read with `ls-tree`, which lists gitlinks like any other
  # entry. Only the gitlink itself is removed here, so `.gitmodules` cannot block for an unrelated
  # reason.
  local d; d="$(new_repo gitlink)"
  local sub="$work/submodule-src"
  mkdir -p "$sub"
  ( cd "$sub" && git init -q -b main . && printf 'y = 1\n' > s.py \
      && git add -A && git -c commit.gpgsign=false commit -q --no-verify -m "chore: sub" ) >/dev/null 2>&1
  if ! git -C "$d" -c protocol.file.allow=always submodule add -q "$sub" sub >/dev/null 2>&1; then
    skip "removing a gitlink without reviewing it is blocked" "REQ-HOOK-25" "submodule fixture unavailable"
    reset_case "$d"; return
  fi
  ( cd "$d" && git add -A && git -c commit.gpgsign=false commit -q --no-verify -m "chore: sub" ) >/dev/null 2>&1
  reset_case "$d"
  review_here "$d"
  git -C "$d" update-index --force-remove sub
  expect_commit "removing a gitlink without reviewing it is blocked" "REQ-HOOK-25" 1 "$d"
}

case_missing_helper_fails_closed_unset_home() {
  # The example hook points at ${PREFLIGHT_HOOK:-${HOME:-}/.config/preflight/preflight-hook}. With
  # `set -u` and an unset HOME, a bare $HOME aborts the shell with "HOME: unbound variable" - the
  # commit was still refused, but by a shell error rather than the documented message. HOME unset is
  # the deterministic case here: it makes the helper path absent regardless of what is installed on
  # the machine running the suite, so this does not depend on the developer's setup.
  local d; d="$(new_repo unset_home)"
  reset_case "$d"
  # AFTER reset_case: `git reset --hard` restores the committed .githooks/pre-commit, which would
  # otherwise overwrite the example hook this case needs to test.
  install -m 0755 "$repo_root/src/githooks/pre-commit" "$d/.githooks/pre-commit"
  printf '\n# unreviewed\n' >> "$d/util.py"
  git -C "$d" add util.py
  local out got
  out="$(env -u HOME -u PREFLIGHT_HOOK git -C "$d" -c commit.gpgsign=false commit -m x 2>&1)"; got=$?
  if [ "$got" = 1 ] && printf '%s' "$out" | grep -q 'helper is missing' \
     && ! printf '%s' "$out" | grep -q 'unbound variable'; then
    ok "the example hook reports a missing helper when HOME is unset" "REQ-HOOK-26"
  else
    bad "the example hook reports a missing helper when HOME is unset" "REQ-HOOK-26" \
        "1 + 'helper is missing'" "$got" "$(printf '%s\n' "$out" | sed 's/^/        | /')"
  fi
}

case_pass_commit_a_with_scratch() {
  # The case that rules out strict tree equality: `commit -a` stages tracked changes but not
  # untracked files, while the reviewed snapshot includes them.
  local d; d="$(new_repo commit_a)"
  reset_case "$d"
  printf '\n# reviewed change\n' >> "$d/util.py"
  printf 'scratch\n' > "$d/scratch.tmp"          # untracked, included in the review
  review_here "$d"
  git -C "$d" add util.py                         # stage only tracked, as `commit -a` would
  expect_commit "commit -a with an untracked scratch file passes" "REQ-HOOK-07" 0 "$d"
}

case_pass_reviewed_deletion() {
  local d; d="$(new_repo del)"
  reset_case "$d"
  git -C "$d" rm -q util.py
  review_here "$d"                                 # the removal IS part of the review
  expect_commit "a reviewed deletion passes" "REQ-HOOK-08" 0 "$d"
}

case_pass_reviewed_rename() {
  local d; d="$(new_repo rn)"
  reset_case "$d"
  git -C "$d" mv util.py helper.py
  review_here "$d"
  expect_commit "a reviewed rename passes" "REQ-HOOK-09" 0 "$d"
}

case_pass_no_changes() {
  local d; d="$(new_repo noop)"
  reset_case "$d"
  review_here "$d"
  # --allow-empty because git refuses an empty commit on its own; the point is that the hook has
  # nothing to object to when the staged tree matches the reviewed one.
  local got
  git -C "$d" -c commit.gpgsign=false commit --allow-empty -m "empty" >/dev/null 2>&1; got=$?
  if [ "$got" = 0 ]; then ok "an empty commit after a clean review passes" "REQ-HOOK-10"
  else bad "an empty commit after a clean review passes" "REQ-HOOK-10" 0 "$got" ""; fi
}

case_block_no_review() {
  local d; d="$(new_repo norev)"
  reset_case "$d"
  printf '\n# change\n' >> "$d/util.py"
  git -C "$d" add util.py
  expect_commit "no review at all is blocked" "REQ-HOOK-11" 1 "$d"
}

case_block_failed_verdict() {
  # The content must MATCH the reviewed tree here, so containment has nothing to object to and the
  # verdict is the only thing that can block. (Stage the change first, review, then set the verdict
  # to fail - otherwise the containment check blocks for an unrelated reason and the case would pass
  # even with the verdict check removed.)
  local d; d="$(new_repo verdict)"
  reset_case "$d"
  printf '\n# reviewed content, but the gate verdict was a failure\n' >> "$d/util.py"
  git -C "$d" add util.py
  review_here "$d"
  python3 - "$d/.preflight/review.meta.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["gate"] = {"verdict": "fail", "exit": 1}
json.dump(d, open(p, "w"), indent=2)
PY
  expect_commit "a failing gate verdict is blocked" "REQ-HOOK-12" 1 "$d"
}

case_block_corrupt_sidecar() {
  # A comparison that cannot run must fail closed: empty output from git is indistinguishable from
  # "no differences", which would silently pass an unverified commit.
  #
  # The corruption has to stay valid hex, and the reviewed tree must DIFFER from the staged tree,
  # or the test proves nothing - a nonexistent tree makes both git calls fail, so whichever check
  # happens to fail closed would block and the case would pass for the wrong reason.
  local d; d="$(new_repo corrupt)"
  reset_case "$d"
  review_here "$d"
  printf '\n# unreviewed change\n' >> "$d/util.py"
  git -C "$d" add util.py
  python3 - "$d/.preflight/review.meta.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
# A different, well-formed tree: the comparison runs and reports a difference, so the ONLY thing
# that can block is the hook treating "could not compare" as a failure.
d["reviewed_tree"] = "0" * 40
json.dump(d, open(p, "w"), indent=2)
PY
  expect_commit "an unusable reviewed tree is blocked" "REQ-HOOK-13" 1 "$d"
}

case_bypass_no_verify() {
  local d; d="$(new_repo bypass)"
  reset_case "$d"
  printf '\n# unreviewed\n' >> "$d/util.py"
  git -C "$d" add util.py
  if git -C "$d" -c commit.gpgsign=false commit -q --no-verify -m "deliberate bypass" >/dev/null 2>&1
  then ok "--no-verify bypasses deliberately" "REQ-HOOK-14"
  else bad "--no-verify bypasses deliberately" "REQ-HOOK-14" 0 "$?" ""; fi
}

case_bypass_skip_env() {
  local d; d="$(new_repo skipenv)"
  reset_case "$d"
  printf '\n# unreviewed\n' >> "$d/util.py"
  git -C "$d" add util.py
  if PREFLIGHT_SKIP=1 git -C "$d" -c commit.gpgsign=false commit -q -m "skip" >/dev/null 2>&1
  then ok "PREFLIGHT_SKIP=1 bypasses deliberately" "REQ-HOOK-15"
  else bad "PREFLIGHT_SKIP=1 bypasses deliberately" "REQ-HOOK-15" 0 "$?" ""; fi
}

case_head_scope_not_enforced() {
  # A head-scope review covers committed content, so it cannot vouch for a commit that did not exist
  # when it ran. The hook must say so rather than silently passing or blocking.
  local d; d="$(new_repo headscope)"
  reset_case "$d"
  review_here "$d"
  python3 - "$d/.preflight/review.meta.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["scope"] = "head"; d["reviewed_tree"] = ""
json.dump(d, open(p, "w"), indent=2)
PY
  printf '\n# unreviewed\n' >> "$d/util.py"
  git -C "$d" add util.py
  local out; out="$(git -C "$d" -c commit.gpgsign=false commit -m "head scope" 2>&1)"; local got=$?
  if [ "$got" = 0 ] && printf '%s' "$out" | grep -qi 'not enforced'; then
    ok "a head-scope review is allowed but reported as not enforced" "REQ-HOOK-16"
  else
    bad "a head-scope review is allowed but reported as not enforced" "REQ-HOOK-16" "0 + notice" "$got" "$(printf '%s\n' "$out" | sed 's/^/        | /')"
  fi
}

case_bootstrap_first_commit() {
  # `preflight-code review` cannot run before a first commit exists, so blocking the first commit would
  # make the hook impossible to adopt.
  local d="$work/bootstrap"
  mkdir -p "$d/.githooks"
  printf '#!/bin/sh\nexec sh %s\n' "$hook" > "$d/.githooks/pre-commit"
  chmod +x "$d/.githooks/pre-commit"
  ( cd "$d" && git init -q -b main . && git config core.hooksPath .githooks \
      && printf 'x = 1\n' > first.py && git add first.py ) >/dev/null 2>&1
  local out; out="$(git -C "$d" -c commit.gpgsign=false commit -m "initial" 2>&1)"; local got=$?
  if [ "$got" = 0 ] && printf '%s' "$out" | grep -qi 'no commits yet'; then
    ok "the first commit of an empty repo is allowed with a notice" "REQ-HOOK-17"
  else
    bad "the first commit of an empty repo is allowed with a notice" "REQ-HOOK-17" "0 + notice" "$got" "$(printf '%s\n' "$out" | sed 's/^/        | /')"
  fi
}

case_second_commit_is_enforced() {
  local d; d="$(new_repo enforce2)"
  reset_case "$d"
  printf '\n# unreviewed\n' >> "$d/util.py"
  git -C "$d" add util.py
  expect_commit "enforcement is active again on a later commit" "REQ-HOOK-18" 1 "$d"
}

case_hook_is_read_only() {
  local d; d="$(new_repo readonly)"
  reset_case "$d"
  review_here "$d"
  printf '\n# unreviewed\n' >> "$d/util.py"
  git -C "$d" add util.py
  local before after head_before head_after
  before="$(git -C "$d" write-tree)"; head_before="$(git -C "$d" rev-parse HEAD)"
  git -C "$d" -c commit.gpgsign=false commit -m "blocked" >/dev/null 2>&1
  after="$(git -C "$d" write-tree)"; head_after="$(git -C "$d" rev-parse HEAD)"
  if [ "$before" = "$after" ] && [ "$head_before" = "$head_after" ]; then
    ok "a blocked commit leaves the index and HEAD untouched" "REQ-HOOK-19"
  else
    bad "a blocked commit leaves the index and HEAD untouched" "REQ-HOOK-19" "unchanged" "changed" \
        "$(printf '        | index %s -> %s\n        | HEAD %s -> %s\n' "$before" "$after" "$head_before" "$head_after")"
  fi
}

case_artifacts_survive_a_block() {
  local d; d="$(new_repo artifacts)"
  reset_case "$d"
  review_here "$d"
  printf '\n# unreviewed\n' >> "$d/util.py"
  git -C "$d" add util.py
  git -C "$d" -c commit.gpgsign=false commit -m "blocked" >/dev/null 2>&1
  if [ -f "$d/.preflight/review.meta.json" ]; then
    ok "the review artifacts survive a block for inspection" "REQ-HOOK-20"
  else
    bad "the review artifacts survive a block for inspection" "REQ-HOOK-20" "present" "missing" ""
  fi
}

case_worktree_enforced() {
  # The hook must run from the worktree's own .githooks via a RELATIVE core.hooksPath.
  local d; d="$(new_repo worktree)"
  reset_case "$d"
  local wt="$work/wt-checkout"
  if ! git -C "$d" worktree add -q "$wt" -b wtbranch >/dev/null 2>&1; then
    skip "the hook enforces inside a linked worktree" "REQ-HOOK-21" "worktree unsupported here"; return
  fi
  if [ ! -f "$wt/.githooks/pre-commit" ]; then
    skip "the hook enforces inside a linked worktree" "REQ-HOOK-21" "hooks not present in the worktree"
    git -C "$d" worktree remove --force "$wt" >/dev/null 2>&1; return
  fi
  printf '\n# unreviewed in the worktree\n' >> "$wt/util.py"
  git -C "$wt" add util.py
  local staged out got
  staged="$(git -C "$wt" diff --cached --name-only)"
  out="$(git -C "$wt" -c commit.gpgsign=false commit -m "worktree change" 2>&1)"; got=$?
  if [ -z "$staged" ] && printf '%s' "$out" | grep -q 'nothing added to commit'; then
    bad "the hook enforces inside a linked worktree" "REQ-HOOK-21" 1 "nothing staged" \
        "        | the test staged nothing, so git refused on its own and the hook never decided\n"
  elif [ "$got" = 1 ]; then
    ok "the hook enforces inside a linked worktree" "REQ-HOOK-21"
  else
    bad "the hook enforces inside a linked worktree" "REQ-HOOK-21" 1 "$got" \
        "$(printf '%s\n' "$out" | sed 's/^/        | /')"
  fi
  git -C "$d" worktree remove --force "$wt" >/dev/null 2>&1
}

case_missing_helper_fails_closed() {
  local d; d="$(new_repo missing)"
  reset_case "$d"
  # A hook that points at a helper which is not there. Failing closed is the whole point of
  # installing the hook, so this must block rather than let an unverified commit through.
  printf '#!/bin/sh\nexec "%s/.githooks/does-not-exist"\n' "$d" > "$d/.githooks/pre-commit"
  chmod +x "$d/.githooks/pre-commit"
  local got
  git -C "$d" -c commit.gpgsign=false commit --allow-empty -m x >/dev/null 2>&1; got=$?
  if [ "$got" = 1 ]; then ok "a missing helper fails the commit closed" "REQ-HOOK-22"
  else bad "a missing helper fails the commit closed" "REQ-HOOK-22" 1 "$got" ""; fi
}

case_post_commit_advisory() {
  # The second bundled hook (src/githooks/post-commit). It cannot block anything - a post-commit
  # hook runs after the commit exists - so its only job is to SPEAK when enforcement silently did not
  # apply, and its own failure mode is silence. It decides by reading `scope` out of the sidecar, so a
  # sidecar it cannot read must warn rather than pass quietly: "could not read it" and "it was
  # verified" look identical from the outside otherwise.
  #
  # Driven by invoking the committed hook with `sh` from the repo root, which is how git invokes it.
  # A real commit cannot reach this state: the pre-commit hook reads the same sidecar and fails closed,
  # so a malformed one is blocked long before post-commit runs. Testing the hook directly is the only
  # way to cover its own logic.
  local d; d="$(new_repo postcommit)"
  reset_case "$d"
  install -m 0755 "$repo_root/src/githooks/post-commit" "$d/.githooks/post-commit"
  local post="$d/.githooks/post-commit" meta="$d/.preflight/review.meta.json"

  run_post() { ( cd "$d" && sh "$post" ) 2>&1; }
  set_meta() { mkdir -p "$d/.preflight"; printf '%s\n' "$1" > "$meta"; }

  local problems='' out

  # Absent sidecar: no review has run, and pre-commit would have refused the commit first - so this is
  # the one unreadable case that must stay quiet, or every fresh clone would warn on its first commit.
  rm -rf "$d/.preflight"
  out="$(run_post)"
  [ -z "$out" ] || problems="$problems
        | absent sidecar should be silent, got: $out"

  # A worktree-scope review is an enforced case, so nothing to say.
  set_meta '{"scope": "worktree", "reviewed_tree": "abc"}'
  out="$(run_post)"
  [ -z "$out" ] || problems="$problems
        | worktree scope should be silent, got: $out"

  # `commit` is the DEFAULT scope and is enforced - src/preflight-hook accepts `commit|worktree`.
  # This assertion is the regression guard for an advisory that warned on every default-scope commit:
  # it only recognised `worktree`, which was correct before `commit` became the default and stale
  # after, and the message it printed ("run 'preflight-code review' with the default worktree scope") named
  # a scope that is no longer the default.
  set_meta '{"scope": "commit", "reviewed_tree": "abc"}'
  out="$(run_post)"
  [ -z "$out" ] || problems="$problems
        | commit scope is enforced and must be silent, got: $out"

  # A head-scope review covers already-committed content, so it cannot vouch for this commit.
  set_meta '{"scope": "head", "reviewed_tree": ""}'
  out="$(run_post)"
  printf '%s' "$out" | grep -q 'scope=head' || problems="$problems
        | head scope should warn about scope=head, got: $out"

  # Not JSON at all: the reader cannot tell whether this commit was covered, so it must not be silent.
  set_meta '{ this is not json'
  out="$(run_post)"
  printf '%s' "$out" | grep -q 'cannot read' || problems="$problems
        | malformed sidecar should warn, got: $out"

  # Valid JSON with no `scope` key - the shape a review from an older or different bundle could leave.
  set_meta '{"reviewed_tree": "abc"}'
  out="$(run_post)"
  printf '%s' "$out" | grep -q 'cannot read' || problems="$problems
        | scope-less sidecar should warn, got: $out"

  # No python3: same reasoning, and the case that was actually hit in the field. git must stay on PATH
  # or the hook exits early at `git rev-parse` and the warning is never reached - which is the
  # difference between testing this branch and testing nothing.
  set_meta '{"scope": "worktree"}'
  local nopy="$work/postcommit-nopy" gitbin; gitbin="$(command -v git)"
  mkdir -p "$nopy"
  ln -sf "$gitbin" "$nopy/git"
  out="$( cd "$d" && env PATH="$nopy" /bin/sh "$post" 2>&1 )"
  printf '%s' "$out" | grep -q 'python3 not found' || problems="$problems
        | missing python3 should warn, got: $out"

  if [ -z "$problems" ]; then ok "the post-commit advisory speaks up when it cannot read the sidecar" "REQ-HOOK-27"
  else bad "the post-commit advisory speaks up when it cannot read the sidecar" "REQ-HOOK-27" \
        "silent-or-warn as listed" "see below" "$problems
"; fi
}

case_convergence_signal() {
  # The `new=N/M` convergence signal - the reason the loop can stop. It is deliberately INDEPENDENT of
  # pr-agent: it is a comparison of two JSON files, so it needs no network, no key and no installed
  # package, and it therefore runs in CI. It previously lived inside a case that skips whenever
  # pr-agent is absent (which is always, in CI), so the feature's own logic was never exercised by any
  # check - a regression in the dedupe key, the count or the hint would have passed everything.
  #
  # Drives the SHIPPED summary block from src/preflight-code rather than restating it, so the test cannot
  # drift from the code it is testing.
  if python3 - "$repo_root/src/preflight-code" <<'PY'
import json, os, re, subprocess, sys, tempfile

src = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"python3 - \"\$out_json\" \"\$out_md\" <<'PY'[^\n]*\n(.*?)\nPY\n", src, re.S)
if not blocks:
    sys.exit("cannot find the summary-line block in src/preflight-code; update this case")
d = tempfile.mkdtemp()
json_path = os.path.join(d, "review.json")
script = os.path.join(d, "summary.py")
open(script, "w").write(blocks[-1])

def summary(prev=None, current=None):
    """Run the shipped summary block over `current`, comparing against `prev` when given."""
    open(json_path, "w", encoding="utf-8").write(current or "{}")
    env = dict(os.environ)
    if prev is None:
        env.pop("PREFLIGHT_PREV_JSON", None)
    else:
        prev_path = os.path.join(d, "prev.json")
        open(prev_path, "w", encoding="utf-8").write(prev)
        env["PREFLIGHT_PREV_JSON"] = prev_path
    return subprocess.run([sys.executable, script, json_path, os.path.join(d, "review.md")],
                          capture_output=True, text=True, env=env).stdout

def finding(content, header="H", path="a.py"):
    return '{"review":{"key_issues_to_review":[{"relevant_file":"%s","issue_header":"%s","issue_content":"%s"}]}}' % (
        path, header, content)

problems = []

# Contract 1: a first review has nothing to compare against, so it must NOT claim new= (the docs say the
# field is absent then; a naive implementation reports new=N/N, which reads like a real signal).
first = summary(current=finding("same"))
if "new=" in first:
    problems.append("new= was reported on a first review, where there is no previous run: " + first.strip())

# Contract 2: a repeat is detected, and carries the judge-don't-refix hint. Normalisation is part of the
# contract: whitespace and case differences are the same finding, or the count is useless in practice.
repeat = summary(prev=finding(" SAME ", header="h"), current=finding("same"))
if "new=0/1" not in repeat:
    problems.append("an identical finding (modulo case/whitespace) was not counted as a repeat: " + repeat.strip())
if "unchanged" not in repeat:
    problems.append("a repeat did not carry the judge-don't-refix hint: " + repeat.strip())

# Contract 3: identity is the whole tuple, not the file - a different issue in the same file is NEW.
# This is the boundary that makes the count meaningful rather than a per-file flag.
changed = summary(prev=finding("different"), current=finding("same"))
if "new=1/1" not in changed:
    problems.append("a differently-worded finding in the same file was not counted as new: " + changed.strip())

# Contract 4: a previous review with NO findings must still produce the count - the round after a clean
# pass is the one most likely to be re-running for no reason, and suppressing the signal there was a real
# defect caught in review.
after_clean = summary(prev='{"review":{"key_issues_to_review":[]}}', current=finding("same"))
if "new=1/1" not in after_clean:
    problems.append("the count was suppressed after a clean previous review: " + after_clean.strip())

# Contract 5: an unreadable previous review degrades to "no count", not to a crash or a false claim.
bad_prev = os.path.join(d, "bad.json")
open(bad_prev, "w").write("{ not json")
env = dict(os.environ); env["PREFLIGHT_PREV_JSON"] = bad_prev
open(json_path, "w", encoding="utf-8").write(finding("same"))
out = subprocess.run([sys.executable, script, json_path, os.path.join(d, "review.md")],
                     capture_output=True, text=True, env=env).stdout
if "new=" in out:
    problems.append("an unreadable previous review still produced a count: " + out.strip())
if "issues=1" not in out:
    problems.append("the counts were lost when the previous review was unreadable: " + out.strip())

if problems:
    print("\n".join(problems))
    sys.exit(1)
PY
  then ok "the convergence signal counts new findings and flags repeats" "REQ-HOOK-31"
  else bad "the convergence signal counts new findings and flags repeats" "REQ-HOOK-31" \
        "new= on change, 0/N on repeat, absent on first/unreadable" "see below" \
        "the loop's stopping signal is wrong: it would either never stop (repeats look new) or stop early (a new finding looks like a repeat)"
  fi
}

case_coverage_marker_matches_real_footer() {
  # Two things only the INSTALLED pr-agent can settle, and both fail silently:
  #
  # 1. The coverage marker. `preflight-code` prints `coverage=PARTIAL` by matching pr-agent's footer in
  #    review.md. The file is model-generated prose, and a finding may discuss coverage - a review of
  #    THIS feature did, repeatedly. Text matching alone loses: the model can reproduce the footer
  #    verbatim while explaining it. The discriminator is therefore structural - findings render inside
  #    the review <table>, and the footer is emitted after it - with the footer wording as a
  #    secondary check.
  # 2. The completeness settings. CI asserts the keys are present in the generated TOML, but presence is
  #    not the same as pr-agent READING them: a key in the wrong table, or one renamed upstream, leaves
  #    the finding cap and chunking inert while every check stays green. pr-agent's own defaults are the
  #    ground truth for which section each key belongs to.
  #
  # CI deliberately never installs pr-agent (no network, no paid key), so both guards SKIP here rather
  # than pretending to have verified anything - and BOTH ids must still report, because a classified id
  # that never reports would let the selfcheck's "every case must be classified" rule go vacuous for it.
  local sp
  sp="$(ls -d "$HOME"/.local/share/uv/tools/pr-agent/lib/*/site-packages/pr_agent 2>/dev/null | head -n1)"
  if [ -z "$sp" ] || [ ! -f "$sp/tools/pr_reviewer.py" ]; then
    skip "the coverage marker ignores prose and matches the real footer" "REQ-HOOK-28" "pr-agent not installed"
    skip "the config keys sit where pr-agent reads them, and the knob list matches upstream" "REQ-HOOK-29" "pr-agent not installed"
    return
  fi

  # Drive the SHIPPED summary-line block over fixtures, so this tests behaviour rather than restating
  # the logic: extract the heredoc body from src/preflight-code and run it.
  if python3 - "$repo_root/src/preflight-code" "$sp/tools/pr_reviewer.py" <<'PY'
import re, subprocess, sys, tempfile, os

helper, reviewer = sys.argv[1:3]
src = open(helper, encoding="utf-8").read()
blocks = re.findall(r"python3 - \"\$out_json\" \"\$out_md\" <<'PY'[^\n]*\n(.*?)\nPY\n", src, re.S)
if not blocks:
    sys.exit("cannot find the summary-line block in src/preflight-code; update this case")
d = tempfile.mkdtemp()
json_path = os.path.join(d, "review.json")
open(json_path, "w").write('{"review":{"key_issues_to_review":[]}}')
script = os.path.join(d, "summary.py")
open(script, "w").write(blocks[-1])

def summary(body, prev=None, current=None):
    md = os.path.join(d, "review.md")
    open(md, "w", encoding="utf-8").write(body)
    if current is not None:
        open(json_path, "w", encoding="utf-8").write(current)
    env = dict(os.environ)
    if prev is not None:
        prev_path = os.path.join(d, "prev.json")
        open(prev_path, "w", encoding="utf-8").write(prev)
        env["PREFLIGHT_PREV_JSON"] = prev_path
    else:
        env.pop("PREFLIGHT_PREV_JSON", None)
    return subprocess.run([sys.executable, script, json_path, md],
                          capture_output=True, text=True, env=env).stdout

# The footer, rebuilt from pr-agent's own source - INCLUDING the horizontal rule that introduces it,
# because that rule is part of what the marker keys on. Each part is written across ADJACENT string
# literals in the source, so take the whole run from the `<hr>` literal (matching one literal would
# truncate the sentence, and starting at the header would drop the rule).
psrc = open(reviewer, encoding="utf-8", errors="replace").read()
anchor = psrc.index("Review coverage:")
hr_start = psrc.rindex('"', 0, psrc.rindex("<hr>", 0, anchor))
rm = re.match(r'((?:"[^"]*"\s*)+)', psrc[hr_start:])
lits = re.findall(r'"([^"]*)"', rm.group(1))
# The source spells newlines as the two characters \n; turn them into real newlines. Only these escapes
# appear here, and they are handled explicitly so the emoji is not mangled by a generic unescaper.
footer = "".join(lits).replace("\\n", "\n").replace('\\"', '"')

# The bullet line is the most format-sensitive part of COVERAGE_RE (it requires a dash, a space and a
# backtick), and the one part not rebuilt from pr-agent's own literals. Verify that pr-agent still emits
# it in that shape - the emitted f-string is the source of the format - so a change there fails this
# case loudly instead of retiring the marker while the check stays green.
if not re.search(r'f"- `\{file\}`"', psrc):
    sys.exit("pr-agent no longer emits coverage bullets as f\"- `{file}`\"; COVERAGE_RE's bullet pattern "
             "must be re-derived from its new output")
footer += "- `late.py`\n"

problems = []
# The real footer, where pr-agent emits it: after the review table, introduced by a horizontal rule.
if "PARTIAL" not in summary("<table>\n<tr><td>clean review</td></tr>\n</table>" + footer):
    problems.append("the real footer, after the table, was not detected")
# No table at all (a future output shape): the marker must still fire on the emitted footer.
if "PARTIAL" not in summary(footer):
    problems.append("the footer without a table was not detected")
# The shapes text matching could not beat, kept as regressions. Each of these tripped an earlier
# version of the marker and made a fully-reviewed diff report PARTIAL:
for why, body in (
    ("a finding quoting the footer verbatim inside the table",
     "<table>\n<tr><td>finding:<br>" + footer + "</td></tr>\n</table>\n"),
    ("prose after the table mentioning the same words, without the rule or the bullet list",
     "<table>\n<tr><td>clean</td></tr>\n</table>\n\nNote: the review says "
     "**Review coverage:** and 'were not included in this review because of the token budget'.\n"),
    ("the header and sentence without pr-agent's rule-and-bullet structure",
     "<table></table>\n\n**Review coverage:** The following files were not included in this "
     "review because of the token budget:\n"),
    ("a review that merely says the generated files were not included in this review",
     "a review that merely says: generated files were not included in this review, and stops there."),
):
    if "PARTIAL" in summary(body):
        problems.append(why + " was misread as coverage")
# And the plain line must always carry its counts, whatever the verdict.
if "issues=0" not in summary(footer):
    problems.append("the summary line lost its counts")

if problems:
    print("\n".join(problems))
    sys.exit(1)
PY
  then ok "the coverage marker ignores prose and matches the real footer" "REQ-HOOK-28"
  else bad "the coverage marker ignores prose and matches the real footer" "REQ-HOOK-28" \
        "footer detected; prose and in-table quotes ignored" "see below" \
        "a missed footer retires the PARTIAL marker (a partial review reads as complete); a spurious match fires it on a complete one"
  fi

  # Part 2: the keys the bundle sets must be in the table pr-agent actually reads them from, and the
  # example file's commented list must still match the pr-agent that is installed.
  if python3 - "$sp/settings/configuration.toml" "$repo_root/config/settings.toml.example" "$repo_root" <<'PY'
import re, sys, tomllib

defaults_path, ours_path, repo_root = sys.argv[1:4]

# Which sections pr-agent declares each key in, from its OWN defaults - the ground truth for where it
# reads them. Collect EVERY section a key appears in rather than the first: several of these keys (e.g.
# extra_instructions) are declared in many tool sections upstream, so "first occurrence wins" would
# resolve a key to whichever section happens to be listed first and fail on a correctly-configured repo.
# The assertion is therefore "pr_reviewer declares it", not "nothing else does".
# Each key with the section pr-agent reads it from. These are the keys the bundle SETS; the ones it
# deliberately leaves unset (`extra_instructions`, `reasoning_effort`, the
# `additional_reasoning_effort_models` that exists only to forward the latter, and the keys that change
# what a review covers - `enable_large_pr_chunking`, `max_number_of_calls` and
# `require_merge_recommendation`) are not listed here, and the `config` stage asserts their absence
# instead - a key that is absent cannot be put in the wrong section.
wanted = {
    "num_max_findings": "pr_reviewer",
    "review_heading": "pr_reviewer",
}
sections = {key: set() for key in wanted}
section = None
for line in open(defaults_path, encoding="utf-8", errors="replace"):
    m = re.match(r"^\[(\w+)\]", line)
    if m:
        section = m.group(1)
    m = re.match(r"^(\w+)\s*=", line)
    if m and m.group(1) in sections and section:
        sections[m.group(1)].add(section)

wrong = [k for k in sorted(wanted) if wanted[k] not in sections[k]]
if wrong:
    print("pr-agent no longer reads these from the section the bundle sets them in: "
          + ", ".join(f"{k} (expected [{wanted[k]}])" for k in wrong))
    sys.exit(2)

ours = tomllib.load(open(ours_path, "rb"))
missing = [k for k in sorted(wanted) if k not in ours.get(wanted[k], {})]
if missing:
    print("config/settings.toml.example does not set these: "
          + ", ".join(f"{k} under [{wanted[k]}]" for k in missing))
    sys.exit(3)

# The published knob list: `[pr_reviewer]` is the steering surface for review quality, so the example
# file carries every key pr-agent declares there - the ones the bundle sets LIVE, and the rest as
# comments at upstream's own value. Comments because a live default freezes it: the pinned pr-agent
# would stop inheriting a value upstream changed. That makes the list a copy of upstream's file, so it
# is checked against it here - a key added upstream, renamed, or defaulted differently shows up as a
# failing case rather than as advice that is quietly wrong.
declared = set()
sec = None
for line in open(defaults_path, encoding="utf-8", errors="replace"):
    m = re.match(r"^\[(\w+)\]", line)
    if m:
        sec = m.group(1)
    m = re.match(r"^([a-z_][a-z0-9_]*)\s*=", line)
    if m and sec == "pr_reviewer":
        declared.add(m.group(1))
upstream = tomllib.load(open(defaults_path, "rb"))["pr_reviewer"]

# Only this section, so a later one's keys cannot satisfy the comparison by coincidence.
# The REAL header - a line that is exactly `[pr_reviewer]` - not the first mention of that text. A
# comment banner naming the section (an `# ---- [pr_reviewer]` divider) satisfies a naive split, which
# leaves an empty body and reports every key as unlisted.
body = re.split(r"(?m)^\[pr_reviewer\]\s*$", open(ours_path, encoding="utf-8", errors="replace").read(), maxsplit=1)[1]
# The next section, live OR commented: a reference file spells a whole section as a commented block (the
# [gate] one is inert by design), and stopping only at a live header would read its keys as [pr_reviewer]
# comments - reporting every gate key as one pr-agent does not declare.
body = re.split(r"(?m)^#?\s*\[", body, maxsplit=1)[0]
live = tomllib.load(open(ours_path, "rb")).get("pr_reviewer", {})
commented = {}
for line in body.splitlines():
    m = re.match(r"^\s*#\s*([a-z_][a-z0-9_]*)\s*=\s*(.+?)\s*$", line)
    if m:
        commented[m.group(1)] = tomllib.loads("%s = %s" % (m.group(1), m.group(2)))[m.group(1)]

unlisted = sorted(set(declared) - set(live) - set(commented))
if unlisted:
    print("pr-agent declares these [pr_reviewer] keys and the example file does not list them: "
          + ", ".join(unlisted))
    sys.exit(5)

# A commented entry claims "this is upstream's value". The live ones are the bundle's, so only the
# commented half is compared - and a stale value here is worse than no list, because it reads as advice.
drifted = sorted(k for k, v in commented.items() if k in upstream and v != upstream[k])
if drifted:
    print("these commented [pr_reviewer] entries no longer match pr-agent's default: "
          + ", ".join("%s (listed %r, pr-agent has %r)" % (k, commented[k], upstream[k]) for k in drifted))
    sys.exit(6)

# The other direction of the same claim: a commented entry for a key pr-agent no longer declares. This is
# the ONE no-op the two checks above cannot see - `unlisted` only looks at upstream's keys, and `drifted`
# skips anything absent upstream - so a key REMOVED upstream would leave advice that reads as configurable
# and does nothing, which is the failure this case exists to catch. Verified by mutation: adding an orphan
# entry passed before this check existed.
stale = sorted(k for k in commented if k not in upstream)
if stale:
    print("these commented [pr_reviewer] entries name keys pr-agent does not declare "
          "(removed or renamed upstream), so uncommenting one would do nothing: " + ", ".join(stale))
    sys.exit(7)

# The DOCS also tell an operator which keys to set - and a wrong key path is silently ignored, so the
# advice fails without feedback. That is not hypothetical: this section of the docs once said
# `config.callback_timeout_seconds` when pr-agent reads it from `[litellm]`, so following the advice
# changed nothing. Check every `section.key` / `[section] key` reference the docs make against
# pr-agent's own defaults, so a documented path that does not exist is caught here rather than by
# someone debugging a hang.
import glob, os, subprocess
DOC_RE = re.compile(r"`(?:\[(\w+)\]\s+([a-z_][a-z0-9_]*)|(config|litellm|pr_reviewer|pr_code_suggestions)\.([a-z_][a-z0-9_]*))`")

# A dotted name that is really a FILENAME is not a config path. `pr_code_suggestions.py` parses as
# section `pr_code_suggestions` + key `py`, which is a source file - and docs cite source files
# constantly, so without this the check reports them all as bad keys.
FILE_SUFFIXES = {"py", "sh", "md", "rst", "adoc", "toml", "json", "yaml", "yml", "cfg", "ini", "txt"}

# Which keys pr-agent declares, per section.
known = {}
sec = None
for line in open(defaults_path, encoding="utf-8", errors="replace"):
    m = re.match(r"^\[(\w+)\]", line)
    if m:
        sec = m.group(1)
    m = re.match(r"^([a-z_][a-z0-9_]*)\s*=", line)
    if m and sec:
        known.setdefault(sec, set()).add(m.group(1))

docs = glob.glob(os.path.join(os.path.dirname(os.path.abspath(ours_path)), "..", "docs", "**", "*.md"),
                recursive=True) + \
       [os.path.join(os.path.dirname(os.path.abspath(ours_path)), "..", "README.md")]

# The glob must reach EVERY tracked doc. Without this the check can lose files silently simply by the
# docs tree gaining a subdirectory - and the file this check exists for is `docs/runbooks/troubleshooting.md`,
# where the wrong-key advice lived. A coverage loss with nothing to show for it is the failure mode here.
try:
    tracked = subprocess.run(["git", "-C", repo_root, "ls-files", "-z", "docs"],
                             capture_output=True, text=True, check=True).stdout.split("\0")
    scanned = {os.path.realpath(d) for d in docs}
    missed = sorted(t for t in tracked
                    if t.endswith(".md") and os.path.realpath(os.path.join(repo_root, t)) not in scanned)
except (OSError, subprocess.CalledProcessError):
    missed = []  # Not a git working tree (a source tarball): there is no tracked set to compare against.

doc_errors = []
if missed:
    doc_errors.append("these tracked docs were never scanned: " + ", ".join(missed))
checked = 0
for doc in docs:
    for line in open(doc, encoding="utf-8", errors="replace"):
        # A line may name a path in order to say it does NOT exist, which is a warning rather than advice.
        # The marker is inline and carries its reason, so the exception stays visible in review instead of
        # living in an allow-list here - the list would be the next place a real mistake hid.
        if "doc-path-ok:" in line:
            continue
        for bracket_section, bracket_key, dotted_section, dotted_key in DOC_RE.findall(line):
            section = bracket_section or dotted_section
            key = bracket_key or dotted_key
            # `findall` hands back '' for a group that did not participate, not None.
            if not bracket_key and key in FILE_SUFFIXES:
                continue
            checked += 1
            if key not in known.get(section, ()):
                doc_errors.append("%s: %s.%s is not a key pr-agent declares in [%s]" % (
                    os.path.basename(doc), section, key, section))

if doc_errors:
    print("\n".join(doc_errors))
    print("a documented config path that pr-agent ignores fails silently for whoever follows it")
    sys.exit(4)
print("documented config paths checked:", checked)

# The `model=FALLBACK` marker reads the run-details PROSE pr-agent writes, so hand-written fixtures in
# REQ-HOOK-42 cannot show that the real shape is still the one the regex expects - a fixture agrees with
# whatever the regex says. This derives the literals from the source that WRITES them and compiles the
# shipped regex over them, so a reworded marker line fails here rather than silently never firing.
import importlib.util, os as _os
spec_path = _os.path.join(_os.path.dirname(defaults_path), "..", "algo", "run_output.py")
if not _os.path.isfile(spec_path):
    print("cannot find pr-agent's run_output.py beside its settings; update this case")
    sys.exit(5)
run_output = open(spec_path, encoding="utf-8", errors="replace").read()
shipped = open(_os.path.join(repo_root, "src", "preflight-code"), encoding="utf-8", errors="replace").read()
m = re.search(r"^FALLBACK_RE = re\.compile\((.*?)\)$", shipped, re.M)
if not m:
    print("src/preflight-code no longer defines FALLBACK_RE with a single re.compile; update this case")
    sys.exit(6)
# `eval` over the literal this repo writes - not untrusted input - so the check reads the SHIPPED pattern
# rather than restating it. The captured text includes the flags argument (`..., re.M`), so the call is
# recompiled here rather than the bare string being passed to `re.compile`.
_fb_pattern = eval("re.compile(" + m.group(1) + ")", {"re": re})

# The shapes pr-agent's own f-string builds, derived from that source rather than restated. The PREFIX
# matters as much as the parenthetical: `Fallback: yes` would still contain the literal but never match the
# shipped regex, and fixtures written with the same wrong prefix would agree with it - the silent
# retirement this whole check exists to catch.
_fb_prefixes = re.findall(r'f"(- Models?: )', run_output)
if sorted(_fb_prefixes) != ["- Model: ", "- Models: "]:
    print("pr-agent's run-details no longer build their model line with the expected prefixes "
          "(found %r); check the marker's regex against the new wording" % (_fb_prefixes or "none"))
    sys.exit(7)
if "includes fallback" not in run_output or "(fallback)" not in run_output:
    print("pr-agent's run-details no longer contain the fallback literals this marker reads: "
          "check the marker's regex against the new wording")
    sys.exit(7)
# Rebuild each line the way pr-agent does, prefix included, then require the shipped regex to match it.
for line in ("- Model: some/model (fallback)", "- Models: a, b (includes fallback)"):
    if not _fb_pattern.search("<table></table>\n" + line + "\n"):
        print("the model=FALLBACK marker no longer matches the line pr-agent emits: " + repr(line))
        sys.exit(8)
# And the direction that matters for false positives, against a real review's own text.
for body in ("- Model: some/model\n", "- Models: a, b\n"):
    if _fb_pattern.search("<table></table>\n" + body + "\n"):
        print("the model=FALLBACK marker fires on a line that does NOT report a fallback: " + repr(body))
        sys.exit(9)
print("the model=FALLBACK marker matches pr-agent's own run-details wording")
PY
  then ok "the config keys sit where pr-agent reads them, and the knob list matches upstream" "REQ-HOOK-29"
  else bad "the config keys sit where pr-agent reads them, and the knob list matches upstream" "REQ-HOOK-29" \
        "each key under [pr_reviewer]" "not where pr-agent reads it" \
        "a completeness key is in the wrong table or was renamed upstream, so the finding cap is silently inert while every check stays green"
  fi
}

case_scope_defaults() {
  # The scope switch: `commit` (the pending change) is the default, and the branch scopes still work.
  #
  # Two things are asserted, and both fail silently without this case:
  #   - the DEFAULT is what the tool's purpose requires. If it regresses to a branch scope, every review
  #     becomes a whole-branch review - the cost problem this scope exists to fix - and nothing else
  #     would notice, because both modes produce a valid review.
  #   - `worktree` still resolves a base and diffs the branch. The branch machinery must survive the
  #     default changing; a refactor that gated `resolve_base` on the wrong value would leave the
  #     branch scope diffing HEAD and reviewing only the pending change while claiming to review the branch.
  #
  # Driven with a stubbed `pr-agent` that records the diff it is handed, so no key or network is needed.
  local d fake out
  d="$work/scope"; fake="$work/scope-bin"
  mkdir -p "$d" "$fake"
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
cat > "$SCOPE_DIFF_OUT"
exit 0
FAKE
  chmod +x "$fake/pr-agent"

  ( cd "$d" \
      && git init -q -b main . \
      && printf 'a\n' > f.txt \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m init \
      && git checkout -q -b feature \
      && printf 'b\n' > g.txt \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m "feat: g" \
      && printf 'c\n' >> f.txt ) >/dev/null 2>&1

  local problems=""
  # Default scope: no PREFLIGHT_SCOPE set. Must review only the pending change (f.txt), not g.txt, which
  # is already committed on this branch.
  out="$work/scope-commit.diff"
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" SCOPE_DIFF_OUT="$out" \
      PREFLIGHT_HOME="$work/scope-cfg" PREFLIGHT_BASE=main \
      bash "$repo_root/src/preflight-code" review ) >"$work/scope-commit.txt" 2>&1
  if ! grep -q "scope=commit" "$work/scope-commit.txt"; then
    problems="$problems
        | the default scope is not commit: $(grep -o 'scope=[a-z]*' "$work/scope-commit.txt" | head -1)"
  fi
  if grep -q "^+++ b/g.txt" "$out" 2>/dev/null; then
    problems="$problems
        | the default scope reviewed already-committed content (g.txt), so it is not reviewing the pending change"
  fi
  grep -q "^+++ b/f.txt" "$out" 2>/dev/null || problems="$problems
        | the default scope did not review the uncommitted change to f.txt"

  # Branch scope: must still resolve a base and include the committed work.
  out="$work/scope-worktree.diff"
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" SCOPE_DIFF_OUT="$out" \
      PREFLIGHT_SCOPE=worktree PREFLIGHT_HOME="$work/scope-cfg" PREFLIGHT_BASE=main \
      bash "$repo_root/src/preflight-code" review ) >"$work/scope-worktree.txt" 2>&1
  if ! grep -q "scope=worktree" "$work/scope-worktree.txt"; then
    problems="$problems
        | PREFLIGHT_SCOPE=worktree did not take effect"
  fi
  grep -q "^+++ b/g.txt" "$out" 2>/dev/null || problems="$problems
        | the worktree scope missed already-committed content (g.txt), so the branch diff is gone"

  # An unknown scope must be refused rather than silently treated as a known one.
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" SCOPE_DIFF_OUT="$work/scope-bad.diff" \
      PREFLIGHT_SCOPE=nonsense PREFLIGHT_HOME="$work/scope-cfg" PREFLIGHT_BASE=main \
      bash "$repo_root/src/preflight-code" review ) >/dev/null 2>&1
  bad_rc=$?
  [ "$bad_rc" = 2 ] || problems="$problems
        | an unknown PREFLIGHT_SCOPE exited $bad_rc rather than 2"

  if [ -z "$problems" ]; then ok "the commit scope is the default and the branch scopes still work" "REQ-HOOK-33"
  else bad "the commit scope is the default and the branch scopes still work" "REQ-HOOK-33" \
        "default=commit, worktree=base, unknown=exit 2" "see below" "$problems
"; fi
}

case_commit_scope_reviews_untracked() {
  # The commit scope must hand the model EVERYTHING a commit would contain, and the containment rule
  # makes an untracked file the sharp case: `reviewed_tree` is built with `git add -A`, so a new file IS
  # in the tree the hook compares against - but a bare `git diff HEAD` never lists it. That combination
  # meant an untracked file was never reviewed while the hook accepted it as reviewed, so a defect in a
  # new file could be committed with the check passing. This asserts the diff itself, because the
  # invariant is about what the model was SHOWN, not about which paths the hook allows.
  local d fake out first second problems=""
  d="$work/untracked"; fake="$work/untracked-bin"
  mkdir -p "$d" "$fake"
  # Records the diff pr-agent is handed, which is the only place this invariant is observable.
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$DIFF_OUT"
[ -n "$js" ] && printf '%s\n' '{"review":{"key_issues_to_review":[],"security_concerns":"No"}}' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
exit 0
FAKE
  chmod +x "$fake/pr-agent"

  ( cd "$d" \
      && git init -q -b main . \
      && printf 'x = 1\n' > tracked.py \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m init \
      && printf '\ndef new_thing(a, b):\n    return a / (b - b)\n' > untracked.py \
      && printf '\nchanged = True\n' >> tracked.py ) >/dev/null 2>&1
  git -C "$d" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    bad "the commit scope reviews untracked files, not just tracked edits" "REQ-HOOK-37" \
        "a seeded repository" "no commit" \
        "the case could not build its fixture, so the reviewed diff was never exercised"
    return
  }

  out="$work/untracked.diff"
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" DIFF_OUT="$out" \
      PREFLIGHT_HOME="$work/untracked-cfg" \
      bash "$repo_root/src/preflight-code" review ) >"$work/untracked.txt" 2>&1

  grep -q '^+++ b/untracked\.py' "$out" 2>/dev/null || problems="$problems
        | the new UNTRACKED file was not in the diff handed to the model, yet it is in reviewed_tree - so
        | the hook would accept it as reviewed while nothing ever looked at it"
  grep -q '^+++ b/tracked\.py' "$out" 2>/dev/null || problems="$problems
        | the tracked edit was missing from the reviewed diff"

  if [ -z "$problems" ]; then ok "the commit scope reviews untracked files, not just tracked edits" "REQ-HOOK-37"
  else bad "the commit scope reviews untracked files, not just tracked edits" "REQ-HOOK-37" \
        "the diff handed to the model contains untracked.py and tracked.py" "see below" "$problems
"; fi
}

# ---------------------------------------------------------------------------- summary wiring

case_summary_wiring() {
  # REQ-HOOK-31 proves the COUNTING is right by extracting the summary heredoc from src/preflight-code and
  # running it standalone - so it never exercises the wiring around it: that `emit_summary` is actually
  # called, and that the previous review is actually exported to the comparison. A helper whose summary
  # block is correct but never invoked would pass that case and report no convergence signal at all,
  # which is the loop's only stopping rule.
  #
  # This drives the REAL helper, end to end, against a stubbed `pr-agent` on PATH - the pattern
  # REQ-HOOK-32 established, so it needs no key and no network, and therefore runs in CI. Two runs:
  #   - the first has no previous review, so it must print counts and must NOT claim a `new=` count;
  #   - the second repeats the same finding, so it must report it as a repeat.
  local d fake out rc problems=""
  d="$work/wiring"; fake="$work/wiring-bin"
  mkdir -p "$d" "$fake"
  # Writes both artifacts, so the helper treats the review as complete and reads the counts from JSON.
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$js" ] && printf '%s\n' '{"review":{"key_issues_to_review":[{"relevant_file":"a.py","issue_header":"H","issue_content":"same"}],"security_concerns":"No","estimated_effort_to_review_[1-5]":3,"risk_level":"low","merge_recommendation":"review carefully"},"usage":{"total_tokens":123}}' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
exit 0
FAKE
  chmod +x "$fake/pr-agent"

  ( cd "$d" \
      && git init -q -b main . \
      && printf 'a\n' > f.txt \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m init \
      && printf 'b\n' >> f.txt ) >/dev/null 2>&1
  git -C "$d" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    bad "the summary line reports the convergence signal from a real run" "REQ-HOOK-34" \
        "a seeded repository" "no commit" \
        "the case could not build its fixture, so the summary wiring was never exercised"
    return
  }

  # This case is about the summary line. The gate is resolved from the helper's own directory and run
  # afterwards, writing the sidecar regardless of its verdict.
  run_once() {
    ( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$work/wiring-cfg" \
        bash "$repo_root/src/preflight-code" review ) 2>&1
  }

  rc=0; out="$(run_once)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | the first run failed (exit $rc), so the summary was never produced: $out"
  case "$out" in *"issues=1"*) ;; *) problems="$problems
        | (1) the counts were not reported on a normal run: $out" ;; esac
  case "$out" in *"new="*) problems="$problems
        | (1) a first review claimed a new= count, but it has no previous run to compare against" ;; esac

  rc=0; out="$(run_once)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | the second run failed (exit $rc): $out"
  case "$out" in *"new=0/1"*) ;; *) problems="$problems
        | (2) a repeat of the previous finding was not reported as new=0/1, so the convergence signal is
        |     not wired to the previous review: $out" ;; esac

  if [ -z "$problems" ]; then ok "the summary line reports the convergence signal from a real run" "REQ-HOOK-34"
  else bad "the summary line reports the convergence signal from a real run" "REQ-HOOK-34" \
        "issues= on the first run with no new=, new=0/1 on the second" "see below" "$problems
"; fi
}

# ---------------------------------------------------------------------------- the verdict fields

case_verdict_fields() {
  # The summary line already carries the two counts `preflight-gate` decides its verdict on - issues and
  # security - but the other two it fails on, `risk_level` and `merge_recommendation`, appear only in the
  # gate's own output. So `preflight-code review` alone reports a change that the gate will then refuse, and the
  # only way to learn why is to run a second command.
  #
  # Asserted against the stub's known values (low / review carefully), which also pins the shape: both are
  # free-text from the model, so an absent field must degrade to a placeholder rather than print an empty
  # `risk=` or the literal `None`, which read as a verdict of their own.
  local d fake out rc problems=""
  d="$work/verdict"; fake="$work/verdict-bin"
  mkdir -p "$d" "$fake"
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$js" ] && printf '%s\n' '{"review":{"key_issues_to_review":[],"security_concerns":"No","estimated_effort_to_review_[1-5]":3,"risk_level":"low","merge_recommendation":"review carefully"},"usage":{"total_tokens":123}}' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
exit 0
FAKE
  # Same stub, but with neither verdict field present: the model is free not to return them.
  local sparse="$work/verdict-sparse"
  mkdir -p "$sparse"
  cat > "$sparse/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$js" ] && printf '%s\n' '{"review":{"key_issues_to_review":[],"security_concerns":"No"}}' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
exit 0
FAKE
  chmod +x "$fake/pr-agent" "$sparse/pr-agent"

  ( cd "$d" \
      && git init -q -b main . \
      && printf 'a\n' > f.txt \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m init \
      && printf 'b\n' >> f.txt ) >/dev/null 2>&1
  git -C "$d" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    bad "the summary line reports the fields the gate fails on" "REQ-HOOK-35" \
        "a seeded repository" "no commit" \
        "the case could not build its fixture, so the summary fields were never exercised"
    return
  }

  rc=0
  out="$( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$work/verdict-cfg" \
            bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | the run failed (exit $rc): $out"
  case "$out" in *"risk=low"*) ;; *) problems="$problems
        | (1) risk_level was not reported on the summary line: $out" ;; esac
  case "$out" in *"merge=review carefully"*) ;; *) problems="$problems
        | (1) merge_recommendation was not reported on the summary line: $out" ;; esac

  rc=0
  out="$( cd "$d" && rm -rf .preflight && PATH="$sparse:$PATH" PREFLIGHT_HOME="$work/verdict-cfg" \
            bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | the run failed (exit $rc) on a review without the verdict fields: $out"
  case "$out" in *"risk=n/a"*) ;; *) problems="$problems
        | (2) an absent risk_level did not degrade to risk=n/a (an empty or literal-None value reads as a verdict): $out" ;; esac
  case "$out" in *"merge=n/a"*) ;; *) problems="$problems
        | (2) an absent merge_recommendation did not degrade to merge=n/a: $out" ;; esac
  # effort and tokens are the third and fourth fields on the line, and each was missed in turn: effort
  # printed a literal `effort=None`, and once that was fixed `tokens` did the same against a payload with
  # no `usage` object. Assert BOTH against the sparse payload below, which carries neither the effort
  # value nor a `usage` object.
  case "$out" in *"effort=n/a"*) ;; *) problems="$problems
        | (2) an absent effort did not degrade to effort=n/a: $out" ;; esac
  case "$out" in *"tokens=n/a"*) ;; *) problems="$problems
        | (2) an absent usage object did not degrade to tokens=n/a: $out" ;; esac
  # A malformed CONTAINER is the other half: a `review` or `usage` that is not an object raised on
  # `.get` and lost the line, before any field was even read. The gate still refuses it (exit 3), so this
  # is about keeping the counts visible, not about softening the verdict.
  local badshape="$work/verdict-badshape"
  mkdir -p "$badshape"
  cat > "$badshape/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$js" ] && printf '%s\n' '{"review":"text","usage":5}' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
exit 0
FAKE
  chmod +x "$badshape/pr-agent"
  rc=0
  out="$( cd "$d" && rm -rf .preflight && PATH="$badshape:$PATH" PREFLIGHT_HOME="$work/verdict-cfg" \
            bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  case "$out" in *"issues=0"*) ;; *) problems="$problems
        | (5) a non-object review/usage lost the summary line instead of degrading: $out" ;; esac

  # The general shape, so a fifth field added later cannot reintroduce the same leak: no field on the
  # line may print the literal None.
  case "$out" in *"=None"*) problems="$problems
        | (2) a bare None reached the summary line: $out" ;; esac

  # A wrongly-TYPED field is worse than an absent one: `security_concerns: true` (which the model does
  # return, and which preflight-gate has its own guard for) made `.strip()` raise AttributeError, killing
  # the heredoc so `issues=`, `new=` and `coverage=` were lost together. Assert the coercion handles the
  # JSON types the model actually sends, not just absence.
  local typed="$work/verdict-typed"
  mkdir -p "$typed"
  cat > "$typed/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$js" ] && printf '%s\n' '{"review":{"key_issues_to_review":[],"security_concerns":true},"usage":{"total_tokens":7}}' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
exit 0
FAKE
  chmod +x "$typed/pr-agent"
  rc=0
  out="$( cd "$d" && rm -rf .preflight && PATH="$typed:$PATH" PREFLIGHT_HOME="$work/verdict-cfg" \
            bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  # The counts must survive a boolean field: if the line is missing entirely, the heredoc raised.
  case "$out" in *"issues=0"*) ;; *) problems="$problems
        | (3) a boolean security_concerns destroyed the summary line instead of degrading: $out" ;; esac
  case "$out" in *"security=yes"*) ;; *) problems="$problems
        | (3) a boolean security_concerns was not coerced to yes/no: $out" ;; esac

  # `key_issues_to_review` is the one field whose TYPE feeds `len()`, so a wrong type does not just print
  # wrong - `"no issues"` reported `issues=9`, and an int or bool raised and lost the whole line. The gate
  # exits 3 on a non-list; the summary cannot exit, so it must fall back and still print.
  local badlist="$work/verdict-badlist"
  mkdir -p "$badlist"
  cat > "$badlist/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$js" ] && printf '%s\n' '{"review":{"key_issues_to_review":"no issues","security_concerns":"No"}}' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
exit 0
FAKE
  chmod +x "$badlist/pr-agent"
  rc=0
  out="$( cd "$d" && rm -rf .preflight && PATH="$badlist:$PATH" PREFLIGHT_HOME="$work/verdict-cfg" \
            bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  case "$out" in *"issues=0"*) ;; *) problems="$problems
        | (4) a non-list key_issues_to_review did not degrade to issues=0
        |     (a string reports its character count, and an int or bool loses the line): $out" ;; esac

  if [ -z "$problems" ]; then ok "the summary line reports the fields the gate fails on" "REQ-HOOK-35"
  else bad "the summary line reports the fields the gate fails on" "REQ-HOOK-35" \
        "risk=low merge=review carefully, and no empty value when absent" "see below" "$problems
"; fi
}

# --------------------------------------------------------------- the partial review, in every scope

case_partial_review_announced_in_commit_scope() {
  # A pruned diff must announce itself in the DEFAULT scope too. The marker was once gated on the branch
  # scopes, on the reasoning that a pending-commit diff is far below the token budget - true of ordinary
  # changes and false of a large one, and the bundle does not chunk, so pruning is what happens to an
  # over-budget diff. With the marker suppressed there, a commit-scope review of a slice printed a clean
  # summary line and nothing else said the rest was never looked at - the exact false-clean this bundle
  # exists to prevent, reintroduced by a scope condition rather than by the matching.
  #
  # Driven through the real helper with a stubbed `pr-agent`, so the assertion is about the ship path
  # (scope -> emit_summary) rather than about the marker regex in isolation.
  local d fake out rc
  d="$work/partial-scope"; fake="$work/partial-scope-bin"
  mkdir -p "$d" "$fake"
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
[ -n "$js" ] && printf '%s\n' '{"review":{"key_issues_to_review":[],"security_concerns":"No"},"usage":{"total_tokens":1}}' > "$js"
# The real footer shape: after the findings' table, introduced by a horizontal rule.
[ -n "$out" ] && {
  printf '<table></table>\n' > "$out"
  printf '\n<hr>\n\n' >> "$out"
  printf '%s\n' '**Review coverage:** The following files were not included in this review because of the token budget:' >> "$out"
  printf '%s\n' '- `big.py`' >> "$out"
}
exit 0
FAKE
  chmod +x "$fake/pr-agent"
  ( cd "$d" \
      && git init -q -b main . \
      && printf 'a\n' > f.txt \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m init \
      && printf 'b\n' >> f.txt ) >/dev/null 2>&1
  git -C "$d" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    bad "a partial review announces itself in the default scope" "REQ-HOOK-43" \
        "a seeded repository" "no commit" \
        "the case could not build its fixture, so the commit-scope path was never exercised"
    return
  }

  rc=0
  out="$( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_HOME="$work/partial-scope-cfg" \
            bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  [ "$rc" = 0 ] || {
    bad "a partial review announces itself in the default scope" "REQ-HOOK-43" \
        "a completed run" "exit $rc" \
        "the run failed, so the summary line was never produced: $out"
    return
  }
  case "$out" in
    *"scope=commit"*) ;;
    *) bad "a partial review announces itself in the default scope" "REQ-HOOK-43" \
           "scope=commit on the summary" "not the default scope" \
           "the case did not run in the default scope, so it does not cover the gap: $out"; return ;;
  esac
  case "$out" in
    *"coverage=PARTIAL"*) ok "a partial review announces itself in the default scope" "REQ-HOOK-43" ;;
    *) bad "a partial review announces itself in the default scope" "REQ-HOOK-43" \
         "coverage=PARTIAL on a commit-scope review whose diff was pruned" "silent" \
         "a pruned commit-scope review reports a clean summary with no mention that files were left out: $out" ;;
  esac
}

# ---------------------------------------------------------------------------- which model answered

case_fallback_model_signal() {
  # pr-agent tries `config.model` and only then `fallback_models`, and records the winner in the run
  # details - which reach the review as PROSE, not as a field in review.json (v0.47.0's JSON carries only
  # `review` and `usage`). So there is no structured field to read, and this case pins the text it does
  # read, in both directions.
  #
  # It matters because a fallback answer is a different model's judgement presented as the configured
  # one: the run looks normal, `issues=0` reads as a clean review, and nothing says the model the bundle
  # was set up for never answered. That is the shape this repository guards against everywhere else - an
  # inability to check that is indistinguishable from a pass.
  local d out rc problems=""
  d="$work/fallback"
  mkdir -p "$d"
  ( cd "$d" \
      && git init -q -b main . \
      && printf 'a\n' > f.txt \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m init \
      && printf 'b\n' >> f.txt ) >/dev/null 2>&1
  git -C "$d" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    bad "the summary line says when a fallback model answered" "REQ-HOOK-42" \
        "a seeded repository" "no commit" \
        "the case could not build its fixture, so the signal was never exercised"
    return
  }

  # One stub per run-details shape, each writing the block pr-agent really emits. The details sit AFTER
  # the findings' `</table>`, which is what stops a finding that quotes them from firing the marker.
  # `check <label> <FALLBACK|absent> '<run-details block>'`.
  check() {
    local label="$1" want="$2" details="$3" bin
    bin="$work/fallback-bin/$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '-')"
    mkdir -p "$bin"
    # Written with a QUOTED heredoc so the JSON and the `%s\n` reach the stub intact: building this
    # through `printf` eats a backslash and the JSON comes out as one line ending in a literal `n`,
    # which is invalid JSON and silently costs the whole summary line.
    cat > "$bin/pr-agent" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
# Drain stdin before writing anything. `preflight-code` streams the diff into the child, so a stub that exits
# without reading kills the writing side with SIGPIPE, which the helper reads as a failed model call - this
# case would then fail, or flake on the timing of the write, for a reason unrelated to the marker it tests.
cat >/dev/null
[ -n "$js" ] && printf '%s\n' '{"review":{"key_issues_to_review":[],"security_concerns":"No"},"usage":{"total_tokens":1}}' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
STUB
    # The details are appended to the stub's output as a heredoc, so a multi-line block never has to be
    # quoted through `printf %s`. Written BEFORE the `exit 0` below - appended after it, the shell would
    # never reach it and every stub would look like a primary-model run.
    {
      cat <<'APPEND'
cat >> "$out" <<'DETAILS' 2>/dev/null || true
APPEND
      printf '%s\n' "$details"
      printf '%s\n' DETAILS 'exit 0'
    } >> "$bin/pr-agent"
    chmod +x "$bin/pr-agent"

    rc=0
    out="$( cd "$d" && rm -rf .preflight && PATH="$bin:$PATH" PREFLIGHT_HOME="$work/fallback-cfg" \
              bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
    [ "$rc" = 0 ] || problems="$problems
        | the run failed (exit $rc) with $label: $out"
    if [ "$want" = FALLBACK ]; then
      case "$out" in *"model=FALLBACK"*) ;; *) problems="$problems
        | $label: the summary line did not say a fallback answered: $out" ;; esac
    else
      case "$out" in *"model=FALLBACK"*) problems="$problems
        | $label: the summary line claimed a fallback when the configured model answered: $out" ;; esac
    fi
  }

  # A single model that lost to the fallback, and the plural form pr-agent emits when more than one model
  # contributed (the chunking path, which marks it `(includes fallback)` instead).
  check fallback-answered FALLBACK '- Model: example-small (fallback)
- Tokens: 1 / 2 / 3
- AI calls: 1'
  check multi-with-fallback FALLBACK '- Models: a, b (includes fallback)
- Tokens: 1 / 2 / 3'
  # The other direction: the configured model answered, so the line must stay quiet. Without these the
  # marker could fire unconditionally and every assertion above would still pass.
  check primary-answered absent '- Model: example-large
- Tokens: 1 / 2 / 3
- AI calls: 1'
  check multi-no-fallback absent '- Models: a, b
- Tokens: 1 / 2 / 3'

  if [ -z "$problems" ]; then ok "the summary line says when a fallback model answered" "REQ-HOOK-42"
  else bad "the summary line says when a fallback model answered" "REQ-HOOK-42" \
        "model=FALLBACK when a fallback answered, absent when the configured model did" "see below" "$problems
"; fi
}

case_bounded_shutdown() {
  # The post-run hang, without a network or a key: a fake `pr-agent` writes the two artifacts and then
  # sleeps, which is the observed shape (the review is complete; only the exit is stuck). Five behaviours
  # are asserted, each one a way the helper previously failed:
  #
  #   1. the counts are still reported, so a hang cannot hide `issues=`/`new=`;
  #   2. the hung process is stopped rather than blocking the loop;
  #   3. the run SUCCEEDS and records its sidecar, because the review is complete and `preflight-gate`
  #      decides the verdict - otherwise a saved run would leave the next commit blocked;
  #   4. a request that writes no artifact (`describe`) is never bounded, since there is nothing to
  #      salvage and a timeout must not cut off valid work;
  #   5. a hang that produced no review FAILS, so a caller's loop cannot read a missing review as a pass.
  #
  # The helper runs under a watchdog: a regression here hangs rather than fails, and a test that stalls the
  # suite reports nothing. The fake publishes its own PID ($FAKE_PID) so the watchdog can stop it too -
  # killing only the subshell would orphan its `sleep`.
  local d fake slow cfg fpid
  d="$work/shutdown"; fake="$work/shutdown-bin"; slow="$work/shutdown-slow"
  cfg="$work/shutdown-cfg"; fpid="$work/shutdown-fake.pid"
  mkdir -p "$d/.githooks" "$fake" "$slow" "$cfg"
  PREFLIGHT_HOME="$cfg" PREFLIGHT_BIN_DIR="$cfg/.bin" \
    PREFLIGHT_SKIP_TOOL_INSTALL=1 "$repo_root/install.sh" >/dev/null 2>&1
  cp "$cfg/settings.toml.example" "$cfg/settings.toml"
  cp "$cfg/providers.toml.example" "$cfg/providers.toml"
  # The one value the reference cannot carry for the user: its key is empty, and the resolver refuses an
  # empty credential - so the copy is completed exactly as the NEXT line tells a user to.
  sed -i.bak 's/^key = ""/key = "test-key"/' "$cfg/providers.toml" && rm -f "$cfg/providers.toml.bak"
  chmod 600 "$cfg/providers.toml"

  # Writes both artifacts, then hangs. `exec` makes this PID the sleeper, so stopping it stops the sleep.
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$js" ] && printf '{"review":{"key_issues_to_review":[{"relevant_file":"a.py","issue_header":"H","issue_content":"c"}],"security_concerns":"No","estimated_effort_to_review_[1-5]":3},"usage":{"total_tokens":123}}\n' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
[ -n "$FAKE_PID" ] && printf '%s\n' "$$" > "$FAKE_PID"
exec sleep 600
FAKE
  # Writes only the markdown, like describe/improve/ask, and takes longer than the shutdown cap.
  cat > "$slow/pr-agent" <<'SLOW'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
sleep 6
[ -n "$out" ] && printf 'a description\n' > "$out"
[ -n "$FAKE_PID" ] && printf '%s\n' "$$" > "$FAKE_PID"
exit 0
SLOW
  chmod +x "$fake/pr-agent" "$slow/pr-agent"

  cp -R "$here/sample/." "$d/"
  ( cd "$d" && git init -q -b main . \
      && git -c commit.gpgsign=false add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m "chore: sample" ) >/dev/null 2>&1
  git -C "$d" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    bad "a hung shutdown still reports, bounds and succeeds" "REQ-HOOK-32" "a seeded repository" "no commit" \
        "the case could not build its fixture, so the shutdown behaviour was never exercised"
    return
  }
  printf '\n\n# unreviewed\n' >> "$d/util.py"

  local out_file="$work/shutdown-out.txt" problems="" rc
  rm -f "$fpid"
  ( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" PREFLIGHT_BASE=main \
      PREFLIGHT_SHUTDOWN_WAIT=3 PREFLIGHT_REVIEW_WAIT=30 FAKE_PID="$fpid" \
      bash "$repo_root/src/preflight-code" review > "$out_file" 2>&1; echo $? > "$work/shutdown-rc.txt" ) &
  local run_pid=$! held=0 timed_out=''
  while kill -0 "$run_pid" 2>/dev/null && [ "$held" -lt 25 ]; do sleep 1; held=$((held + 1)); done
  if kill -0 "$run_pid" 2>/dev/null; then
    timed_out=1
    # The fake first, then the subshell: killing only the subshell leaves the fake (and its `sleep`) alive.
    # Validate before signalling: `kill -KILL 0` (what a bare `|| echo 0` fallback would produce) sends
    # SIGKILL to the CALLER'S WHOLE PROCESS GROUP - the suite and its parent shell included. An empty or
    # missing pid file must mean "nothing to stop", not "kill everything".
    fake_pid="$(cat "$fpid" 2>/dev/null || true)"
    case "$fake_pid" in
      ''|*[!0-9]*) ;;
      *) kill -KILL "$fake_pid" 2>/dev/null || true ;;
    esac
    kill -TERM "$run_pid" 2>/dev/null || true
    sleep 1; kill -KILL "$run_pid" 2>/dev/null || true
  fi
  wait "$run_pid" 2>/dev/null || true
  out="$(cat "$out_file" 2>/dev/null || true)"
  rc="$(cat "$work/shutdown-rc.txt" 2>/dev/null || echo 124)"

  [ -z "$timed_out" ] || problems="$problems
        | the helper never returned, so the shutdown bound is not in force"
  case "$out" in *"issues=1"*) ;; *) problems="$problems
        | (1) the counts were not reported, so a hang still hides issues=/new=: $out" ;; esac
  case "$out" in *"did not exit"*) ;; *) problems="$problems
        | (2) the stalled process was not reported and stopped" ;; esac
  [ "$rc" = 0 ] || problems="$problems
        | (3) the run failed (exit $rc) despite a complete, usable artifact"
  [ -f "$d/.preflight/review.meta.json" ] || problems="$problems
        | (3) no sidecar was recorded, so the next commit would be blocked despite a complete review"

  # (4) describe writes no artifact, so it must be allowed to finish: no cap, no kill.
  rm -rf "$d/.preflight"
  ( cd "$d" && PATH="$slow:$PATH" PREFLIGHT_HOME="$cfg" PREFLIGHT_BASE=main \
      PREFLIGHT_SHUTDOWN_WAIT=2 bash "$repo_root/src/preflight-code" describe ) >"$work/shutdown-desc.txt" 2>&1
  grep -q 'did not exit' "$work/shutdown-desc.txt" && problems="$problems
        | (4) describe was bounded and killed: a command with no artifact must not be cut off"
  [ -f "$d/.preflight/description.md" ] || problems="$problems
        | (4) describe produced no output, so its run was lost"

  # (5) A hang that never writes a review must FAIL - exiting 0 would read as a pass to a caller's loop.
  rm -rf "$d/.preflight"
  printf '#!/bin/sh\nexec sleep 600\n' > "$fake/pr-agent"; chmod +x "$fake/pr-agent"
  dead_rc=0
  ( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" PREFLIGHT_BASE=main \
      PREFLIGHT_SHUTDOWN_WAIT=3 PREFLIGHT_REVIEW_WAIT=5 \
      bash "$repo_root/src/preflight-code" review ) >/dev/null 2>&1 || dead_rc=$?
  [ "$dead_rc" != 0 ] || problems="$problems
        | (5) a hang that wrote no review exited 0, so a missing review reads as a pass"

  if [ -z "$problems" ]; then ok "a hung shutdown still reports, bounds and succeeds" "REQ-HOOK-32"
  else bad "a hung shutdown still reports, bounds and succeeds" "REQ-HOOK-32" \
        "counts printed, process stopped, exit 0, sidecar written, describe untouched, no-review fails" "see below" "$problems
"; fi
}

# ---------------------------------------------------------------------------- run history

case_run_history() {
  # Every run that SUCCEEDS is kept under `$dir/runs/<id>/` with its start, finish and duration, because
  # the next run DESTROYS the previous one: `preflight-code` removes `review.json`/`review.md` before launching
  # pr-agent (phase 1 polls for the file, so a stale one would report the previous run's counts). That
  # removal is load-bearing and stays - which is exactly why the run it removes has to be preserved
  # somewhere, and why the assertions below are about the PREVIOUS run surviving, not only about a
  # directory existing.
  #
  # The fixed top-level paths must keep meaning "the latest run": the commit hook reads
  # `.preflight/review.meta.json` and preflight-gate reads `.preflight/review.json`, both by name. So the
  # history is additive, and the case asserts the old paths still land.
  #
  # Only a successful run is archived, and that is the sharp edge this case mostly guards: the fixed
  # paths are not deleted before a describe/improve/ask launch (only review's are), so after a failed run
  # they still hold the PREVIOUS run's file. Archiving on "the artifact exists" therefore filed stale
  # output - and, before that, the previous review's sidecar - under a run that never produced it.
  #
  # Drives the REAL helper against a stub `pr-agent` - the pattern REQ-HOOK-32/REQ-HOOK-34 established -
  # so it needs no key and no network and therefore runs in CI. The stub DRAINS STDIN: `preflight-code` pipes
  # the diff into it, and a stub that exits without reading kills the writing side with SIGPIPE, which
  # the helper reads as the model call failing. That is the stub's bug, not the helper's, and it would
  # make this case assert the wrong thing.
  local d fake cfg problems="" rc out first
  d="$work/history"; fake="$work/history-bin"; cfg="$work/history-cfg"
  mkdir -p "$d" "$fake" "$cfg"
  # The success stub, reused: `agent_ok` restores it after a case installs a failing one.
  # Each invocation writes DIFFERENT bytes, so "the first run's archived review.json still holds the
  # first run's output" is a claim a comparison can actually falsify. A stub with constant output made
  # that check unfalsifiable: reusing the first run's directory would compare equal and pass (found by
  # reviewing this change with the tool).
  agent_ok() {
    cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
cat >/dev/null
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
seq=$(cat "$FAKE_SEQ" 2>/dev/null || echo 0); seq=$((seq + 1)); [ -n "$FAKE_SEQ" ] && printf '%s' "$seq" > "$FAKE_SEQ"
[ -n "$js" ] && printf '%s\n' "{\"review\":{\"key_issues_to_review\":[{\"relevant_file\":\"a.py\",\"issue_header\":\"H\",\"issue_content\":\"run-$seq\"}],\"security_concerns\":\"No\",\"estimated_effort_to_review_[1-5]\":3},\"usage\":{\"total_tokens\":$seq}}" > "$js"
[ -n "$out" ] && printf '<table></table>\nrun %s\n' "$seq" > "$out"
exit 0
FAKE
    chmod +x "$fake/pr-agent"
  }
  agent_ok

  ( cd "$d" \
      && git init -q -b main . \
      && printf 'a\n' > f.txt \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m init \
      && printf 'b\n' >> f.txt ) >/dev/null 2>&1
  git -C "$d" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    bad "every successful run is kept with its start, finish and duration" "REQ-HOOK-41" "a seeded repository" "no commit" \
        "the case could not build its fixture, so the run history was never exercised"
    return
  }

  run() { ( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" FAKE_SEQ="$work/history-seq" \
              bash "$repo_root/src/preflight-code" "$1" ) 2>&1; }

  rc=0; out="$(run review)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | the first review failed (exit $rc): $out"

  first="$(ls -1 "$d/.preflight/runs" 2>/dev/null | head -n1)"
  [ -n "$first" ] || problems="$problems
        | no run directory was created under .preflight/runs/"

  if [ -n "$first" ]; then
    for f in run.json review.md review.json; do
      [ -f "$d/.preflight/runs/$first/$f" ] || problems="$problems
        | the first run did not archive $f"
    done
    # start, finish and duration, read as JSON rather than grepped for - a field that is present but
    # empty, or a duration that is not a number, would satisfy a substring check.
    #
    # `if python3 ... <<'PY'`, not an assignment from `$( ... <<'PY' ... )`: that is the form every other
    # Python block in this suite uses, and it avoids the heredoc-inside-command-substitution shape that
    # AGENTS.md documents as a bash 3.2 mis-parse (the bodies here carry no apostrophe, which is what
    # actually triggers it, but there is no reason to take the risk).
    if python3 - "$d/.preflight/runs/$first/run.json" <<'PY'
import json, sys
bad = []
try:
    d = json.load(open(sys.argv[1]))
except Exception as exc:
    sys.exit("run.json is not readable JSON: %s" % exc)
for key in ("started_at", "finished_at"):
    stamp = d.get(key)
    if not isinstance(stamp, str) or not stamp.endswith("Z") or "T" not in stamp:
        bad.append("%s=%r is not a UTC timestamp" % (key, stamp))
if not isinstance(d.get("duration_seconds"), int):
    bad.append("duration_seconds=%r is not a number" % (d.get("duration_seconds"),))
if d.get("command") != "review":
    bad.append("command=%r" % (d.get("command"),))
if sorted(d.get("artifacts") or []) != ["review.json", "review.md", "review.meta.json"]:
    bad.append("artifacts=%r" % (d.get("artifacts"),))
# Non-zero on a finding: `print` alone exits 0, so the `if` below would never take its else-branch and
# every assertion in this block would be dead (found by reviewing this change with the tool).
if bad:
    sys.exit("\n".join(bad))
PY
    then :; else problems="$problems
        | run.json does not record the run (diagnostic above)" ; fi
    # The old paths still mean "the latest run" - the commit hook and the gate read them by name.
    [ -f "$d/.preflight/review.meta.json" ] || problems="$problems
        | the sidecar is no longer at the fixed path the commit hook reads"
    cp "$d/.preflight/runs/$first/review.json" "$work/history-first.json"
  fi

  rc=0; out="$(run review)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | the second review failed (exit $rc): $out"
  # Order-independent: `ls` sorts ids lexically and the pid is not zero-padded, so two runs in the same
  # UTC second can sort either way (…-1000 before …-999) and a head/tail comparison would report a false
  # failure. The set is what matters, and the directory COUNT already proves the first was not reused.
  [ "$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')" = 2 ] || problems="$problems
        | a second run did not leave two run directories, so the first was lost"
  [ "$(ls -1 "$d/.preflight/runs" 2>/dev/null | grep -cxF "$first")" = 1 ] || problems="$problems
        | the first run's directory is no longer present after a second run"
  if [ -n "$first" ] && [ -f "$work/history-first.json" ]; then
    cmp -s "$work/history-first.json" "$d/.preflight/runs/$first/review.json" || problems="$problems
        | the second run overwrote the FIRST run's archived review.json"
  fi

  # Every command is archived, not just `review` - and ONLY its own artifacts. `describe` writes no
  # sidecar, so it must not inherit the `review.meta.json` a previous review left at the fixed path:
  # keying the archive on the run succeeding rather than on the command credited describe with the
  # previous review's sidecar (found by reviewing this change with the tool).
  rc=0; out="$(run describe)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | describe failed (exit $rc): $out"
  # Same `if python3 ... <<'PY'` shape as above, for the same reason: no `$( )` around a heredoc.
  if python3 - "$d/.preflight/runs" <<'PY'
import json, os, sys
runs = sys.argv[1]
found = None
for name in sorted(os.listdir(runs)):
    path = os.path.join(runs, name, "run.json")
    if not os.path.isfile(path):
        continue
    # A read that fails must be REPORTED, not skipped: this is JSON the helper wrote, so a malformed one
    # means the helper wrote it badly, which is exactly what this assertion exists to catch.
    try:
        record = json.load(open(path))
    except Exception as exc:
        sys.exit("run.json under runs/%s is not readable JSON: %s" % (name, exc))
    if record.get("command") != "describe":
        continue
    found = name
    if sorted(record.get("artifacts") or []) != ["description.md"]:
        sys.exit("the describe run archived %r, not just its own description.md" % (record.get("artifacts"),))
    if os.path.exists(os.path.join(runs, name, "review.meta.json")):
        sys.exit("the previous review's review.meta.json was archived into the describe run")
if found is None:
    sys.exit("describe was not recorded in the run history")
PY
  then :; else problems="$problems
        | the describe run's record is wrong (diagnostic above)" ; fi

  # A FAILED run must not be archived, because its artifacts cannot be told apart from output a previous
  # run left at the fixed paths. Archiving on "the file exists" filed the first run's description.md
  # under the failed second run (found by reviewing this change with the tool). The fixed path itself is
  # cleared before the launch, so nothing stale is left there to be mistaken for this run's output.
  printf '#!/bin/sh\ncat >/dev/null\nexit 3\n' > "$fake/pr-agent"
  chmod +x "$fake/pr-agent"
  before="$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')"
  rc=0; out="$(run describe)" || rc=$?
  [ "$rc" != 0 ] || problems="$problems
        | a failing describe exited 0"
  [ "$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')" = "$before" ] || problems="$problems
        | a FAILED run was archived, so it was credited with the previous run's description.md"
  # A well-formed agent that exits non-zero AFTER writing the artifact: the output exists and is fresh,
  # but the run did not succeed. This is the case an "the file exists" guard still misses even when
  # nothing stale is involved, so it is what makes `run_ok` the deciding condition rather than a
  # belt-and-braces check.
  printf '#!/bin/sh\ncat >/dev/null\nwhile [ $# -gt 0 ]; do case "$1" in --output) o="$2"; shift 2;; *) shift;; esac; done\n[ -n "$o" ] && printf "partial\\n" > "$o"\nexit 4\n' > "$fake/pr-agent"
  chmod +x "$fake/pr-agent"
  rc=0; out="$(run describe)" || rc=$?
  [ "$rc" != 0 ] || problems="$problems
        | a describe that exited non-zero after writing its artifact exited 0"
  [ "$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')" = "$before" ] || problems="$problems
        | a run that wrote an artifact but FAILED was still archived"
  agent_ok

  # A well-formed agent that exits 0 without writing anything - an empty diff, or an agent that silently
  # produces nothing. The run succeeded, so `run_ok` is set, and only the pre-launch removal of the
  # output path keeps it from archiving the PREVIOUS run's file as its own. Without that removal this
  # filed the earlier run's description.md under a run that never wrote it (found by reviewing this
  # change with the tool).
  printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$fake/pr-agent"
  chmod +x "$fake/pr-agent"
  before="$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')"
  rc=0; out="$(run describe)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | a describe whose agent wrote nothing failed (exit $rc): $out"
  [ "$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')" = "$before" ] || problems="$problems
        | a successful run that wrote NOTHING archived the previous run's artifact as its own"
  [ ! -f "$d/.preflight/description.md" ] || problems="$problems
        | a run that wrote nothing left the previous run's description.md at the fixed path"
  agent_ok

  # A run that produces nothing leaves nothing: an empty directory would read as a run whose artifacts
  # went missing rather than as one that never wrote any.
  local before after
  before="$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')"
  printf '#!/bin/sh\nexec sleep 600\n' > "$fake/pr-agent"; chmod +x "$fake/pr-agent"
  rc=0; out="$( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" FAKE_SEQ="$work/history-seq" \
                 PREFLIGHT_REVIEW_WAIT=2 PREFLIGHT_SHUTDOWN_WAIT=2 \
                 bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  [ "$rc" != 0 ] || problems="$problems
        | a run that wrote nothing exited 0"
  after="$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$before" = "$after" ] || problems="$problems
        | a run that produced no artifact still left a run directory behind"

  # Without python3 there can be no run.json, so there must be no run directory either - otherwise
  # `cat .preflight/runs/*/run.json` (the documented way to read the history) fails for that entry, and
  # the warning claiming the run "was not recorded" is contradicted by a directory that exists (found by
  # reviewing this change with the tool).
  #
  # Two things about the fixture matter, and both were wrong in the first version:
  #   - the PATH must be the REAL one minus python3, not a stub directory with a binary or two in it.
  #     With almost nothing on PATH the helper fails long before the archive, so the assertion would
  #     pass against the very bug it is for.
  #   - `$fake` must come FIRST, or the real `pr-agent` on the inherited PATH is what runs, which needs
  #     a key and a network and breaks this case's whole premise.
  # `python3.13` is excluded by the glob, which is the name a venv or a `uv` install actually puts there.
  agent_ok
  local nopy="$work/history-nopy" dir entry
  mkdir -p "$nopy"
  local IFS=':'
  for dir in $PATH; do
    [ -d "$dir" ] || continue
    for entry in "$dir"/*; do
      [ -x "$entry" ] && [ ! -d "$entry" ] || continue
      case "${entry##*/}" in python3*) continue ;; esac
      ln -sf "$entry" "$nopy/${entry##*/}" 2>/dev/null || true
    done
  done
  unset IFS
  # The stub LAST, so it wins over any real pr-agent the loop above linked in.
  ln -sf "$fake/pr-agent" "$nopy/pr-agent"
  [ ! -e "$nopy/python3" ] || problems="$problems
        | the fixture still has python3 on PATH, so the case would not exercise the missing-python3 path"
  before="$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')"
  ( cd "$d" && env PATH="$nopy" PREFLIGHT_HOME="$cfg" \
      bash "$repo_root/src/preflight-code" describe ) >/dev/null 2>&1 || true
  after="$(ls -1 "$d/.preflight/runs" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$before" = "$after" ] || problems="$problems
        | without python3 a run directory was left behind with no run.json in it"

  # A bookkeeping failure must not leave a run directory with no run.json - the documented
  # `cat .preflight/runs/*/run.json` would fail for it, and the failure would otherwise be silent
  # (found by reviewing this change with the tool).
  #
  # A `python3` that exists but fails is what exercises the branch. The previous fixture made
  # PREFLIGHT_DIR read-only instead, which was vacuous in two ways: `mkdir -p "$run_dir"` still succeeds
  # under an already-created writable `runs/`, and the stub cannot write its artifact at all, so the case
  # exited through the "nothing to archive" path and the write-failure branch was never reached.
  # A python3 that fails ONLY when asked to write the record. A blanket `exit 1` no longer reaches this
  # branch: the model configuration is rendered with python3 first, so a broken interpreter refuses the run
  # before there is anything to archive - which is correct, and a different failure from this one.
  agent_ok
  local badpy="$work/history-badpy"
  mkdir -p "$badpy"
  # The shim fails only on the ARCHIVE write and delegates everything else to the real interpreter, by
  # absolute path: `env -u PATH python3` cannot find it, which would break the render instead of the
  # archive and test the wrong branch.
  _real_py="$(command -v python3)"
  cat > "$badpy/python3" <<BADPY
#!/bin/sh
for a in "\$@"; do
  case "\$a" in *run.json) exit 1 ;; esac
done
# The real interpreter, resolved at TEST time and substituted in, so the shim works on any machine rather
# than only the one it was written on. `command -v` inside the shim would find itself.
exec $_real_py "\$@"
BADPY
  chmod +x "$badpy/python3"
  out="$( cd "$d" && PATH="$badpy:$fake:$PATH" PREFLIGHT_HOME="$cfg" FAKE_SEQ="$work/history-seq" \
            bash "$repo_root/src/preflight-code" describe 2>&1 )" || true
  printf '%s' "$out" | grep -q 'could not write' || problems="$problems
        | an unrecordable run did not say so; silence here is the failure mode this branch exists for"
  for entry in "$d"/.preflight/runs/*/; do
    [ -f "${entry}run.json" ] || problems="$problems
        | ${entry}holds artifacts but no run.json, so the documented cat of every run.json fails"
  done

  mkdir -p "$work/history-blocked"
  printf 'not a directory\n' > "$work/history-blocked/runs"
  # A run directory that cannot be CREATED must warn too, for the same reason: a silently incomplete
  # history is indistinguishable from a complete one. `runs` as a regular file is the simplest way to
  # make `mkdir -p "$run_dir"` fail, and it also proves the run itself still succeeds (found by reviewing
  # this change with the tool).
  out="$( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" FAKE_SEQ="$work/history-seq" \
            PREFLIGHT_DIR="$work/history-blocked" bash "$repo_root/src/preflight-code" review 2>&1 )" || true
  printf '%s' "$out" | grep -q 'could not create' || problems="$problems
        | a run that could not create its run directory was dropped from the history in silence"

  # The sidecar is the one artifact with a fixed name rather than deriving from the command, and it is
  # never removed before the launch (only review's two artifacts are). So its pre-WRITE removal is what
  # keeps a failed write from leaving the previous run's sidecar at the fixed path for archive_run to
  # file - which would leave run.json recording THIS run's verdict beside a file holding the older one.
  # A python3 shim that fails only on the sidecar path is the only way to reach that branch (found by
  # reviewing this change with the tool).
  agent_ok
  local shim="$work/history-shim" realpy
  realpy="$(command -v python3)"
  mkdir -p "$shim"
  # Matched on the SECOND argument, which is the path the helper passes to every `python3 - <path> ...`
  # call. Matching the whole argument list instead trips on the ARCHIVE call too, because the artifact
  # list it is handed contains the sidecar's name - so the run's own run.json write failed and the
  # assertion fired for a reason unrelated to provenance.
  #
  # The real interpreter must be an ABSOLUTE path: `exec python3 ...` inside the shim would resolve to
  # the shim itself, which sits first on the PATH this fixture builds, and recurse until it dies.
  cat > "$shim/python3" <<SHIM
#!/bin/sh
case "\$2" in *review.meta.json) exit 1 ;; esac
exec "$realpy" "\$@"
SHIM
  chmod +x "$shim/python3"
  # The fixture is only meaningful if the shim passes everything except the sidecar write through, so
  # prove it before relying on it: a shim that failed every call would leave the shim run with no archive
  # at all, and the assertion below would pass for the wrong reason.
  "$shim/python3" -c 'print("ok")' 2>/dev/null | grep -q '^ok$' || problems="$problems
        | the python3 shim does not pass non-sidecar calls through, so the probe proves nothing"
  # A review first, so a real sidecar exists to be wrongly inherited.
  rc=0; out="$( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" FAKE_SEQ="$work/history-seq" \
                 bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | the sidecar probe's setup review failed (exit $rc): $out"
  ls -1 "$d/.preflight/runs" > "$work/history-before-shim.txt" 2>/dev/null || : > "$work/history-before-shim.txt"
  rc=0; out="$( cd "$d" && PATH="$shim:$fake:$PATH" PREFLIGHT_HOME="$cfg" \
                 bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  # Only the run this invocation added is inspected, and by IDENTITY rather than by position: run ids are
  # `<UTC second>-<pid>` with an unpadded pid, so two runs in the same second can sort either way and
  # "the last entry" is not reliably the one under test.
  out="$(python3 - "$d/.preflight/runs" "$work/history-before-shim.txt" <<'PY'
import json, os, sys
runs, before_path = sys.argv[1:3]
before = set(open(before_path).read().split())
new = [n for n in sorted(os.listdir(runs)) if n not in before]
if len(new) != 1:
    print("expected exactly one new run directory, found %d" % len(new))
    raise SystemExit
path = os.path.join(runs, new[0], "run.json")
if not os.path.isfile(path):
    print("the new run directory holds no run.json, so its record cannot be checked")
    raise SystemExit
record = json.load(open(path))
if "review.meta.json" in (record.get("artifacts") or []):
    print("the run whose sidecar write failed inherited the previous review's review.meta.json")
if os.path.exists(os.path.join(runs, new[0], "review.meta.json")):
    print("the run whose sidecar write failed left a sidecar in its archive")
PY
)"
  [ -z "$out" ] || problems="$problems
        | $out"

  if [ -z "$problems" ]; then ok "every successful run is kept with its start, finish and duration" "REQ-HOOK-41"
  else bad "every successful run is kept with its start, finish and duration" "REQ-HOOK-41" \
        "two run dirs after two runs, the first intact, describe and review archived, nothing for a failed or empty run" "see below" "$problems
"; fi
}

# ---------------------------------------------------------------------------- bundle hygiene

case_bundle_hooks_executable() {
  # Git IGNORES a hook file that is not marked executable - it prints a hint and runs nothing - so a
  # `.githooks/pre-commit` committed without its executable bit enforces nothing at all. Verified
  # directly: in a clone of a repo whose hooks are mode 100644, an unreviewed commit exits 0.
  #
  # `cp` preserves the source mode, so the documented recipe works on a machine where the bundle was
  # installed - but the committed mode is what a FRESH CLONE obeys, and the source file is one editor or
  # patch away from losing its bit. install.sh already guards this for its own copies (`install -m 0755`,
  # which is why the recipe tells people to copy the INSTALLED hooks rather than the repo's); this check
  # guards the repo's shipped files at the source, where a chmod cannot be undone by a patch tool.
  local f mode problems="" index_note=''
  # The INDEX half needs $repo_root to be a git working tree. A source tarball or a "Download ZIP" has
  # no .git, and `ls-files` there returns nothing - which this case would otherwise read as "not tracked"
  # and report as a defect, when the files are present and fine. Every other case stays inside a temp repo
  # it creates, so this is the suite's only dependence on the source tree being a repo.
  #
  # `core.fileMode=false` is deliberately NOT treated as a reason to skip: that setting governs what
  # `git add` writes, not what the index already holds, so `ls-files -s` reports the committed mode
  # either way. Only the recipe (which does the `add`) has to compensate, with `update-index --chmod=+x`.
  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    index_note="not a git working tree, so the committed mode could not be checked"
  fi
  for f in src/githooks/pre-commit src/githooks/post-commit; do
    [ -f "$repo_root/$f" ] || { problems="$problems
        | $f is missing"; continue; }
    [ -x "$repo_root/$f" ] || problems="$problems
        | $f is not executable on disk, so a repo that copied it would have a hook git ignores"
    [ -n "$index_note" ] && continue
    # The mode in the INDEX is what the commit will carry, and what a clone will check out.
    mode="$(git -C "$repo_root" ls-files -s -- "$f" 2>/dev/null | awk '{print $1}' | head -1)"
    case "$mode" in
      100755) ;;
      100644) problems="$problems
        | $f is committed mode 100644; a fresh clone would not execute it and would enforce nothing" ;;
      '') problems="$problems
        | $f is not tracked by git at all, so it would not be in the commit" ;;
      *) problems="$problems
        | $f is committed with unexpected mode $mode" ;;
    esac
  done
  if [ -n "$problems" ]; then
    bad "the shipped git hooks are executable, on disk and in the index" "REQ-HOOK-36" \
        "src/githooks/* executable on disk and committed as 100755" "see below" "$problems
"
  elif [ -n "$index_note" ]; then
    skip "the shipped git hooks are executable, on disk and in the index" "REQ-HOOK-36" \
         "on disk: yes; committed mode: $index_note"
  else
    ok "the shipped git hooks are executable, on disk and in the index" "REQ-HOOK-36"
  fi
}

case_gate_doc_advisory() {
  # pr-agent's finding schema has no severity field, so before this the gate failed on any finding.
  # A finding on documentation therefore blocked a commit as hard as a bug in the hook. The gate now
  # derives a tier from the finding's FILE TYPE (its extension, wherever the file lives) and treats a
  # prose format as advisory: reported, but not fatal, unless `PREFLIGHT_GATE_DOC_BLOCKS=1` asks for
  # the strict behaviour.
  #
  # The trap this case is built around is the path itself. `relevant_file` arrives with a trailing
  # newline (`'README.md\n'`), so a naive `endswith('.md')` reports every documentation finding as code
  # and the advisory tier never fires. A doc path and a code path are each therefore driven through a
  # real gate run, and the doc run additionally pins the blocking/advisory SPLIT rather than only the
  # verdict, so a regression that classified everything the same way cannot pass.
  local d doc code problems="" out rc boundary
  d="$work/gate-tier"; mkdir -p "$d/.preflight"
  # A scratch PREFLIGHT_HOME, because the gate reads [gate] from $PREFLIGHT_HOME/settings.toml when that
  # file exists, and a developer machine has one. Without this the case would depend on the developer's
  # machine state - a home policy that narrowed or widened doc_suffixes would flip the expected exit codes.
  #
  # Scoped to the `bash` invocations below rather than exported: a case function runs in the top-level
  # shell, so an exported PREFLIGHT_HOME would leak into every later case - including the live one,
  # which resolves the installed helpers through ${PREFLIGHT_HOME:-$HOME/.config/preflight}.
  local tier_home="$work/gate-tier-home"
  mkdir -p "$tier_home"
  doc='{"review":{"key_issues_to_review":[{"relevant_file":"README.md\n","issue_header":"typo","issue_content":"c"}],"security_concerns":"No"}}'
  code='{"review":{"key_issues_to_review":[{"relevant_file":"src/preflight\n","issue_header":"bug","issue_content":"c"}],"security_concerns":"No"}}'

  gate_run() { ( cd "$d" && PREFLIGHT_HOME="$tier_home" PREFLIGHT_DIR=.preflight bash "$repo_root/src/preflight-gate" ); }

  printf '%s' "$doc" > "$d/.preflight/review.json"
  rc=0; out="$(gate_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | a finding on README.md failed the gate (exit $rc): $out"
  case "$out" in *"advisory=1"*) ;; *) problems="$problems
        | the doc finding was not counted as advisory (the trailing-newline path trap): $out" ;; esac
  # `blocking=0` and the `[advisory]` tag together pin the SPLIT and the label. Asserting a bare
  # `blocking=1` would be dead: a doc-only review prints `blocking=0 advisory=1`, and a misclassified
  # finding prints no count at all, so neither ever contains the string `blocking=1`.
  case "$out" in *"blocking=0"*) ;; *) problems="$problems
        | the doc finding was not counted in a blocking/advisory split: $out" ;; esac
  case "$out" in *"[advisory]"*) ;; *) problems="$problems
        | the doc finding was not tagged [advisory]: $out" ;; esac

  printf '%s' "$code" > "$d/.preflight/review.json"
  rc=0; out="$(gate_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | a finding on code still failed with exit $rc, expected 1: $out"
  case "$out" in *"[blocking]"*) ;; *) problems="$problems
        | the code finding was not tagged blocking: $out" ;; esac
  case "$out" in *"advisory="*) problems="$problems
        | the code finding was counted as advisory, so real bugs no longer block: $out" ;; esac

  printf '%s' "$doc" > "$d/.preflight/review.json"
  rc=0
  out="$( cd "$d" && PREFLIGHT_HOME="$tier_home" PREFLIGHT_DIR=.preflight PREFLIGHT_GATE_DOC_BLOCKS=1 bash "$repo_root/src/preflight-gate" 2>&1 )" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | PREFLIGHT_GATE_DOC_BLOCKS=1 still passed (exit $rc): $out"
  case "$out" in *"[blocking]"*) ;; *) problems="$problems
        | in strict mode a promoted doc finding was still labelled advisory, contradicting the exit code: $out" ;; esac

  # The rule is a FILE-TYPE rule, so it holds wherever the file lives: a `.md` under `docs/` is
  # advisory, but content that happens to sit in `docs/` but is not prose keeps blocking - a
  # `conf.py`, a build script, an `.mdx` (Markdown plus executable JSX), or a `requirements.txt`.
  # The tier therefore cannot be defeated by the directory a file sits in, nor by a prose-looking name.
  boundary='{"review":{"key_issues_to_review":[{"relevant_file":"docs/README.md","issue_header":"x","issue_content":"c"},{"relevant_file":"docs/conf.py","issue_header":"y","issue_content":"c"},{"relevant_file":"requirements.txt","issue_header":"z","issue_content":"c"},{"relevant_file":"docs/component.mdx","issue_header":"w","issue_content":"c"}],"security_concerns":"No"}}'
  printf '%s' "$boundary" > "$d/.preflight/review.json"
  rc=0; out="$(gate_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | code under docs/, a requirements.txt or an .mdx should still block, but the gate passed (exit $rc): $out"
  case "$out" in *"blocking=3 advisory=1"*) ;; *) problems="$problems
        | the tier was not split by file type (.txt and .mdx must block alongside .py): $out" ;; esac

  if [ -z "$problems" ]; then ok "documentation findings are advisory, code findings block" "REQ-HOOK-38"
  else bad "documentation findings are advisory, code findings block" "REQ-HOOK-38" \
        "doc=pass(split), code=exit 1, strict=exit 1" "see below" "$problems
"; fi
}

case_gate_config() {
  # The gate's tunables come from a [gate] table - in the machine's settings.toml, then in a repo-local
  # `.preflight.toml` override - with the environment on top, so a repo whose docs differ can say so
  # without a one-off variable, and a one-off can still win without editing a file. What this case pins is
  # the PRECEDENCE and the degradation: the suffix list is what actually decides a verdict, so a config
  # that silently failed to load would leave a repo believing its policy was in force.
  #
  # It also pins the two failure modes that matter: a malformed file must WARN and fall back rather than
  # crash (a crash is a non-zero exit, which the commit hook reads as "the review did not pass"), and an
  # unknown/absent key must keep the built-in default rather than disabling a check.
  local d home problems="" out rc key home_line repo_line review want
  local FINDING_FOO FINDING_PY FINDING_EFFORT_5
  d="$work/gate-config"; home="$work/gate-config-home"
  mkdir -p "$d/.preflight" "$home"
  # A real repository: the gate resolves the repo-local file at the repository ROOT, so a bare directory
  # would only exercise the cwd fallback (and the subdirectory assertion below would pass for the wrong
  # reason - or fail, as it did when this fixture was added before the init).
  ( cd "$d" && git init -q . ) >/dev/null 2>&1

  # One finding per tier/field, so a table row can name the shape it needs.
  FINDING_FOO='{"review":{"key_issues_to_review":[{"relevant_file":"notes.foo","issue_header":"h","issue_content":"c"}],"security_concerns":"No"}}'
  FINDING_PY='{"review":{"key_issues_to_review":[{"relevant_file":"a.py","issue_header":"h","issue_content":"c"}],"security_concerns":"No"}}'
  FINDING_EFFORT_5='{"review":{"key_issues_to_review":[],"security_concerns":"No","estimated_effort_to_review_[1-5]":5}}'

  gate_cfg_run() { ( cd "$d" && PREFLIGHT_HOME="$home" PREFLIGHT_DIR=.preflight "$@" bash "$repo_root/src/preflight-gate" ); }

  # Home config narrows documentation to `.foo`, so a `.md` finding blocks and a `.foo` one does not. The
  # [gate] table sits BESIDE the review's own sections, in the same file: a [pr_reviewer] key there is not
  # an unknown gate key, and the gate must not warn about it.
  printf '[pr_reviewer]\nnum_max_findings = 3\n\n[gate]\ndoc_suffixes = [".foo"]\n' > "$home/settings.toml"
  printf '%s' '{"review":{"key_issues_to_review":[{"relevant_file":"README.md","issue_header":"h","issue_content":"c"}],"security_concerns":"No","estimated_effort_to_review_[1-5]":3}}' > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | the home [gate] did not take effect: a .md finding should have blocked (exit $rc): $out"
  case "$out" in *"unknown key"*) problems="$problems
        | the gate reported the review's own settings as unknown keys: $out" ;; esac

  printf '%s' '{"review":{"key_issues_to_review":[{"relevant_file":"notes.foo","issue_header":"h","issue_content":"c"}],"security_concerns":"No","estimated_effort_to_review_[1-5]":3}}' > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | a suffix from doc_suffixes was not treated as advisory (exit $rc): $out"

  # Effort is REPORTED, never enforced: a high estimate is the model's own number, not a property of the
  # change, so it must not decide the verdict. A [gate] key no longer read is still reported rather than
  # silently ignored, because a policy that looks in force while nothing applies it is the failure this
  # whole case guards.
  printf '[gate]\ndoc_suffixes = [".foo"]\n' > "$home/settings.toml"
  printf '%s' '{"review":{"key_issues_to_review":[],"security_concerns":"No","estimated_effort_to_review_[1-5]":5,"merge_recommendation":"changes_required"}}' > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | effort or merge_recommendation still decided the verdict (exit $rc): $out"
  case "$out" in *"merge="*) problems="$problems
        | the merged recommendation is still on the gate's summary line: $out" ;; esac

  # A key the gate no longer reads is REPORTED rather than ignored: a retired max_effort left in [gate]
  # is a policy that looks in force while nothing applies it, which is the failure this case guards.
  printf '[gate]\nmax_effort = 4\n' > "$home/settings.toml"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  case "$out" in *"unknown key 'max_effort'"*) ;; *) problems="$problems
        | a retired max_effort in [gate] was not reported as an unknown key: $out" ;; esac

  # The repo-local .preflight.toml overrides the home file. The home policy is RESTATED first, and the
  # assertion is driven in both directions: with `.foo` alone, `.md` blocks; with the repo file widening
  # it to `.md`, it does not. Without the restatement the home file is whatever the blocks above left, and
  # `.md` is advisory by the built-in default - so the run would pass whether or not the repo file was read.
  printf '[gate]\ndoc_suffixes = [".foo"]\n' > "$home/settings.toml"
  printf '%s' '{"review":{"key_issues_to_review":[{"relevant_file":"README.md","issue_header":"h","issue_content":"c"}],"security_concerns":"No","estimated_effort_to_review_[1-5]":3}}' > "$d/.preflight/review.json"
  rm -f "$d/.preflight.toml"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | with no repo-local file, the home doc_suffixes did not make .md block (exit $rc): $out"
  printf '[gate]\ndoc_suffixes = [".md"]\n' > "$d/.preflight.toml"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | the repo-local .preflight.toml did not override the home doc_suffixes (exit $rc): $out"

  # The environment overrides both files.
  rc=0; out="$(PREFLIGHT_GATE_DOC_BLOCKS=1 gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | PREFLIGHT_GATE_DOC_BLOCKS=1 did not override the config files (exit $rc): $out"

  # A bare `1` is a natural mirror of the env var, and TOML parses it as an int. Falling back to the
  # default (False, permissive) would leave the writer believing the gate was strict.
  printf '[gate]\ndoc_suffixes = [".foo"]\ndoc_blocks = 1\n' > "$d/.preflight.toml"
  printf '%s' '{"review":{"key_issues_to_review":[{"relevant_file":"notes.foo","issue_header":"h","issue_content":"c"}],"security_concerns":"No"}}' > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | doc_blocks = 1 (a TOML integer) did not make documentation block (exit $rc): $out"

  # Malformed TOML: warn, fall back to the home file, never crash. A crash is a non-zero exit, which
  # the commit hook reads as "the review did not pass". The home file is restated because the blocks
  # above replaced it, and this assertion is about the FALLBACK, not about whatever was left behind.
  printf '[gate]\ndoc_suffixes = [".foo"]\n' > "$home/settings.toml"
  printf '[gate]\nnot = = toml\n' > "$d/.preflight.toml"
  printf '%s' "$FINDING_FOO" > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | a malformed config file should fall back to the home policy (exit $rc): $out"
  case "$out" in *"warning"*) ;; *) problems="$problems
        | a malformed config file was ignored silently: $out" ;; esac
  case "$out" in *Traceback*) problems="$problems
        | a malformed config file crashed the gate: $out" ;; esac

  # Present but unreadable. A directory in the file's place is the portable way to produce that: a
  # permissions test would pass under root, which ignores the mode bits.
  rm -rf "$d/.preflight.toml"; mkdir -p "$d/.preflight.toml"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  case "$out" in *"warning"*) ;; *) problems="$problems
        | an unreadable config was ignored silently: $out" ;; esac
  [ "$rc" = 0 ] || problems="$problems
        | an unreadable config should fall back to the home policy (exit $rc): $out"
  rmdir "$d/.preflight.toml" 2>/dev/null || true

  # The retired PREFLIGHT_GATE_MAX_EFFORT is inert, in both directions: it must not restore a ceiling the
  # gate deliberately dropped, and an unparseable value must not fail the run either.
  printf '[gate]\ndoc_suffixes = [".foo"]\n' > "$home/settings.toml"
  printf '%s' "$FINDING_EFFORT_5" > "$d/.preflight/review.json"
  rc=0; out="$(PREFLIGHT_GATE_MAX_EFFORT=2 gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | the retired PREFLIGHT_GATE_MAX_EFFORT still failed an over-limit effort (exit $rc): $out"
  rc=0; out="$(PREFLIGHT_GATE_MAX_EFFORT=abc gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | an unparseable PREFLIGHT_GATE_MAX_EFFORT failed the run (exit $rc): $out"


  # THE CLASS, as a table: for every key, an invalid value must be REPORTED and must leave the value
  # already in force exactly as it was. Each row's home line is chosen so the two failure modes give a
  # different exit code - "kept the home value" vs "dropped the key and fell back to the built-in
  # default" - which is what makes a row a real assertion rather than a repeat of the default. A new
  # key needs a row here, not another bespoke assertion; that per-key patchwork is what let this class
  # recur once per key.
  #
  # Columns: key | home policy | repo-local policy | review | expected exit
  while IFS='|' read -r key home_line repo_line review want; do
    [ -n "$key" ] || continue
    # A leading `+` continues the line on the PREVIOUS one, as `\n` does in a format string: the table
    # rows below stay one physical line each, and a multi-key policy is still expressible.
    printf '[gate]\n%b\n' "$(printf '%s' "$home_line" | tr '+' '\n')" > "$home/settings.toml"
    printf '[gate]\n%b\n' "$(printf '%s' "$repo_line" | tr '+' '\n')" > "$d/.preflight.toml"
    printf '%s' "$review" > "$d/.preflight/review.json"
    rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
    case "$out" in
      *"ignoring $key"*) ;;
      *) problems="$problems
        | an invalid $key was not reported as ignored [$repo_line]: $out" ;;
    esac
    [ "$rc" = "$want" ] || problems="$problems
        | an invalid $key changed the outcome [$repo_line]: got exit $rc, expected $want (the value already in force was not kept): $out"
    case "$out" in *Traceback*) problems="$problems
        | an invalid $key crashed the gate [$repo_line]: $out" ;; esac
  done <<EOF
doc_suffixes|doc_suffixes = [".foo"]|doc_suffixes = [""]|$FINDING_PY|1
doc_suffixes|doc_suffixes = [".foo"]|doc_suffixes = 5|$FINDING_FOO|0
doc_suffixes|doc_suffixes = [".foo"]|doc_suffixes = [""]|$FINDING_FOO|0
doc_suffixes|doc_suffixes = [".foo"]|doc_suffixes = [".md", 1]|$FINDING_PY|1
doc_suffixes|doc_suffixes = [".foo"]|doc_suffixes = ["../x"]|$FINDING_PY|1
doc_suffixes|doc_suffixes = [".foo"]|doc_suffixes = ["."]|$FINDING_PY|1
doc_blocks|doc_suffixes = [".foo"]+doc_blocks = true|doc_blocks = "ture"|$FINDING_FOO|1
allow_issues|doc_suffixes = [".foo"]+allow_issues = true|allow_issues = "maybe"|$FINDING_PY|0
allow_issues|doc_suffixes = [".foo"]+allow_issues = true|allow_issues = 2|$FINDING_PY|0
allow_issues|doc_suffixes = [".foo"]+allow_issues = false|allow_issues = 2|$FINDING_PY|1
allow_issues|doc_suffixes = [".foo"]+allow_issues = false|allow_issues = -1|$FINDING_PY|1
EOF

  # A suffix without a leading dot is NORMALISED, not matched raw: `endswith("txt")` would also match
  # `notes.baktxt`, which is broader than the extension the writer meant. `.txt` blocks here precisely
  # because it is not a `.txt`.
  printf '[gate]\ndoc_suffixes = [".md"]\n' > "$home/settings.toml"
  printf '[gate]\ndoc_suffixes = ["txt"]\n' > "$d/.preflight.toml"
  printf '%s' '{"review":{"key_issues_to_review":[{"relevant_file":"notes.baktxt","issue_header":"h","issue_content":"c"}],"security_concerns":"No"}}' > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | a dotless suffix was matched raw instead of normalised, so notes.baktxt became advisory (exit $rc): $out"
  case "$out" in *"leading dot"*) ;; *) problems="$problems
        | normalising a suffix was not reported: $out" ;; esac

  # A path fragment is not an extension: `endswith('docs/')` would match anything under a directory of
  # that name, which is not "this file type". Rejected, so the home value stands.
  printf '[gate]\ndoc_suffixes = [".foo"]\n' > "$home/settings.toml"
  printf '[gate]\ndoc_suffixes = ["docs/"]\n' > "$d/.preflight.toml"
  printf '%s' "$FINDING_FOO" > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | a path fragment in doc_suffixes was accepted instead of rejected (exit $rc): $out"
  case "$out" in *"is not a file extension"*) ;; *) problems="$problems
        | a path fragment in doc_suffixes was not reported: $out" ;; esac

  # An empty entry invalidates the WHOLE list rather than being dropped with the rest applied: a list
  # the writer got wrong is one value, and partially honouring it is the silent difference this rule
  # exists to avoid. The home value must therefore survive a list that also contains a valid entry.
  printf '[gate]\ndoc_suffixes = [".foo"]\n' > "$home/settings.toml"
  printf '[gate]\ndoc_suffixes = [".md", ""]\n' > "$d/.preflight.toml"
  printf '%s' "$FINDING_FOO" > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | a partly-invalid doc_suffixes list was applied instead of keeping the home value (exit $rc): $out"
  case "$out" in *"empty entry"*) ;; *) problems="$problems
        | an empty suffix entry alongside valid ones was not reported: $out" ;; esac

  # Waiving key issues must not leave the finding labelled as if it still blocked: the label and the
  # exit code have to agree, which is the same rule the doc_blocks override follows.
  rm -f "$home/settings.toml"
  printf '[gate]\ndoc_suffixes = [".md"]\nallow_issues = true\n' > "$d/.preflight.toml"
  printf '%s' "$FINDING_PY" > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | allow_issues = true did not waive a key issue (exit $rc): $out"
  case "$out" in *"[waived]"*) ;; *) problems="$problems
        | a waived finding was still labelled as blocking, contradicting the exit code: $out" ;; esac
  case "$out" in *"waived (allow_issues)"*) ;; *) problems="$problems
        | a waiver was not reported, so PASS gave no sign a finding was discarded: $out" ;; esac

  # An unknown key is reported too: a typo'd key name is how a policy looks configured while doing
  # nothing, and it has no validator to inherit the rule from.
  printf '[gate]\ndoc_block = true\n' > "$d/.preflight.toml"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  case "$out" in *"unknown key"*) ;; *) problems="$problems
        | an unknown config key was not reported: $out" ;; esac

  # With no config files at all, the built-in defaults make a .md advisory and a code finding block.
  rm -f "$home/settings.toml" "$d/.preflight.toml"

  # The files the policy lived in before it moved into [gate] are NOT read, and a keyed one is reported by
  # name. An inert one is silent: that is exactly what the old install wrote, so nothing was lost.
  #
  # The retired value DIFFERS from the one in [gate], and that is what makes the assertion discriminating:
  # when both files said `allow_issues = true`, a regression that read the retired file merged the same
  # value the [gate] table already had, so the verdict was unchanged and the case stayed green.
  printf 'allow_issues = true\n' > "$home/gate.toml"
  printf '[gate]\ndoc_suffixes = [".md"]\n' > "$home/settings.toml"
  printf '%s' "$FINDING_PY" > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | a retired gate.toml was applied over [gate] (exit $rc, want 1: its allow_issues=true only wins if the file is read): $out"
  case "$out" in *"no longer read"*) ;; *) problems="$problems
        | a retired gate.toml that sets keys was not reported: $out" ;; esac
  printf '# every key commented out, as the old install wrote it\n' > "$home/gate.toml"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  case "$out" in *"no longer read"*) problems="$problems
        | an inert retired gate.toml was reported, though it lost no policy: $out" ;; esac
  rm -f "$home/gate.toml"

  # The REPO-LOCAL retired file is reported too, and from the same repository-root resolution as
  # `.preflight.toml` (both paths come from `_retired_files()`). The value again differs from [gate], so
  # the verdict would move if it were read.
  rm -f "$home/gate.toml"
  printf '[gate]\ndoc_suffixes = [".md"]\n' > "$home/settings.toml"
  printf 'allow_issues = true\n' > "$d/.preflight-gate.toml"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | a retired .preflight-gate.toml was applied over [gate] (exit $rc, want 1): $out"
  case "$out" in *".preflight-gate.toml"*"no longer read"*) ;; *) problems="$problems
        | a retired repo-local .preflight-gate.toml that sets keys was not reported by name: $out" ;; esac
  rm -f "$d/.preflight-gate.toml"

  # A [pr_reviewer] key beside [gate] is the review's, not a typo in the gate's: the gate reads ONLY the
  # [gate] table, so it must not warn about the rest of the file it shares.
  printf '[pr_reviewer]\nnum_max_findings = 3\n\n[gate]\ndoc_suffixes = [".foo"]\n' > "$home/settings.toml"
  printf '%s' "$FINDING_PY" > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  case "$out" in *"unknown key"*) problems="$problems
        | the gate reported the review's [pr_reviewer] keys as unknown gate keys: $out" ;; esac
  [ "$rc" = 1 ] || problems="$problems
        | a code finding no longer blocked beside a valid [gate] table (exit $rc): $out"
  rm -f "$home/settings.toml"

  # The repository file is resolved at the repository ROOT, so a gate invocation from a subdirectory
  # (where a pre-commit hook or an agent may run it) reads the same policy. A cwd-relative lookup would
  # silently fall back to the machine's defaults there, which is the "policy never loaded" failure this
  # case exists to catch - and it would be invisible, because the verdict is still a verdict.
  printf '[gate]\ndoc_blocks = true\n' > "$d/.preflight.toml"
  printf '%s' '{"review":{"key_issues_to_review":[{"relevant_file":"README.md","issue_header":"h","issue_content":"c"}],"security_concerns":"No"}}' > "$d/.preflight/review.json"
  mkdir -p "$d/nested"
  rc=0; out="$( cd "$d/nested" && PREFLIGHT_HOME="$home" PREFLIGHT_DIR="$d/.preflight" \
                bash "$repo_root/src/preflight-gate" "$d/.preflight/review.json" 2>&1 )" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | from a subdirectory, the repo-local .preflight.toml was not read (exit $rc): $out"
  case "$out" in *"[blocking]"*) ;; *) problems="$problems
        | from a subdirectory, the promoted doc finding was not labelled blocking: $out" ;; esac
  rm -rf "$d/nested"; rm -f "$d/.preflight.toml"

  printf '%s' '{"review":{"key_issues_to_review":[{"relevant_file":"README.md","issue_header":"h","issue_content":"c"}],"security_concerns":"No"}}' > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | with no config file, .md should still be advisory (exit $rc): $out"
  printf '%s' '{"review":{"key_issues_to_review":[{"relevant_file":"a.py","issue_header":"h","issue_content":"c"}],"security_concerns":"No"}}' > "$d/.preflight/review.json"
  rc=0; out="$(gate_cfg_run 2>&1)" || rc=$?
  [ "$rc" = 1 ] || problems="$problems
        | with no config file, a code finding should still block (exit $rc): $out"

  if [ -z "$problems" ]; then ok "gate policy is configurable, layered home -> repo -> env" "REQ-HOOK-39"
  else bad "gate policy is configurable, layered home -> repo -> env" "REQ-HOOK-39" \
        "home=blocks .md, repo overrides, env overrides, malformed warns, defaults hold" "see below" "$problems
"; fi
}

case_review_context() {
  # The reviewer needs facts about the repository, so a deliberate trade-off is not reported as a
  # defect. pr-agent carries them through `[artifacts]`, which is the mechanism a plain-diff run can
  # actually reach: its own `repo_context_files` is dead here, because the plain-diff provider
  # implements neither `get_repo_file_content` nor `get_repo_context_ref`.
  #
  # The contract is the extraction, and it has an asymmetry worth guarding: a `Code review` section is
  # sent ALONE, so a long AGENTS.md does not follow the reviewer into the prompt; with no such section
  # the whole file is sent. Both directions are asserted, because a regression that always sent the
  # whole file would look right on a repository that happens to have only the section.
  local d fake got problems="" out rc line
  d="$work/ctx"; fake="$work/ctx-bin"
  mkdir -p "$d" "$fake"
  # Records the artifact path and its contents: what the model was SHOWN is only observable here.
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --json-output) js="$2"; shift 2 ;;
    *) shift ;;
  esac
done
{
  printf 'ARTIFACT_PATH=%s\n' "${ARTIFACT_PATH:-}"
  printf 'ARTIFACT_INSTRUCTIONS=%s\n' "${ARTIFACT_INSTRUCTIONS:-}"
  printf 'ARTIFACT_LABEL=%s\n' "${ARTIFACTS__ARTIFACT_LABEL:-}"
  if [ -n "${ARTIFACT_PATH:-}" ] && [ -f "$ARTIFACT_PATH" ]; then
    printf -- '---\n'
    cat "$ARTIFACT_PATH"
  fi
} > "$CTX_OUT"
[ -n "$js" ] && printf '%s\n' '{"review":{"key_issues_to_review":[],"security_concerns":"No","merge_recommendation":"safe_to_merge"},"usage":{"total_tokens":9}}' > "$js"
[ -n "$out" ] && printf '<table></table>\n' > "$out"
exit 0
FAKE
  chmod +x "$fake/pr-agent"

  ( cd "$d" \
      && git init -q -b main . \
      && printf 'v = 1\n' > tracked.py \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m init ) >/dev/null 2>&1
  git -C "$d" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
    bad "the repository's review context reaches the model" "REQ-HOOK-40" \
        "a seeded repository" "no commit" \
        "the case could not build its fixture, so no context could be extracted"
    return
  }

  # Sentinel lines, not the literal bodies, so a failure names what leaked rather than just failing.
  cat > "$d/AGENTS.md" <<'MD'
# Notes for agents
AGENT_SENTINEL_ONLY

## Code review
REVIEW_SENTINEL_KEPT

### a subsection
REVIEW_SENTINEL_NESTED

## Later section
LATER_SENTINEL_EXCLUDED
MD
  out="$work/ctx.txt"
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" CTX_OUT="$work/ctx.sent" \
      PREFLIGHT_HOME="$work/ctx-cfg" \
      bash "$repo_root/src/preflight-code" review ) >"$out" 2>&1

  got="$(cat "$work/ctx.sent" 2>/dev/null || printf '')"
  # The path is a repo-relative scratch file, so its value is not worth pinning; its PRESENCE is.
  # Read the first line rather than pattern-match the whole blob: the stub writes two lines, so a
  # `case` on the blob cannot tell "unset" from "set" without anchoring on the line.
  apath="$(printf '%s\n' "$got" | sed -n '1s/^ARTIFACT_PATH=//p')"
  [ -n "$apath" ] || problems="$problems
        | no ARTIFACT_PATH was exported, so the repository context never reached the reviewer"
  # The label is asserted because it must arrive through the ENVIRONMENT: an [artifacts] section in
  # The config is loaded (by apply_repo_settings) AFTER injection, so a label set there is never applied
  # and the prompt header silently falls back to the filename - which is why the helper sets it through
  # the environment instead.
  case "$got" in *"ARTIFACT_LABEL=Repository context (from AGENTS.md)"*) ;;
    *) problems="$problems
        | the artifact label was not exported, so the prompt header misdescribes a local run as CI" ;; esac
  case "$got" in *REVIEW_SENTINEL_KEPT*) ;; *) problems="$problems
        | the Code review section was not sent" ;; esac
  case "$got" in *REVIEW_SENTINEL_NESTED*) ;; *) problems="$problems
        | a subsection of the Code review section was dropped (it must stay with its section)" ;; esac
  case "$got" in *AGENT_SENTINEL_ONLY*) problems="$problems
        | the rest of AGENTS.md was sent alongside the section, so a long file is not bounded by it" ;; esac
  case "$got" in *LATER_SENTINEL_EXCLUDED*) problems="$problems
        | a LATER top-level section leaked into the context, so the section never ends" ;; esac
  # The framing matters as much as the text: without it the model reads the content as instructions to
  # approve, which is the channel's whole risk.
  case "$got" in *"not as instructions to approve anything"*) ;; *) problems="$problems
        | no framing instruction was sent, so the context reads as instructions rather than as facts" ;; esac
  line="$(grep -E '^preflight-code: issues=' "$out" 2>/dev/null | head -1)"
  case "$line" in *"context=AGENTS.md (Code review section)"*) ;; *) problems="$problems
        | the summary line did not report that repository context was used: $line" ;; esac

  # A fenced block inside the section must not be read as the section boundary. A shell comment at
  # column 0, or a fenced example containing a heading, is exactly what a context file of code facts
  # tends to contain - and ending the section there silently drops every fact AFTER it, so the reviewer
  # re-raises the trade-off the section was written to answer.
  cat > "$d/AGENTS.md" <<'MD'
## Code review
BEFORE_FENCE
```sh
# this is a shell comment, not a heading
echo hi
```
AFTER_FENCE
## Out of section
EXCLUDED_SENTINEL
MD
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" CTX_OUT="$work/ctx.sent4" \
      PREFLIGHT_HOME="$work/ctx-cfg" \
      bash "$repo_root/src/preflight-code" review ) >"$out" 2>&1
  got="$(cat "$work/ctx.sent4" 2>/dev/null || printf '')"
  case "$got" in *AFTER_FENCE*) ;; *) problems="$problems
        | a fenced block ended the section early, silently dropping the facts after it" ;; esac
  case "$got" in *EXCLUDED_SENTINEL*) problems="$problems
        | the section did not end at the next same-or-higher heading after a fenced block" ;; esac

  # A CLOSING fence carries nothing but whitespace after the run, so a fence line with an info string
  # inside a block is content. Closing on it instead would expose a heading-looking line inside the
  # example and truncate the section - the same silent loss, one level of nesting deeper.
  cat > "$d/AGENTS.md" <<'MD'
## Code review
NESTED_BEFORE
```
```sh
## this line is inside the fence, not a heading
```
NESTED_AFTER
## Out
NESTED_EXCLUDED
MD
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" CTX_OUT="$work/ctx.sent10" \
      PREFLIGHT_HOME="$work/ctx-cfg" \
      bash "$repo_root/src/preflight-code" review ) >"$out" 2>&1
  got="$(cat "$work/ctx.sent10" 2>/dev/null || printf '')"
  case "$got" in *NESTED_AFTER*) ;; *) problems="$problems
        | a tagged fence inside a block ended it early, truncating the section" ;; esac
  case "$got" in *NESTED_EXCLUDED*) problems="$problems
        | the section did not end at the next real heading after a nested fence" ;; esac

  # A bare `#` is a valid EMPTY heading, so the title group is None. Passing that to a regex raises, the
  # extractor exits non-zero, and the `(unreadable)` branch silently disables the whole feature for the
  # repository - a one-line trigger, which is why it is asserted rather than reasoned about.
  cat > "$d/AGENTS.md" <<'MD'
#
## Code review
BARE_HASH_SENTINEL
MD
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" CTX_OUT="$work/ctx.sent8" \
      PREFLIGHT_HOME="$work/ctx-cfg" \
      bash "$repo_root/src/preflight-code" review ) >"$out" 2>&1
  got="$(cat "$work/ctx.sent8" 2>/dev/null || printf '')"
  case "$got" in *BARE_HASH_SENTINEL*) ;; *) problems="$problems
        | a bare `#` line disabled the context entirely instead of being read as an empty heading" ;; esac
  # `(unreadable)` appears only on the SUMMARY line, not in what the stub was handed, so this must read
  # $out - a check against $got could never fire, which is how it survived the first round.
  case "$(grep -E '^preflight-code: issues=' "$out" 2>/dev/null | head -1)" in *"(unreadable)"*) problems="$problems
        | the context file was reported unreadable, so the extractor failed rather than extracting" ;; esac

  # An indented heading is a heading in CommonMark, and the fence scan already allows leading whitespace;
  # column-0 anchoring would make the two disagree, and would send the whole file instead of the section.
  cat > "$d/AGENTS.md" <<'MD'
   ## Code review
INDENTED_SENTINEL
   ## Later
INDENTED_EXCLUDED
MD
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" CTX_OUT="$work/ctx.sent9" \
      PREFLIGHT_HOME="$work/ctx-cfg" \
      bash "$repo_root/src/preflight-code" review ) >"$out" 2>&1
  got="$(cat "$work/ctx.sent9" 2>/dev/null || printf '')"
  case "$got" in *INDENTED_SENTINEL*) ;; *) problems="$problems
        | an indented Code review heading was not recognised" ;; esac
  case "$got" in *INDENTED_EXCLUDED*) problems="$problems
        | an indented later heading did not end the section, so the rest of the file leaked in" ;; esac

  # A column-0 `#` with no following space is NOT a heading in CommonMark. Reading one as a heading
  # ends the section there and silently drops the facts after it - the same truncation the fence check
  # prevents, for code that is not fenced.
  cat > "$d/AGENTS.md" <<'MD'
## Code review
HASH_BEFORE
#!/bin/sh
#hashtag
HASH_AFTER
## Out
HASH_EXCLUDED
MD
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" CTX_OUT="$work/ctx.sent7" \
      PREFLIGHT_HOME="$work/ctx-cfg" \
      bash "$repo_root/src/preflight-code" review ) >"$out" 2>&1
  got="$(cat "$work/ctx.sent7" 2>/dev/null || printf '')"
  case "$got" in *HASH_AFTER*) ;; *) problems="$problems
        | a `#` line with no following space ended the section, dropping the facts after it" ;; esac
  case "$got" in *HASH_EXCLUDED*) problems="$problems
        | the section did not end at the next real heading" ;; esac

  # Resolved against the repository root Hardcoding it made the prompt say "from AGENTS.md"
  # while the summary line said otherwise - two sources disagreeing about the same fact.
  printf '## Code review\nALT_SENTINEL\n' > "$d/ALT.md"
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" CTX_OUT="$work/ctx.sent5" \
      PREFLIGHT_HOME="$work/ctx-cfg" PREFLIGHT_CONTEXT_FILE=ALT.md \
      bash "$repo_root/src/preflight-code" review ) >"$out" 2>&1
  got="$(cat "$work/ctx.sent5" 2>/dev/null || printf '')"
  case "$got" in *"ARTIFACT_LABEL=Repository context (from ALT.md)"*) ;;
    *) problems="$problems
        | the artifact label did not name the file actually used (PREFLIGHT_CONTEXT_FILE=ALT.md)" ;; esac
  case "$got" in *ALT_SENTINEL*) ;; *) problems="$problems
        | the override file's section was not sent" ;; esac

  # With no such section the whole file is sent - the compatibility direction, where an existing
  # AGENTS.md is used as-is rather than being silently ignored.
  printf '# Notes\nWHOLE_SENTINEL\n' > "$d/AGENTS.md"
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" CTX_OUT="$work/ctx.sent2" \
      PREFLIGHT_HOME="$work/ctx-cfg" \
      bash "$repo_root/src/preflight-code" review ) >"$out" 2>&1
  got="$(cat "$work/ctx.sent2" 2>/dev/null || printf '')"
  case "$got" in *WHOLE_SENTINEL*) ;; *) problems="$problems
        | with no Code review section the WHOLE AGENTS.md should be sent, but it was not" ;; esac
  line="$(grep -E '^preflight-code: issues=' "$out" 2>/dev/null | head -1)"
  # An EXCLUSION, because the plain label is a substring of the section label: a positive match would
  # also accept `context=AGENTS.md (Code review section)` and could not tell the two modes apart.
  case "$line" in *"(Code review section)"*) problems="$problems
        | with no Code review heading the section label was still reported: $line" ;; esac
  case "$line" in *"context=AGENTS.md"*) ;; *) problems="$problems
        | the summary line did not report whole-file context: $line" ;; esac

  # No context file at all must leave the run exactly as it was: no artifact, nothing claimed.
  rm -f "$d/AGENTS.md"
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" CTX_OUT="$work/ctx.sent3" \
      PREFLIGHT_HOME="$work/ctx-cfg" \
      bash "$repo_root/src/preflight-code" review ) >"$out" 2>&1
  got="$(cat "$work/ctx.sent3" 2>/dev/null || printf '')"
  apath="$(printf '%s\n' "$got" | sed -n '1s/^ARTIFACT_PATH=//p')"
  [ -z "$apath" ] || problems="$problems
        | ARTIFACT_PATH was exported with no context file present: $apath"
  line="$(grep -E '^preflight-code: issues=' "$out" 2>/dev/null | head -1)"
  case "$line" in *context=*) problems="$problems
        | the summary line claimed context when there was no context file: $line" ;; esac

  if [ -z "$problems" ]; then ok "the repository's review context reaches the model" "REQ-HOOK-40"
  else bad "the repository's review context reaches the model" "REQ-HOOK-40" \
        "section-only when present, whole file otherwise, nothing when absent" "see below" "$problems
"; fi
}

# ---------------------------------------------------------------------------- named model configurations

# These drive the SHIPPED renderer through the SHIPPED helper, with a stub `pr-agent` that records the
# config URL it was handed and takes a copy of that file. Offline and key-free, like the rest of the
# suite.
#
# The copy is the point: the rendered file is kept at $PREFLIGHT_HOME/.pragent.settings.toml and the next
# run overwrites it, so "what did THIS launch actually read?" is only answerable from a copy taken during
# the run. Every assertion is made against that copy rather than against the renderer's own output, so a
# renderer that reports one thing and writes another is caught.

model_stub() {
  # $2 is the value of --extra_config_url: the config this run was pointed at.
  local fake="$1"
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
printf '%s\n' "$2" > "$PREFLIGHT_CFG_OUT"
cp "$2" "$PREFLIGHT_CFG_COPY" 2>/dev/null
cat > /dev/null
exit 0
FAKE
  chmod +x "$fake/pr-agent"
}

model_repo() {
  local d="$1"
  mkdir -p "$d"
  ( cd "$d" \
      && git init -q -b main . \
      && printf 'a\n' > f.txt \
      && git add -A \
      && git -c commit.gpgsign=false commit -q --no-verify -m init \
      && printf 'b\n' >> f.txt ) >/dev/null 2>&1
}

# A config dir as install.sh leaves it, plus the step its NEXT line tells the user to take: create both
# files from the installed examples. Run through the real installer rather than copying the repo's
# templates, so a case cannot pass against a config shape an install would never produce - and the examples
# are the ones the install actually wrote.
model_cfg_dir() {
  local cfg="$1"
  mkdir -p "$cfg"
  PREFLIGHT_HOME="$cfg" PREFLIGHT_BIN_DIR="$cfg/.bin" \
  PREFLIGHT_SKIP_TOOL_INSTALL=1 "$repo_root/install.sh" >/dev/null 2>&1
  cp "$cfg/settings.toml.example" "$cfg/settings.toml"
  cp "$cfg/providers.toml.example" "$cfg/providers.toml"
  # The one value the reference cannot carry for the user: its key is empty, and the resolver refuses an
  # empty credential - so the copy is completed exactly as the NEXT line tells a user to.
  sed -i.bak 's/^key = ""/key = "test-key"/' "$cfg/providers.toml" && rm -f "$cfg/providers.toml.bak"
  chmod 600 "$cfg/providers.toml"
}

# Write a fixture as ONE document and split it by TOP-LEVEL TABLE: [config] and [pr_reviewer] go to
# settings.toml, [providers.*] and [profiles.*] to providers.toml. A case then never has to say which file
# a table belongs to, and a profile cannot silently land in the wrong one. The PROVIDERS already in
# providers.toml are kept (a case only states what it is changing); its PROFILES are replaced, so one
# case's profiles cannot leak into the next.
model_cfg_write() {
  local cfg="$1"
  python3 - "$cfg" "$2" <<'PYCFG'
import pathlib, sys

cfg = pathlib.Path(sys.argv[1])
chunks, cur = [], []
for line in sys.argv[2].splitlines():
    if line.startswith("[") and line.rstrip().endswith("]"):
        if cur:
            chunks.append(cur)
        cur = [line]
    else:
        cur.append(line)
if cur:
    chunks.append(cur)

settings, providers = [], []
for chunk in chunks:
    top = chunk[0].strip().strip("[]").split(".")[0].strip().strip('"')
    # settings.toml is every section pr-agent reads PLUS [selection]; providers.toml is
    # [providers.*] and [profiles.*]. Anything else a fixture writes goes to settings.toml, which is
    # where pr-agent's own sections live.
    is_providers = top in ("providers", "profiles")
    (providers if is_providers else settings).append("\n".join(chunk).strip("\n"))

(cfg / "settings.toml").write_text("\n\n".join(settings).strip() + "\n")

path = cfg / "providers.toml"
existing = path.read_text() if path.exists() else ""
keep, cur = [], []
for line in existing.splitlines():
    if line.startswith("[") and line.rstrip().endswith("]"):
        if cur:
            keep.append(cur)
        cur = [line]
    else:
        cur.append(line)
if cur:
    keep.append(cur)
kept = ["\n".join(c).strip("\n") for c in keep
        if c[0].strip().strip("[]").split(".")[0].strip().strip('"') != "profiles"]
out = "\n\n".join([c for c in kept if c] + providers)
path.write_text(out.strip() + "\n" if out.strip() else "")
PYCFG
}

case_model_configuration() {
  local d="$work/models" cfg="$work/models-cfg" fake="$work/models-bin"
  local repo_dir
  mkdir -p "$fake"
  model_repo "$d"
  repo_dir="$(cd "$d" && pwd -P)"
  model_cfg_dir "$cfg"
  model_stub "$fake"

  cat > "$cfg/providers.toml" <<'TOML'
[providers.alpha]
api_base = "https://alpha.example.com/v1"
key      = "key-one"
stream   = true

[providers.work]
transport = "openrouter"
api_base  = "https://llm.internal.corp/v1"
key       = "key-two"
TOML

  # Two endpoints are configured and the SECOND is the one in use, deliberately: a renderer that ignored
  # the provider entry would leave the first provider's host and key in place, which is exactly the
  # silent misroute this feature exists to make impossible.
  #
  # The second provider's transport is `openrouter` rather than the default `openai`, and that is also
  # deliberate: the default transport is `openai`, so a renderer that hard-coded the default instead of
  # reading the provider would look correct on an `openai` provider. A different transport is what makes
  # "the pin is derived from the provider" falsifiable.
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "work-main"
fallback = ["work-small"]

# Run-wide, independent of which profile is assigned.
[pr_reviewer]
num_max_findings = 10
review_heading = "From settings.toml"

[config]
max_output_tokens = 384000

[profiles.work-main]
provider = "work"
model = "their-model-id"

[profiles.work-small]
provider = "work"
model = "their-small"
TOML
)"

  local problems="" rc url copy out
  run_models() {
    rc=0
    ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" \
        PREFLIGHT_CFG_OUT="$work/models.url" PREFLIGHT_CFG_COPY="$work/models.copy" \
        PREFLIGHT_HOME="$cfg" bash "$repo_root/src/preflight-code" review ) >"$work/models.out" 2>&1 || rc=$?
    url="$(cat "$work/models.url" 2>/dev/null)"
    copy="$work/models.copy"
    rm -f "$work/models.url"
  }

  run_models
  [ "$rc" = 0 ] || problems="$problems
        | a run with a valid assignment failed (exit $rc): $(cat "$work/models.out")"
  case "$url" in
    # The launched config must be the RENDERED file: it is the only source now, so an empty URL means the
    # run never got a config at all and would answer on pr-agent's own defaults.
    "") problems="$problems
        | pr-agent was not handed a rendered config (got nothing)" ;;
    # And it must be a name pr-agent will actually LOAD. Its settings loader skips every file that is not
    # `*.toml` - with a warning, not an error - so a correctly-named-by-content file at a bare `mktemp`
    # path is accepted as `--extra_config_url` and then ignored, and the run answers on pr-agent's own
    # defaults. That is why this asserts the SUFFIX rather than only the content.
    *.toml) ;;
    *) problems="$problems
        | the rendered config is named ${url##*/}, which pr-agent will skip: its loader reads only *.toml" ;;
  esac
  if [ ! -s "$copy" ]; then
    problems="$problems
        | the run wrote no config for pr-agent to read (output: $(cat "$work/models.out"))"
  else
    # The heredoc is written to a FILE and run, not embedded in a command substitution: on macOS bash 3.2
    # an apostrophe anywhere in such a body is a mis-parse (AGENTS.md), turning a message edit into a
    # syntax error far from the cause. This file had that fixed once - keeping the shape keeps it fixed.
    cat > "$work/models-check.py" <<'PY'
import os, sys, tomllib
path = sys.argv[1]
d = tomllib.load(open(path, "rb"))
bad = []
if d["config"]["model"] != "their-model-id":
    bad.append(f"model={d['config']['model']!r} (want the named provider id)")
if d["config"]["fallback_models"] != ["their-small"]:
    bad.append(f"fallback_models={d['config']['fallback_models']!r}")
if d["openrouter"]["api_base"] != "https://llm.internal.corp/v1":
    bad.append(f"api_base={d['openrouter']['api_base']!r} - the other provider would answer")
if d["openrouter"]["key"] != "key-two":
    bad.append("the credential is not the named provider")
# The pin must come from the provider entry. The default transport is `openai`, so this provider uses
# `openrouter` and the two cannot be confused - a renderer that hard-coded the default, or skipped the
# pin, would leave the request addressed to the wrong provider transport.
if d["litellm"]["custom_llm_provider"] != "openrouter":
    bad.append(f"pin={d['litellm']['custom_llm_provider']!r} (want the provider transport)")
# This provider does not stream, so no streaming pair may survive from settings.toml: the gate fires on a
# provider name AND an api_base substring, so a stale pair is one that a host the user never connected to
# streaming happens to match.
if d["litellm"]["force_streaming_custom_llm_provider"] != "":
    bad.append("an inherited streaming provider survived the render")
if d["litellm"]["force_streaming_api_base_substrings"] != []:
    bad.append("an inherited streaming host survived the render")
# settings.toml IS the config, so anything it carries must reach the render rather than be replaced by it.
# These two are the ones whose loss changes review behaviour.
if d["config"].get("max_output_tokens", 0) < 100000:
    bad.append("the profile max_output_tokens was dropped by the render")
if not d["pr_reviewer"].get("review_heading", ""):
    bad.append("the settings.toml review_heading was dropped by the render")
if d["pr_reviewer"]["num_max_findings"] != 10:
    bad.append(f"the profile num_max_findings did not apply: {d['pr_reviewer']['num_max_findings']!r}")
mode = os.stat(path).st_mode & 0o777
if mode != 0o600:
    bad.append(f"the rendered config is {oct(mode)}, not 0o600, and it holds a key")
print("; ".join(bad))
sys.exit(1 if bad else 0)
PY
    out="$(python3 "$work/models-check.py" "$copy")" || problems="$problems
        | the rendered config is not right: $out"

    # The per-run file's mode is checked on the stub's copy (above), because the helper deletes its own
    # render on exit. What this asserts is that deletion: a credential-bearing file per run, never
    # accumulated, and a stale render that a later run could be handed.
    case "$url" in
      "$cfg"/.pragent.settings.*.toml) ;;
      *) problems="$problems
        | pr-agent was handed $url, not a per-run file in $cfg" ;;
    esac
    if [ -e "$url" ]; then
      problems="$problems
        | the run left its per-run rendered config behind: $url"
    fi
  fi
  rm -f "$copy"

  # The inspectable copy is what survives a run, by design. What must hold for it: it is 600-mode, it is
  # outside the repository, and the NEXT run rewrites it rather than reusing it.
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
printf '%s\n' "$2" > "$PREFLIGHT_CFG_OUT"
exit 3
FAKE
  chmod +x "$fake/pr-agent"
  run_models
  [ "$rc" = 3 ] || problems="$problems
        | a failing pr-agent no longer reports its own exit status (got $rc)"
  _fixed="$cfg/.pragent.settings.toml"
  if [ ! -f "$_fixed" ]; then
    problems="$problems
        | the inspectable copy of the last render is missing ($_fixed)"
  else
    [ "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$_fixed")" = "0o600" ] \
      || problems="$problems
        | the inspectable copy is not 600-mode: $(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$_fixed")"
    case "$(cd "$cfg" && pwd -P)/" in
      "$repo_dir"/*) problems="$problems
        | the rendered config lives inside the repository, so a review could stage its own key" ;;
    esac
  fi
  # A SECOND run must overwrite the first's bytes, not append or reuse them.
  before_sum="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$_fixed" 2>/dev/null)"
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "work-main"

[profiles.work-main]
provider = "work"
model = "a-different-model"
TOML
)"
  run_models >/dev/null 2>&1
  after_sum="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$_fixed" 2>/dev/null)"
  [ -n "$before_sum" ] && [ "$before_sum" = "$after_sum" ] && problems="$problems
        | the rendered config was NOT rewritten for the next run - a stale endpoint and model would be reused"
  model_stub "$fake"

  # The rendered file holds the provider's key, and the review snapshots the working tree with `git add -A`
  # BEFORE rendering - so with a config dir inside a repository the PREVIOUS run's file is what gets
  # staged. That is reachable now the path is fixed where a `mktemp` path made it impossible, so the
  # renderer refuses it. Both directions are asserted: a repo that ignores the path works, one that does
  # not refuses and says what to add.
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "work-main"

[profiles.work-main]
provider = "work"
model = "their-model-id"
TOML
)"
  _home_in_repo="$d/home-in-repo"
  mkdir -p "$_home_in_repo"
  cp "$cfg/settings.toml" "$cfg/providers.toml" "$cfg/settings-render.sh" "$_home_in_repo/"
  # The refusal must come BEFORE the working-tree snapshot. That snapshot is `git add -A`, which writes
  # the blob - so an unignored providers.toml would land in .git/objects even though the run refuses, and
  # `git cat-file` would hand the key back afterwards. Counted, not assumed: objects are enumerated before
  # and after, and the key's blob must not be among the new ones.
  _objs_before="$work/models.objs.before"; _objs_after="$work/models.objs.after"
  git -C "$d" cat-file --batch-all-objects --batch-check > "$_objs_before" 2>/dev/null
  rc=0
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/models.tmpdir.url" \
      PREFLIGHT_HOME="$_home_in_repo" bash "$repo_root/src/preflight-code" review ) >"$work/models.tmpdir.out" 2>&1 || rc=$?
  [ "$rc" != 0 ] || problems="$problems
        | a PREFLIGHT_HOME inside a repository, not ignoring the rendered path, was accepted - the key would be staged"
  # The key from providers.toml, by content: a blob whose body carries it is the credential in the object
  # store, whichever path it was staged under.
  _keyblob="$(git -C "$d" cat-file --batch-all-objects --batch-check > "$_objs_after" 2>/dev/null; \
              comm -13 "$_objs_before" "$_objs_after" | awk '$2 == "blob" {print $1}' | \
              while read -r _o; do
                git -C "$d" cat-file blob "$_o" 2>/dev/null | grep -qF 'key-two' && echo "$_o" && break
              done)"
  [ -z "$_keyblob" ] || problems="$problems
        | the refusal came AFTER the working-tree snapshot: the key reached .git/objects as blob $_keyblob"
  case "$(cat "$work/models.tmpdir.out")" in
    *"are not ignored there"*) ;;
    *) problems="$problems
        | the refusal for a config dir inside a repository did not name the cause: $(cat "$work/models.tmpdir.out")" ;;
  esac
  # The remedy must name the DIRECTORY: an enumeration of known names can never cover a
  # `providers.toml.bak` or an editor copy, which the same snapshot stages. It must also be RELATIVE,
  # because a gitignore pattern is matched from the repo root and an absolute one can never be pasted in.
  case "$(cat "$work/models.tmpdir.out")" in
    *"(home-in-repo/)"*) ;;
    *) problems="$problems
        | the refusal did not print the config directory as a repo-relative rule: $(grep -i 'not ignored' "$work/models.tmpdir.out")" ;;
  esac
  # Ignoring ONLY the render is not enough: providers.toml sits beside it and holds the same key, so the
  # remedy the refusal prints has to cover both, and a half-ignored config dir must still be refused.
  printf 'home-in-repo/.pragent.settings.*.toml\n' > "$d/.gitignore"
  rc=0
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/models.tmpdir.url" \
      PREFLIGHT_HOME="$_home_in_repo" bash "$repo_root/src/preflight-code" review ) >"$work/models.tmpdir.out" 2>&1 || rc=$?
  [ "$rc" != 0 ] || problems="$problems
        | ignoring only the rendered path was accepted, but providers.toml holds the same key and would be staged"
  case "$(cat "$work/models.tmpdir.out")" in
    *"home-in-repo/providers.toml"*) ;;
    *) problems="$problems
        | the refusal did not name providers.toml as unignored: $(grep -i 'not ignored' "$work/models.tmpdir.out" | head -2)" ;;
  esac
  # EVERY file in the dir counts, not the four names a list would hold: a backup of providers.toml holds
  # the same key, and `git add -A` stages it under a name no enumeration can predict.
  printf 'home-in-repo/.pragent.settings.*.toml\nhome-in-repo/.pragent.settings.toml\nhome-in-repo/providers.toml\nhome-in-repo/settings.toml\n' > "$d/.gitignore"
  printf 'key = "key-two"\n' > "$_home_in_repo/providers.toml.bak"
  rc=0
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/models.tmpdir.url" \
      PREFLIGHT_HOME="$_home_in_repo" bash "$repo_root/src/preflight-code" review ) >"$work/models.tmpdir.out" 2>&1 || rc=$?
  [ "$rc" != 0 ] || problems="$problems
        | an unignored providers.toml.bak was accepted, but it holds the key and the snapshot stages it"
  case "$(cat "$work/models.tmpdir.out")" in
    *"home-in-repo/providers.toml.bak"*) ;;
    *) problems="$problems
        | the refusal did not name the unignored backup: $(grep -i 'not ignored' "$work/models.tmpdir.out" | head -2)" ;;
  esac
  rm -f "$_home_in_repo/providers.toml.bak"
  # But a config dir in a DIFFERENT git repository is not this run's hazard: the reviewed repo's snapshot
  # never sees it, so it must render. Scoping the guard to the repo under review is what prevents an
  # unrelated `$HOME`-as-checkout from blocking every review on the machine.
  # OUTSIDE `$d`: a nested git repository inside the fixture would break that fixture's own snapshot.
  _other_repo="$work/other-repo"
  rm -rf "$_other_repo"; mkdir -p "$_other_repo"
  cp "$cfg/settings.toml" "$cfg/providers.toml" "$cfg/settings-render.sh" "$_other_repo/"
  ( cd "$_other_repo" && git init -q . ) 2>/dev/null
  ( cd "$d" && bash -c '. "$1"; __preflight_render_settings "$2" >/dev/null' _ \
      "$repo_root/scripts/settings-render.sh" "$_other_repo" ) >"$work/models.other.out" 2>&1 \
    || problems="$problems
        | a config dir in an UNRELATED repository blocked the review: $(tail -2 "$work/models.other.out")"

  # The same layout, with the whole directory ignored - the remedy the refusal prints: it must render.
  printf 'home-in-repo/\n' > "$d/.gitignore"
  rc=0
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/models.tmpdir.url" \
      PREFLIGHT_HOME="$_home_in_repo" bash "$repo_root/src/preflight-code" review ) >"$work/models.tmpdir.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || problems="$problems
        | a config dir inside a repository, with both files ignored, was still refused (exit $rc): $(cat "$work/models.tmpdir.out")"
  [ "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$_home_in_repo/.pragent.settings.toml" 2>/dev/null)" = "0o600" ] \
    || problems="$problems
        | the rendered config is not 600-mode when PREFLIGHT_HOME is inside a repository"
  rm -f "$d/.gitignore"
  rm -rf "$d/home-in-repo" "$work/models.tmpdir.copy" "$work/models.tmpdir.url"
  model_stub "$fake"

  # A file that assigns NOTHING means there is no model, and there is no second config to fall back to -
  # so the run must refuse and say why, rather than review on pr-agent's own defaults. Rendering nothing
  # and rendering an empty file are also different outcomes, and the second would look configured.
  printf '[pr_reviewer]\nnum_max_findings = 10\n' > "$cfg/settings.toml"
  run_models
  [ "$rc" = 2 ] || problems="$problems
        | a settings.toml assigning no profile exited $rc, not 2 (it must refuse: there is no model)"

  # The SAME state reached through the shell fast path rather than the parser: a file whose every line is
  # blank or a comment. That path used to `return 0` - leaving the rendered path empty so the caller
  # launched pr-agent with no config - when preflight.toml could still supply a model. With no fallback it
  # must refuse too, or the review silently answers on pr-agent's own defaults.
  printf '# every key is commented out\n#\n' > "$cfg/settings.toml"
  run_models
  [ "$rc" = 2 ] || problems="$problems
        | an all-comments settings.toml exited $rc, not 2 (it must refuse, not fall through to defaults)"
  case "$(cat "$work/models.out")" in
    *"assigns no model profile"*) ;;
    *) problems="$problems
        | the refusal for an all-comments settings.toml did not name the cause: $(cat "$work/models.out")" ;;
  esac
  case "$(cat "$work/models.out")" in
    *"assigns no profile"*|*"no 'main'"*|*"[selection]"*) ;;
    *) problems="$problems
        | the refusal for an unassigned settings.toml did not name the cause: $(cat "$work/models.out")" ;;
  esac

  # Profiles DEFINED but none assigned - the state "I wrote my models but have not picked one". The
  # settings.toml is written explicitly rather than through model_cfg_write, which leaves a previous
  # case's file in place when the fixture names no settings section at all.
  printf '[pr_reviewer]\nnum_max_findings = 10\n' > "$cfg/settings.toml"
  cat > "$cfg/providers.toml" <<'TOML'
[providers.work]
api_base = "https://llm.internal.corp/v1"
key = "key-two"

[profiles.decided-later]
provider = "work"
model = "their-model-id"
TOML
  run_models
  [ "$rc" = 2 ] || problems="$problems
        | a profiles-only settings.toml exited $rc, not 2: with no fallback config an unassigned file has no model"
  case "$(cat "$work/models.out")" in
    *"assigns no model profile"*) ;;
    *) problems="$problems
        | the refusal for a profiles-only settings.toml did not name the cause: $(cat "$work/models.out")" ;;
  esac

  printf '[selection]\nmain = "work-main"\n' > "$cfg/settings.toml"
  printf '[providers.work]\napi_base = "https://llm.internal.corp/v1"\nkey = "key-two"\n\n[profiles.work-main]\nprovider = "work"\nmodel = "their-model-id"\n' \
    > "$cfg/providers.toml"
  chmod 600 "$cfg/providers.toml"
  # TWO RUNS NEVER SHARE A FILE. (Placed here, with its own valid pair: every assertion above this point
  # leaves a deliberately-invalid config behind, which would make a render refuse and prove nothing.) The rendered path carries the run's pid, so concurrent runs cannot read
  # each other's model, endpoint and KEY - the race a single fixed path had, which a lock only papered
  # over. Asserted on two renders run back to back in separate processes.
  _a="$(bash -c '. "$1"; __preflight_render_settings "$2" >/dev/null 2>&1; printf "%s" "$PREFLIGHT_RENDERED_CONFIG"' \
        _ "$repo_root/scripts/settings-render.sh" "$cfg" 2>/dev/null)" || _a=''
  _b="$(bash -c '. "$1"; __preflight_render_settings "$2" >/dev/null 2>&1; printf "%s" "$PREFLIGHT_RENDERED_CONFIG"' \
        _ "$repo_root/scripts/settings-render.sh" "$cfg" 2>/dev/null)" || _b=''
  if [ -z "$_a" ] || [ -z "$_b" ]; then
    problems="$problems
        | a render produced no path, so the per-run isolation could not be checked"
  else
    [ "$_a" != "$_b" ] || problems="$problems
        | two runs rendered to the SAME path ($_a), so one could read the other's endpoint and key"
    [ "$(dirname "$_a")" = "$cfg" ] || problems="$problems
        | a run rendered outside the config dir: $_a"
    rm -f "$_a" "$_b"
  fi
  # The LAST render is also copied to a fixed name, so a run stays inspectable after its own file is gone.
  if [ ! -f "$cfg/.pragent.settings.toml" ]; then
    problems="$problems
        | no fixed-name copy of the last render was left for inspection"
  else
    [ "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$cfg/.pragent.settings.toml")" = "0o600" ] \
      || problems="$problems
        | the inspectable copy is not 600-mode, and it holds the key"
  fi

  # A FALLBACK LIST IS NOT A MODEL CHOICE. With `main` absent or empty, promoting the first fallback to
  # the primary would review on a profile the user meant only as a backup - and the summary line would not
  # report a fallback, because the resolver had already made it the primary. The refusal message used to
  # say "there is nothing to review with" while the code did exactly the opposite.
  # providers.toml written directly: model_cfg_write replaces the profiles, and this case needs the
  # profile the fallback names to EXIST, so the refusal can only be about `main`.
  printf '[selection]\nfallback = ["backup"]\n' > "$cfg/settings.toml"
  cat > "$cfg/providers.toml" <<'TOML'
[providers.work]
api_base = "https://llm.internal.corp/v1"
key = "key-two"

[profiles.backup]
provider = "work"
model = "their-model-id"
TOML
  run_models
  [ "$rc" = 2 ] || problems="$problems
        | a settings.toml with only a fallback list exited $rc, not 2 (a fallback is not a main model)"
  case "$(cat "$work/models.out")" in
    *"fallback chain is not a main model"*) ;;
    *) problems="$problems
        | the refusal for a fallback-only assignment did not say a fallback is not a main model: $(cat "$work/models.out")" ;;
  esac

  # A REPOSITORY may override a review setting in its own committed `.preflight.toml`, without touching
  # the machine's settings.toml. The merge is by SECTION then by KEY, so an override says one thing and
  # every other [pr_reviewer] value from settings.toml survives - a whole-file replacement would silently
  # drop the finding cap that keeps the loop convergent. Asserted on the bytes pr-agent receives, because
  # a merge that only happened in the resolver's head would look identical from here.
  printf '[selection]\nmain = "work-main"\n\n[pr_reviewer]\nreview_heading = "From settings.toml"\nnum_max_findings = 10\n' > "$cfg/settings.toml"
  printf '[providers.work]\napi_base = "https://llm.internal.corp/v1"\nkey = "key-two"\n\n[profiles.work-main]\nprovider = "work"\nmodel = "their-model-id"\n' \
    > "$cfg/providers.toml"
  chmod 600 "$cfg/providers.toml"
  printf '[pr_reviewer]\nnum_max_findings = 4\n\n[gate]\nallow_issues = true\n' > "$d/.preflight.toml"
  _ov="$(bash -c '. "$1"; __preflight_render_settings "$2" "$3" >/dev/null 2>&1; printf "%s" "$PREFLIGHT_RENDERED_CONFIG"' \
        _ "$repo_root/scripts/settings-render.sh" "$cfg" "$d" 2>/dev/null)" || _ov=''
  if [ -z "$_ov" ] || [ ! -s "$_ov" ]; then
    problems="$problems
        | a repository .preflight.toml made the render refuse: $(bash -c '. "$1"; __preflight_render_settings "$2" "$3"' _ "$repo_root/scripts/settings-render.sh" "$cfg" "$d" 2>&1 | tail -3)"
  else
    cat > "$work/models-override.py" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
bad = []
if d["pr_reviewer"]["num_max_findings"] != 4:
    bad.append(f"the repo override did not apply: num_max_findings={d['pr_reviewer']['num_max_findings']!r}")
if d["pr_reviewer"].get("review_heading") != "From settings.toml":
    bad.append("the repo override replaced the whole [pr_reviewer] instead of merging into it")
if "gate" in d:
    bad.append("the [gate] policy reached pr-agent, which reads nothing from it")
print("; ".join(bad))
sys.exit(1 if bad else 0)
PY
    out="$(python3 "$work/models-override.py" "$_ov")" || problems="$problems
        | the repository .preflight.toml was not applied correctly: $out"
    rm -f "$_ov"
  fi
  # And the same file, same content, with NO repository argument: the override must not apply, or the
  # assertion above would pass even if the renderer read the file unconditionally from the cwd.
  _nov="$(cd "$d" && bash -c '. "$1"; __preflight_render_settings "$2" >/dev/null 2>&1; printf "%s" "$PREFLIGHT_RENDERED_CONFIG"' \
        _ "$repo_root/scripts/settings-render.sh" "$cfg" 2>"$work/models-noroot.err")" || _nov=''
  # A render that REFUSED is a failure, not a reason to skip: `preflight-code` passes `${root:-}`, so an empty
  # root is the ordinary outside-a-repository case, and a regression that refused it would break the
  # helper there while this case stayed green by asserting nothing.
  if [ -z "$_nov" ] || [ ! -s "$_nov" ]; then
    problems="$problems
        | the renderer refused without a repository argument, which is the outside-a-repository case: $(tail -3 "$work/models-noroot.err")"
  else
    python3 - "$_nov" <<'PY' || problems="$problems
        | the override applied without a repository argument, so its scope is the cwd rather than the reviewed tree"
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
sys.exit(1 if d["pr_reviewer"]["num_max_findings"] != 10 or "gate" in d else 0)
PY
    rm -f "$_nov"
  fi
  rm -f "$d/.preflight.toml"

  # A committed file must not choose which credential a review spends: naming a provider directly, or a
  # profile through [selection], is the same decision one indirection apart. Both are refused by name.
  for _bad in '[providers.x]\nkey = "k"' '[profiles.x]\nprovider = "work"\nmodel = "m"' '[selection]\nmain = "work-main"'; do
    printf '%b\n' "$_bad" > "$d/.preflight.toml"
    rc=0
    ( cd "$d" && bash -c '. "$1"; __preflight_render_settings "$2" "$3"' \
        _ "$repo_root/scripts/settings-render.sh" "$cfg" "$d" ) >"$work/models-bad.out" 2>&1 || rc=$?
    [ "$rc" != 0 ] || problems="$problems
        | a .preflight.toml choosing a model or credential was accepted: $_bad"
    case "$(cat "$work/models-bad.out")" in
      *"cannot override"*) ;;
      *) problems="$problems
        | the refusal for $_bad did not name it as an override a repository cannot make: $(cat "$work/models-bad.out" | tail -2)" ;;
    esac
  done
  rm -f "$d/.preflight.toml"

  if [ -z "$problems" ]; then ok "a named model configuration is rendered, scoped and cleaned up" "REQ-HOOK-44"
  else bad "a named model configuration is rendered, scoped and cleaned up" "REQ-HOOK-44" \
        "the rendered 600-mode config is what pr-agent reads; the provider's own host and key apply; cleanup holds on failure" \
        "see below" "$problems
"; fi
}

case_model_configuration_refusals() {
  local d="$work/models-refuse" cfg="$work/models-refuse-cfg" fake="$work/models-refuse-bin"
  mkdir -p "$fake"
  model_repo "$d"
  model_cfg_dir "$cfg"
  model_stub "$fake"

  local problems=""
  # Each refusal has to NAME its cause, because the failure it prevents is silent: a chain spanning two
  # providers is answered by whichever one is pinned - a different host, with that provider's key - and
  # pr-agent reports nothing.
  try_refuse() {
    local label="$1" expect="$2" rc=0 out
    rm -f "$work/refuse.url"
    ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/refuse.url" \
        PREFLIGHT_HOME="$cfg" bash "$repo_root/src/preflight-code" review ) >"$work/refuse.out" 2>&1 || rc=$?
    out="$(cat "$work/refuse.out")"
    if [ "$rc" = 0 ]; then
      problems="$problems
        | $label was accepted (exit 0): $out"
      return
    fi
    case "$out" in
      *"$expect"*) ;;
      *) problems="$problems
        | the refusal for $label did not name it (want: $expect): $out" ;;
    esac
    # A refusal must not reach pr-agent: a review that ran anyway would have answered on the wrong model,
    # and the sidecar it wrote would authorize a commit on that basis.
    if [ -e "$work/refuse.url" ]; then
      problems="$problems
        | $label refused, but pr-agent ran anyway"
    fi
  }

  cat > "$cfg/providers.toml" <<'TOML'
[providers.one]
api_base = "https://one.example/v1"
key      = "k1"
[providers.two]
api_base = "https://two.example/v1"
key      = "k2"
TOML
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"
fallback = ["b"]
[profiles.a]
provider = "one"
model = "m1"
[profiles.b]
provider = "two"
model = "m2"
TOML
)"
  try_refuse "a chain that spans two providers" "ONE endpoint per run"

  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"
[profiles.a]
provider = "typo"
model = "m1"
TOML
)"
  try_refuse "a provider defined nowhere" "no [providers.typo] table defines"

  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"
[profiles.a]
model = "m1"
TOML
)"
  try_refuse "a profile naming no provider" "has no 'provider'"

  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"
[profiles.a]
provider = "one"
model = "m1"
[profiles.a.litellm]
custom_llm_provider = "openai"
TOML
)"
  try_refuse "a profile-level litellm section" "[profiles.a.litellm]"

  cat > "$cfg/providers.toml" <<'TOML'
[providers.x]
transport = "made-up"
key = "k"
TOML
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"
[profiles.a]
provider = "x"
model = "m1"
TOML
)"
  try_refuse "a transport pr-agent cannot route" "not one pr-agent can route"

  cat > "$cfg/providers.toml" <<'TOML'
[providers.x]
transport = "anthropic"
api_base = "https://proxy.example/v1"
key = "k"
TOML
  # The profile has to be restated: writing providers.toml above replaced the profiles the previous case
  # put there. That is deliberate - a case states the whole file it is testing, not a patch of the last.
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"
[profiles.a]
provider = "x"
model = "m1"
TOML
)"
  try_refuse "an api_base on a transport that reads none" "reads no endpoint for transport"

  # A CREDENTIAL under an endpoint section OTHER than the one being written. It would be copied into the
  # rendered file verbatim and sent - and settings.toml is never mode-checked, so the copy would also be
  # the one left world-readable. This is what a leftover `.secrets.toml` migration looks like.
  cat > "$cfg/providers.toml" <<'TOML'
[providers.x]
api_base = "https://one.example/v1"
key = "k1"
TOML
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"

[openrouter]
key = "a-leftover-key"

[profiles.a]
provider = "x"
model = "m1"
TOML
)"
  try_refuse "a credential in another endpoint section" "belongs in providers.toml"

  # The OTHER spelling, under the section this run writes. `entry["key_name"]` covers only the transport's
  # own name, so `[openai] api_key` would be copied into the rendered file unrefused - the same hole in
  # the other direction.
  cat > "$cfg/providers.toml" <<'TOML'
[providers.x]
api_base = "https://one.example/v1"
key = "k1"
TOML
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"

[openai]
api_key = "a-leftover-key"

[profiles.a]
provider = "x"
model = "m1"
TOML
)"
  try_refuse "a credential under the chosen section's other spelling" "which the provider supplies"

  # A transport-specific credential NAME. The set is derived from the transport table rather than
  # hard-coded, because `gemini` uses `gemini_api_key` - a listed ("key", "api_key") left that unrefused.
  cat > "$cfg/providers.toml" <<'TOML'
[providers.x]
api_base = "https://one.example/v1"
key = "k1"
TOML
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"

[google_ai_studio]
gemini_api_key = "a-leftover-key"

[profiles.a]
provider = "x"
model = "m1"
TOML
)"
  try_refuse "a transport-specific credential name" "belongs in providers.toml"

  # A whole `[providers.*]` (or `[profiles.*]`) block pasted into the wrong file. Its `key` would be copied
  # into the rendered config and left in a settings.toml nothing mode-checks - a shadowed position.
  cat > "$cfg/providers.toml" <<'TOML'
[providers.x]
api_base = "https://one.example/v1"
key = "k1"
TOML
  # Written explicitly: `model_cfg_write` splits by table name, so it would put `[profiles.a]` in
  # settings.toml too and a DIFFERENT refusal would fire first - proving nothing about the stray table.
  printf '[selection]\nmain = "a"\n\n[providers.stray]\nkey = "sk-leaked"\n' > "$cfg/settings.toml"
  printf '[providers.x]\napi_base = "https://one.example/v1"\nkey = "k1"\n\n[profiles.a]\nprovider = "x"\nmodel = "m1"\n' \
    > "$cfg/providers.toml"
  try_refuse "a providers table in settings.toml" "belongs in providers.toml"

  # A file that assigns a model while the resolver is missing must refuse rather than review on some
  # other model. This is the upgrade path where the templates arrived without the helper, so
  # the helper has to be unreachable from EVERY lookup the helper performs - including the checkout it
  # would find beside the script in this very test. A lone copy of the helper, with no scripts/ beside
  # it, is what that install looks like.
  cat > "$cfg/providers.toml" <<'TOML'
[providers.x]
api_base = "https://one.example/v1"
key = "k1"
TOML
  model_cfg_write "$cfg" "$(cat <<'TOML'
[selection]
main = "a"
[profiles.a]
provider = "x"
model = "m1"
TOML
)"
  mkdir -p "$work/upgrade/bin"
  cp "$repo_root/src/preflight-code" "$work/upgrade/bin/preflight"
  mkdir -p "$work/upgrade/cfg"
  cp "$cfg/settings.toml" "$cfg/providers.toml" "$work/upgrade/cfg/"
  rm -f "$work/refuse.url"
  rc=0
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/refuse.url" \
      PREFLIGHT_HOME="$work/upgrade/cfg" bash "$work/upgrade/bin/preflight" review ) \
      >"$work/refuse.out" 2>&1 || rc=$?
  out="$(cat "$work/refuse.out")"
  if [ "$rc" = 0 ]; then
    problems="$problems
        | an assignment with no resolver installed was accepted (exit 0): $out"
  else
    case "$out" in
      *"settings-render.sh was not found"*) ;;
      *) problems="$problems
        | the refusal for a missing resolver did not name it: $out" ;;
    esac
    [ -e "$work/refuse.url" ] && problems="$problems
        | a missing resolver refused, but pr-agent ran anyway"
  fi

  # The other half of that message: no resolver AND no settings.toml, which is the bare-clone or wrong
  # `PREFLIGHT_HOME` case. The refusal must name what is actually missing instead of reporting the file
  # as present, because "settings.toml is present" sends the operator to inspect a file that is not there.
  _empty="$work/empty-cfg"
  rm -rf "$_empty"; mkdir -p "$_empty"
  rc=0
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/refuse.url" \
      PREFLIGHT_HOME="$_empty" bash "$work/upgrade/bin/preflight" review ) >"$work/refuse.out" 2>&1 || rc=$?
  out="$(cat "$work/refuse.out")"
  [ "$rc" != 0 ] || problems="$problems
        | a config dir with neither settings.toml nor a resolver was accepted (exit 0): $out"
  case "$out" in
    *"is present"*) problems="$problems
        | the refusal reported a settings.toml that does not exist as present: $out" ;;
  esac
  case "$out" in
    *"neither settings-render.sh nor"*) ;;
    *) problems="$problems
        | the refusal for an empty config dir did not name both missing files: $out" ;;
  esac

  # The half-configured state, which is the one a message can destroy: settings.toml absent while a KEYED
  # providers.toml is already there. The advice must not tell the operator to copy the empty-key template
  # over it, so the providers.toml line is offered only when that file is absent too.
  _half="$work/half-cfg"
  rm -rf "$_half"; mkdir -p "$_half"
  cat > "$_half/providers.toml" <<'TOML'
[providers.x]
api_base = "https://one.example/v1"
key = "my-real-key"
[profiles.a]
provider = "x"
model = "m1"
TOML
  rc=0
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/refuse.url" \
      PREFLIGHT_HOME="$_half" bash "$repo_root/src/preflight-code" review ) >"$work/half.out" 2>&1 || rc=$?
  out="$(cat "$work/half.out")"
  [ "$rc" != 0 ] || problems="$problems
        | a config dir with no settings.toml was accepted (exit 0): $out"
  case "$out" in
    *"settings.toml.example"*) ;;
    *) problems="$problems
        | the refusal for a missing settings.toml did not print the command that creates it: $out" ;;
  esac
  case "$out" in
    *"providers.toml.example"*) problems="$problems
        | a keyed providers.toml was told to copy the empty-key template over itself: $out" ;;
  esac
  grep -q 'my-real-key' "$_half/providers.toml" || problems="$problems
        | the refusal modified providers.toml, which holds the key"
  # The resolver is shared by both helpers, so every line it prints has to name the command the operator
  # ran - otherwise `preflight-pr` reports a refusal as `preflight-code`'s, or the retired bare name turns
  # up in output a user is reading. Asserted on a refusal, which is where these messages actually appear.
  case "$out" in
    preflight-code:*) ;;
    *) problems="$problems
        | the shared resolver did not name preflight-code in its refusal: $out" ;;
  esac
  case "$out" in
    *"preflight: "*) problems="$problems
        | the refusal still carries the retired bare-name prefix: $out" ;;
  esac

  # A derived key in settings.toml's OWN [litellm] is refused, not silently overwritten: the value would
  # read as configured while the render replaced it - and a pin that disagreed with the endpoint is
  # resolved by LiteLLM silently, to the wrong host.
  cat > "$cfg/providers.toml" <<'TOML'
[providers.x]
api_base = "https://one.example/v1"
key = "k1"
[profiles.a]
provider = "x"
model = "m1"
TOML
  printf '[selection]\nmain = "a"\n\n[litellm]\ncustom_llm_provider = "openrouter"\n' > "$cfg/settings.toml"
  rm -f "$work/refuse.url"
  rc=0
  ( cd "$d" && rm -rf .preflight && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/refuse.url" \
      PREFLIGHT_HOME="$cfg" bash "$repo_root/src/preflight-code" review ) >"$work/refuse.out" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    problems="$problems
        | a derived litellm key in settings.toml was accepted (exit 0), so it would be silently ignored"
  else
    case "$(cat "$work/refuse.out")" in
      *"which preflight derives"*) ;;
      *) problems="$problems
        | the refusal for a derived litellm key did not name it: $(cat "$work/refuse.out")" ;;
    esac
  fi


  if [ -z "$problems" ]; then ok "a configuration that cannot be applied is refused by name" "REQ-HOOK-45"
  else bad "a configuration that cannot be applied is refused by name" "REQ-HOOK-45" \
        "every refusal names its cause and no review runs" "see below" "$problems
"; fi
}

# ---------------------------------------------------------------------------- preflight-pr cleanup

# `preflight-pr` launches pr-agent as a child so its own EXIT trap can remove the per-run rendered config.
# That trap is the only thing that deletes it for this helper, so an undefined function or a dropped
# `rm` there leaks one credential-bearing file per run while the suite stays green - the renderer's own
# cases never drive `preflight-pr`. This drives it against a stub, offline.
case_pr_rendered_config_removed() {
  local cfg="$work/pr-cfg" fake="$work/pr-bin" d="$work/pr-repo"
  local rc out problems='' url
  mkdir -p "$fake" "$cfg"
  model_stub "$fake"
  model_repo "$d"
  model_cfg_write "$cfg" 'not used'
  printf '[selection]\nmain = "a"\n[pr_reviewer]\nnum_max_findings = 10\n' > "$cfg/settings.toml"
  printf '[providers.x]\napi_base = "https://one.example/v1"\nkey = "k1"\n\n[profiles.a]\nprovider = "x"\nmodel = "m1"\n' \
    > "$cfg/providers.toml"
  chmod 600 "$cfg/settings.toml" "$cfg/providers.toml"

  # A stub whose run FAILS after recording the URL: the failing path is the one that also has to remove
  # the file, and a trap that ran the removal only on success would leak exactly here.
  # The stub also reads its stdin: `preflight-pr` backgrounds pr-agent to be able to reap it, and bash
  # redirects a backgrounded command's stdin from /dev/null unless told otherwise - so a wrapper that
  # silently stops passing stdin through looks identical to one that never received any.
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
printf '%s\n' "$2" > "$PREFLIGHT_CFG_OUT"
read -r _piped <&0
printf '%s\n' "$_piped" > "$PREFLIGHT_STDIN_OUT"
exit 3
FAKE
  chmod +x "$fake/pr-agent"
  rm -f "$work/pr.stdin"

  printf 'piped-input\n' | ( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_CFG_OUT="$work/pr.url" \
      PREFLIGHT_STDIN_OUT="$work/pr.stdin" PREFLIGHT_HOME="$cfg" \
      bash "$repo_root/src/preflight-pr" ) >"$work/pr.out" 2>&1 || rc=$?
  url="$(cat "$work/pr.url" 2>/dev/null)"
  case "$(cat "$work/pr.stdin" 2>/dev/null)" in
    piped-input) ;;
    *) problems="$problems
        | pr-agent did not receive the caller's stdin through preflight-pr" ;;
  esac

  case "$url" in
    "$cfg"/.pragent.settings.*.toml) ;;
    *) problems="$problems
        | preflight-pr was handed ${url:-nothing}, not a per-run file in $cfg" ;;
  esac
  # The exit status must be pr-agent's, not a trap failure's: a trap calling a function that does not
  # exist reports 127 and hides the reason the run actually failed.
  [ "$rc" = 3 ] || problems="$problems
        | preflight-pr reported $rc, not pr-agent's 3 (a failing cleanup masks the real status)"
  case "$(cat "$work/pr.out")" in
    *"command not found"*) problems="$problems
        | preflight-pr's EXIT trap called something that does not exist: $(cat "$work/pr.out")" ;;
  esac
  if [ -n "$url" ] && [ -e "$url" ]; then
    problems="$problems
        | preflight-pr left its per-run rendered config behind: $url (it holds the key)"
  fi
  [ -f "$cfg/.pragent.settings.toml" ] || problems="$problems
        | preflight-pr left no inspectable copy of the render"
  # One file per run, 600-mode: the copy holds the key, so a wider mode defeats the point of the run's
  # own file being 600-mode.
  [ "$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' \
        "$cfg/.pragent.settings.toml" 2>/dev/null)" = "0o600" ] || problems="$problems
        | the inspectable copy is not 600-mode, and it holds the key"

  if [ -z "$problems" ]; then ok "preflight-pr removes its per-run rendered config" "REQ-HOOK-46"
  else bad "preflight-pr removes its per-run rendered config" "REQ-HOOK-46" \
        "the run deletes what it rendered and reports pr-agent's status" "see below" "$problems
"; fi
}

case_pr_abnormal_exit_reaps_child() {
  local cfg="$work/prreap-cfg" fake="$work/prreap-bin" d="$work/prreap-repo"
  local pidf="$work/prreap.pid" problems=''
  mkdir -p "$fake" "$cfg"
  model_repo "$d"
  printf '[selection]\nmain = "a"\n' > "$cfg/settings.toml"
  printf '[providers.x]\napi_base = "https://one.example/v1"\nkey = "k1"\n\n[profiles.a]\nprovider = "x"\nmodel = "m1"\n' \
    > "$cfg/providers.toml"
  chmod 600 "$cfg/settings.toml" "$cfg/providers.toml"

  # Same failure as REQ-HOOK-48, in the sibling helper: a pr-agent left running holds the caller's stdout
  # pipe open, so `x="$(preflight-pr ...)"` blocks on the model call after the helper is gone. The stub
  # reports its OWN pid and `exec` makes the sleep BE that process, so the case watches the exact child
  # rather than searching for it by name.
  printf '#!/bin/sh\nprintf "%%s\\n" "$$" > "$PREFLIGHT_REAP_PIDFILE"\nexec sleep 300\n' > "$fake/pr-agent"
  chmod +x "$fake/pr-agent"

  ( cd "$d" && exec env PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" PREFLIGHT_REAP_PIDFILE="$pidf" \
      bash "$repo_root/src/preflight-pr" >/dev/null 2>&1 ) &
  local pf=$! waited=0 child=''
  while [ "$waited" -lt 15 ] && [ ! -s "$pidf" ]; do
    sleep 1; waited=$((waited + 1))
  done
  [ -s "$pidf" ] && child="$(cat "$pidf")"

  if [ -z "$child" ]; then
    problems="$problems
        | the child never started, so this case proved nothing"
    kill -TERM "$pf" 2>/dev/null || true
    wait "$pf" 2>/dev/null || true
  else
    kill -TERM "$pf" 2>/dev/null || true
    wait "$pf" 2>/dev/null || true
    local tries=0 alive=1
    while [ "$tries" -lt 10 ]; do
      if kill -0 "$child" 2>/dev/null; then tries=$((tries + 1)); sleep 1; else alive=0; break; fi
    done
    if [ "$alive" = 1 ]; then
      problems="$problems
        | a PR review killed mid-flight left its pr-agent running, which holds the caller's output pipe open"
      kill -9 "$child" 2>/dev/null || true
    fi
  fi
  rm -f "$pidf"

  if [ -z "$problems" ]; then ok "an abnormally ended PR run does not leave pr-agent behind" "REQ-HOOK-49"
  else bad "an abnormally ended PR run does not leave pr-agent behind" "REQ-HOOK-49" \
        "the child is reaped when preflight-pr dies" "see below" "$problems
"; fi
}

case_review_progress_note() {
  local cfg="$work/note-cfg" fake="$work/note-bin" d="$work/note-repo" w="$work/note-work"
  local rc out problems='' hung silent junk fired survived
  mkdir -p "$fake" "$cfg" "$w"
  model_stub "$fake"
  model_repo "$d"
  model_cfg_write "$cfg" 'not used'
  printf '[selection]\nmain = "a"\n[pr_reviewer]\nnum_max_findings = 10\n' > "$cfg/settings.toml"
  printf '[providers.x]\napi_base = "https://one.example/v1"\nkey = "k1"\n\n[profiles.a]\nprovider = "x"\nmodel = "m1"\n' \
    > "$cfg/providers.toml"
  chmod 600 "$cfg/settings.toml" "$cfg/providers.toml"
  printf '#!/bin/sh\nexit 0\n' > "$fake/preflight-gate"; chmod +x "$fake/preflight-gate"

  # A pr-agent that never finishes and never writes an artifact is indistinguishable from a slow review
  # unless the helper says which phase it is in. The failure this guards is not the hang itself: it is
  # that an operator cannot tell a wedged endpoint from a working run until the wait expires.
  printf '#!/bin/sh\nexec sleep 600\n' > "$fake/pr-agent"; chmod +x "$fake/pr-agent"
  out="$( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" PREFLIGHT_REVIEW_WAIT=5 \
            PREFLIGHT_PROGRESS_EVERY=2 PREFLIGHT_SHUTDOWN_WAIT=1 \
            bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  hung="$(printf '%s\n' "$out" | grep -c 'still running')"

  # ... and the note must not fire when the artifact arrives first, or every normal review is noisy.
  cat > "$fake/pr-agent" <<'FAKE'
#!/bin/sh
printf '{}' > .preflight/review.json
printf 'done' > .preflight/review.md
exit 0
FAKE
  chmod +x "$fake/pr-agent"
  out="$( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" PREFLIGHT_REVIEW_WAIT=5 \
            PREFLIGHT_PROGRESS_EVERY=2 PREFLIGHT_SHUTDOWN_WAIT=1 \
            bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  silent="$(printf '%s\n' "$out" | grep -c 'still running')"

  # A typo in the interval must not turn the wait loop into a stream of shell errors: that noise is what
  # would hide the very note the two runs above exist to surface.
  printf '#!/bin/sh\nexec sleep 600\n' > "$fake/pr-agent"; chmod +x "$fake/pr-agent"
  # `08` is the value that matters, and the wait has to be long enough to let it fire: the note is
  # printed, then the interval is incremented, and arithmetic reads a leading zero as octal, where `08`
  # is not a number. A value like `5m` is sanitized back to the default and never reaches the increment.
  out="$( cd "$d" && PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" PREFLIGHT_REVIEW_WAIT=10 \
            PREFLIGHT_PROGRESS_EVERY=08 PREFLIGHT_SHUTDOWN_WAIT=1 \
            bash "$repo_root/src/preflight-code" review 2>&1 )" || rc=$?
  junk="$(printf '%s\n' "$out" | grep -c 'integer expression expected\|value too great for base')"
  # More than one note at a 1s interval would mean the interval never advanced.
  fired="$(printf '%s\n' "$out" | grep -c 'still running')"
  survived=1
  case "$out" in *'stopping it'*) ;; *) survived=0 ;; esac

  [ "$hung" -ge 1 ] || problems="$problems
        | a review that wrote nothing for 5s printed no 'still running' note, so a wedged endpoint is
        | indistinguishable from a slow one until the wait expires"
  [ "$silent" = 0 ] || problems="$problems
        | the note fired $silent time(s) on a run whose artifact arrived immediately"
  [ "$junk" = 0 ] || problems="$problems
        | a non-numeric PREFLIGHT_PROGRESS_EVERY printed $junk shell error(s) instead of falling back to the
        | default interval"
  [ "$survived" = 1 ] || problems="$problems
        | a non-numeric PREFLIGHT_PROGRESS_EVERY killed the run instead of being ignored"
  [ "$fired" -le 1 ] || problems="$problems
        | the interval stopped advancing under a leading-zero value: the note fired $fired time(s)"

  if [ -z "$problems" ]; then ok "a review that writes nothing says so while it waits" "REQ-HOOK-47"
  else bad "a review that writes nothing says so while it waits" "REQ-HOOK-47" \
        "a silent phase and a slow one read differently" "see below" "$problems
"; fi
}

case_abnormal_exit_reaps_child() {
  local cfg="$work/reap-cfg" fake="$work/reap-bin" d="$work/reap-repo" pidf="$work/reap.pid" problems=''
  mkdir -p "$fake" "$cfg"
  model_repo "$d"
  printf '[selection]\nmain = "a"\n' > "$cfg/settings.toml"
  printf '[providers.x]\napi_base = "https://one.example/v1"\nkey = "k1"\n\n[profiles.a]\nprovider = "x"\nmodel = "m1"\n' \
    > "$cfg/providers.toml"
  chmod 600 "$cfg/settings.toml" "$cfg/providers.toml"
  printf '#!/bin/sh\nexit 0\n' > "$fake/preflight-gate"; chmod +x "$fake/preflight-gate"

  # A child that outlives this script keeps the caller's stdout pipe open, so `x="$(preflight-code review)"`
  # blocks on the model call after the script itself is gone: the failure is reported against the wrong
  # process, and as a hang rather than an error.
  #
  # The stub reports its OWN pid, and `exec` makes the long sleep BE that process, so the case watches the
  # exact child rather than searching for it by name - a pattern match picks up any other run's stub, and
  # the name is not in the argv `sleep` exposes anyway.
  printf '#!/bin/sh\nprintf "%%s\\n" "$$" > "$PREFLIGHT_REAP_PIDFILE"\nexec sleep 300\n' > "$fake/pr-agent"
  chmod +x "$fake/pr-agent"
  rm -f "$pidf"

  # `exec` in the subshell is what makes `$!` the helper itself rather than a wrapper around it: `kill`
  # must reach the script, or its EXIT trap never runs and the case fails for a reason the fix cannot see.
  ( cd "$d" && exec env PATH="$fake:$PATH" PREFLIGHT_HOME="$cfg" PREFLIGHT_REAP_PIDFILE="$pidf" \
      PREFLIGHT_REVIEW_WAIT=300 PREFLIGHT_PROGRESS_EVERY=600 \
      bash "$repo_root/src/preflight-code" review >/dev/null 2>&1 ) &
  local pf=$! waited=0 child=''
  while [ "$waited" -lt 15 ] && [ ! -s "$pidf" ]; do
    sleep 1; waited=$((waited + 1))
  done
  [ -s "$pidf" ] && child="$(cat "$pidf")"

  if [ -z "$child" ]; then
    problems="$problems
        | the child never started, so this case proved nothing"
    kill -TERM "$pf" 2>/dev/null || true
    wait "$pf" 2>/dev/null || true
  else
    kill -TERM "$pf" 2>/dev/null || true
    wait "$pf" 2>/dev/null || true
    local tries=0 alive=1
    while [ "$tries" -lt 10 ]; do
      if kill -0 "$child" 2>/dev/null; then tries=$((tries + 1)); sleep 1; else alive=0; break; fi
    done
    if [ "$alive" = 1 ]; then
      problems="$problems
        | a review killed mid-flight left its pr-agent running, which holds the caller's output pipe open"
      kill -9 "$child" 2>/dev/null || true
    fi
  fi
  rm -f "$pidf"

  if [ -z "$problems" ]; then ok "an abnormally ended run does not leave pr-agent behind" "REQ-HOOK-48"
  else bad "an abnormally ended run does not leave pr-agent behind" "REQ-HOOK-48" \
        "the child is reaped when the helper dies" "see below" "$problems
"; fi
}

# ---------------------------------------------------------------------------- live end-to-end
# Needs the installed helpers and an API key, so it is skipped when either is absent.

case_e2e_real_review() {
  if ! command -v preflight-code >/dev/null 2>&1; then
    skip "a real review then commit passes end to end" "REQ-HOOK-23" "preflight-code not on PATH"; return
  fi
  # The live case needs a configured endpoint, which means the two config files exist and hold a key.
  _live_cfg="${PREFLIGHT_HOME:-$HOME/.config/preflight}"
  if [ ! -f "$_live_cfg/settings.toml" ] || [ ! -f "$_live_cfg/providers.toml" ]; then
    skip "a real review then commit passes end to end" "REQ-HOOK-23" "no settings.toml/providers.toml"; return
  fi
  # Ask the RESOLVER, not a grep: it validates every provider in the file, so a second provider left at
  # `key = ""` passes a grep for the first one's key and then refuses the render - which would report a
  # failure instead of a skip, for a reason that has nothing to do with what this case tests.
  #
  # Neither rendered file is left behind: the renderer writes the inspectable `.pragent.settings.toml` AND a
  # per-run `.pragent.settings.<pid>.toml`, and only a caller's EXIT trap removes the second. It holds the
  # real key, so the path is captured and removed here rather than left to the next run to rewrite.
  if ! _probe_cfg="$( ( . "$repo_root/scripts/settings-render.sh" \
         && __preflight_render_settings "$_live_cfg" >/dev/null 2>&1 \
         && printf '%s' "$PREFLIGHT_RENDERED_CONFIG" ) 2>/dev/null )" \
     || [ -z "$_probe_cfg" ]; then
    skip "a real review then commit passes end to end" "REQ-HOOK-23" "the config is not reviewable"; return
  fi
  rm -f "$_probe_cfg"
  local d; d="$(new_repo e2e)"
  reset_case "$d"
  printf '\n\ndef sub(a, b):\n    return a - b\n' >> "$d/util.py"
  git -C "$d" add util.py
  if ! ( cd "$d" && preflight-code review ) >/dev/null 2>&1; then
    skip "a real review then commit passes end to end" "REQ-HOOK-23" "review could not run"; return
  fi
  local verdict
  verdict="$(python3 - "$d/.preflight/review.meta.json" <<'PY'
import json, sys
print((json.load(open(sys.argv[1])).get("gate") or {}).get("verdict", ""))
PY
)"
  if [ "$verdict" != "pass" ]; then
    skip "a real review then commit passes end to end" "REQ-HOOK-23" "review verdict was '$verdict'"
    return
  fi
  local got
  git -C "$d" -c commit.gpgsign=false commit -m "feat: sub" >/dev/null 2>&1; got=$?
  if [ "$got" = 0 ]; then ok "a real review then commit passes end to end" "REQ-HOOK-23"
  else bad "a real review then commit passes end to end" "REQ-HOOK-23" 0 "$got" ""; fi

  # The coverage marker's structural half searches only the text after the review's last `</table>`, on
  # the assumption that plain-diff mode renders one. Every other check feeds synthetic tables, so a real
  # review.md is the only place that assumption can be falsified - and if it breaks, the marker goes
  # inert and a partial review reads as complete. Cheap to assert here, where a real review already ran.
  #
  # An ABSENT review.md is a failure, not a skip: this id exists only to make the assumption falsifiable,
  # and a version that reports nothing when the artifact is missing would silently retire the requirement
  # - the same "a guard that did not run proves nothing" rule the selfcheck applies to skips.
  if [ ! -f "$d/.preflight/review.md" ]; then
    bad "a real review renders the table the coverage marker relies on" "REQ-HOOK-30" \
        "a review.md to inspect" "no review.md written" \
        "the review reported a pass but wrote no review.md, so the marker's structural assumption cannot be checked"
  elif grep -q '</table>' "$d/.preflight/review.md"; then
    ok "a real review renders the table the coverage marker relies on" "REQ-HOOK-30"
  else
    bad "a real review renders the table the coverage marker relies on" "REQ-HOOK-30" \
        "a </table> in review.md" "absent" \
        "the coverage marker's structural restriction is inert on real output; re-check src/preflight-code's COVERAGE_RE handling"
  fi
}

# ---------------------------------------------------------------------------- the selfcheck
#
# The suite's headline number answers "did every case pass", which is not the same question as "is the
# hook enforcing". A hook that blocks nothing at all still satisfies every case that asserts *acceptance*
# (a reviewed deletion, commit -a, a reviewed rename) and every case that tests a deliberate bypass, so
# those pass whether or not the hook works.
#
# That is fine per case, but it means a green suite is not on its own evidence that the checks which are
# supposed to refuse a commit still do. Nothing kept the enforcement cases sensitive: someone could add a
# case labelled as an enforcement test that passes with the hook stubbed out, and no check would notice.
#
# `selfcheck` closes that by running this entire suite against a neutered hook (`exit 0`) and requiring
# that exactly the enforcement-sensitive cases fail. It also requires every case to be classified below,
# so a newly added case fails the selfcheck until its author says which kind it is.

# REQ ids whose whole purpose is to catch an unreviewed commit, so a neutered hook must make them fail.
sensitive='REQ-HOOK-01 REQ-HOOK-02 REQ-HOOK-03 REQ-HOOK-04 REQ-HOOK-05 REQ-HOOK-06 REQ-HOOK-11 REQ-HOOK-12
REQ-HOOK-13 REQ-HOOK-16 REQ-HOOK-17 REQ-HOOK-18 REQ-HOOK-19 REQ-HOOK-21 REQ-HOOK-24 REQ-HOOK-25'

# Everything else, grouped by why a neutered hook cannot affect it. Listing them explicitly (rather than
# treating "not sensitive" as a default) is deliberate: an unclassified case must be an error, not an
# oversight that silently joins the insensitive set.
#
#   permissive-by-design  assert that something is NOT blocked, so blocking nothing trivially satisfies
#                         them. They fail if the hook ever over-blocks.
#   bypass                assert the documented escape hatches work.
#   orthogonal            do not test blocking at all, or test a different file.
insensitive='REQ-HOOK-07 REQ-HOOK-08 REQ-HOOK-09 REQ-HOOK-10 REQ-HOOK-14 REQ-HOOK-15 REQ-HOOK-20
REQ-HOOK-22 REQ-HOOK-26 REQ-HOOK-27 REQ-HOOK-28 REQ-HOOK-29 REQ-HOOK-31
REQ-HOOK-32 REQ-HOOK-33 REQ-HOOK-34 REQ-HOOK-35 REQ-HOOK-36 REQ-HOOK-37 REQ-HOOK-38
REQ-HOOK-39 REQ-HOOK-40 REQ-HOOK-41 REQ-HOOK-42 REQ-HOOK-43
REQ-HOOK-44 REQ-HOOK-45 REQ-HOOK-46 REQ-HOOK-47 REQ-HOOK-48 REQ-HOOK-49'

case_selfcheck() {
  # A stub that lets every commit through. Not a copy of the real hook with a line removed: the point is
  # to model "the hook does not enforce", however that came about.
  local stub="$work/selfcheck/neutered-hook"
  mkdir -p "$work/selfcheck"
  printf '#!/bin/sh\nexit 0\n' >"$stub"

  local results="$work/selfcheck/results.tsv" out rc
  : >"$results"
  # The child is invoked with the `hook` group, which never contains `selfcheck`, so this cannot recurse.
  PREFLIGHT_TEST_HOOK="$stub" PREFLIGHT_TEST_RESULTS="$results" \
    sh "$0" hook >"$work/selfcheck/log" 2>&1

  # Ask python3 to do the set arithmetic: it is already a dependency of the suite, and the shell
  # alternative (looping over two lists and grepping) is where this kind of check usually goes wrong.
  out="$(python3 - "$results" "$sensitive" "$insensitive" <<'PY'
import sys

results, sensitive_blob, insensitive_blob = sys.argv[1:4]
sensitive = set(sensitive_blob.split())
insensitive = set(insensitive_blob.split())

seen = {}
try:
    rows = open(results)
except OSError:
    rows = []

for line in rows:
    status, req, name = (line.rstrip("\n").split("\t") + ["", ""])[:3]
    if req:
        seen.setdefault(req, []).append((status, name))

if not seen:
    print("  the child run produced no case results - the suite did not run")
    sys.exit(1)

problems = []
for req in sorted(sensitive):
    entries = seen.get(req)
    if entries is None:
        problems.append(f"{req}: declared enforcement-sensitive but no case ran under that id")
        continue
    for status, name in entries:
        if status == "PASS":
            problems.append(f"{req}: enforcement-sensitive but PASSED with a neutered hook "
                            f"({name}) - it does not actually test enforcement")
        elif status == "SKIP":
            problems.append(f"{req}: enforcement-sensitive but SKIPPED ({name}) - a guard that did "
                            f"not run proves nothing")

for req in sorted(insensitive):
    for status, name in seen.get(req, []):
        if status == "FAIL":
            problems.append(f"{req}: expected to be insensitive to a neutered hook but FAILED "
                            f"({name})")

for req in sorted(set(seen) - sensitive - insensitive):
    problems.append(f"{req}: unclassified - add it to the sensitive or insensitive list in run.sh "
                    f"({'/'.join(n for _, n in seen[req])})")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"{len(sensitive)} enforcement-sensitive, {len(insensitive)} insensitive, "
      f"{len(seen)} ids exercised")
PY
)"; rc=$?

  if [ "$rc" = 0 ]; then
    ok "a neutered hook fails exactly the enforcement-sensitive cases" "REQ-SELF-01"
    printf '        %s\n' "$out"
  else
    bad "a neutered hook fails exactly the enforcement-sensitive cases" "REQ-SELF-01" "0" "$rc" \
        "$(printf '%s\n' "$out" | sed 's/^/        | /')"
  fi
}

# ---------------------------------------------------------------------------- run

run_group() {
  local fn
  for fn in "$@"; do
    case "$fn" in
      e2e_real_review) case_e2e_real_review ;;
      *) "$fn" ;;
    esac
  done
}

say "preflight-code hook integration tests"
say ""

if [ "$which_cases" = "all" ] || [ "$which_cases" = "hook" ]; then
  say "hook enforcement (offline)"
  run_group \
    case_block_edit_after_review \
    case_block_new_file \
    case_block_git_rm \
    case_block_cached_remove \
    case_block_rename \
    case_block_typechange \
    case_block_quoted_name_deletion \
    case_block_gitlink_removal \
    case_pass_commit_a_with_scratch \
    case_pass_reviewed_deletion \
    case_pass_reviewed_rename \
    case_pass_no_changes \
    case_block_no_review \
    case_block_failed_verdict \
    case_block_corrupt_sidecar \
    case_bypass_no_verify \
    case_bypass_skip_env \
    case_head_scope_not_enforced \
    case_bootstrap_first_commit \
    case_second_commit_is_enforced \
    case_hook_is_read_only \
    case_artifacts_survive_a_block \
    case_worktree_enforced \
    case_missing_helper_fails_closed \
    case_missing_helper_fails_closed_unset_home \
    case_post_commit_advisory \
    case_convergence_signal \
    case_coverage_marker_matches_real_footer \
    case_summary_wiring \
    case_verdict_fields \
    case_fallback_model_signal \
    case_partial_review_announced_in_commit_scope \
    case_bounded_shutdown \
    case_run_history \
    case_scope_defaults \
    case_commit_scope_reviews_untracked \
    case_bundle_hooks_executable \
    case_gate_doc_advisory \
    case_gate_config \
    case_review_context \
    case_model_configuration \
    case_model_configuration_refusals \
    case_pr_rendered_config_removed \
    case_review_progress_note \
    case_abnormal_exit_reaps_child \
    case_pr_abnormal_exit_reaps_child
  say ""
fi

if [ "$which_cases" = "all" ] || [ "$which_cases" = "e2e" ]; then
  say "live end-to-end (needs the installed helpers and a key)"
  run_group case_e2e_real_review
  say ""
fi

if [ "$which_cases" = "all" ] || [ "$which_cases" = "selfcheck" ]; then
  say "selfcheck (the enforcement cases must fail against a neutered hook)"
  run_group case_selfcheck
  say ""
fi

say "$pass passed, $fail failed, $skipped skipped"
[ "$fail" = 0 ] || exit 1
# Nothing ran and nothing failed would be indistinguishable from success in a CI log.
[ "$((pass + fail + skipped))" -gt 0 ] || { echo "tests: no cases ran" >&2; exit 2; }
exit 0
