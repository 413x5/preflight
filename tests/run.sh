#!/usr/bin/env bash
# Integration tests for the preflight commit hook.
#
#   tests/run.sh              # run everything (a few minutes)
#   tests/run.sh hook         # only the hook cases
#   tests/run.sh e2e          # only the live-endpoint cases
#   tests/run.sh selfcheck    # only the selfcheck: the suite re-run against a neutered hook
#
# They exercise the REAL hook files from files/, against real git repositories, with no network and no
# API key. That matters: everything here was written to catch a specific regression that a unit test
# of the comparison logic would have missed, because the bugs lived in how git reports a staged change
# (a rename is not "A" or "M", a gitlink is not a blob, a scratch file shows up as a deletion).
#
# A small scratch index per case replaces a real `preflight review`: the tests write the sidecar that
# a worktree-scope review would have written, using the same scratch-index method preflight itself
# uses. That keeps the suite offline and deterministic, and keeps the tested logic the real thing.
#
# Traceability: every case declares the requirement it guards - `[REQ-HOOK-nn]` for a hook case,
# `[REQ-SELF-nn]` for the selfcheck itself - and the mapping is listed in tests/README.md. A case that
# fails names its requirement in the output.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
hook="${PREFLIGHT_TEST_HOOK:-$repo_root/files/preflight-hook}"

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
  cp "$repo_root/files/githooks/pre-commit" "$d/.githooks/pre-commit"
  chmod +x "$d/.githooks/pre-commit"
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
  # `preflight review` cannot run before a first commit exists, so blocking the first commit would
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
  # The second bundled hook (files/githooks/post-commit). It cannot block anything - a post-commit
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
  cp "$repo_root/files/githooks/post-commit" "$d/.githooks/post-commit"
  chmod +x "$d/.githooks/post-commit"
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

  # A worktree-scope review is the enforced case, so nothing to say.
  set_meta '{"scope": "worktree", "reviewed_tree": "abc"}'
  out="$(run_post)"
  [ -z "$out" ] || problems="$problems
        | worktree scope should be silent, got: $out"

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

case_coverage_marker_matches_real_footer() {
  # Two things only the INSTALLED pr-agent can settle, and both fail silently:
  #
  # 1. The coverage marker. `preflight` prints `coverage=PARTIAL` by matching pr-agent's footer in
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
    skip "the completeness keys sit in the section pr-agent reads" "REQ-HOOK-29" "pr-agent not installed"
    return
  fi

  # Drive the SHIPPED summary-line block over fixtures, so this tests behaviour rather than restating
  # the logic: extract the heredoc body from files/preflight and run it.
  if python3 - "$repo_root/files/preflight" "$sp/tools/pr_reviewer.py" <<'PY'
import re, subprocess, sys, tempfile, os

helper, reviewer = sys.argv[1:3]
src = open(helper, encoding="utf-8").read()
blocks = re.findall(r"python3 - \"\$out_json\" \"\$out_md\" <<'PY'[^\n]*\n(.*?)\nPY\n", src, re.S)
if not blocks:
    sys.exit("cannot find the summary-line block in files/preflight; update this case")
d = tempfile.mkdtemp()
json_path = os.path.join(d, "review.json")
open(json_path, "w").write('{"review":{"key_issues_to_review":[]}}')
script = os.path.join(d, "summary.py")
open(script, "w").write(blocks[-1])

def summary(body):
    md = os.path.join(d, "review.md")
    open(md, "w", encoding="utf-8").write(body)
    return subprocess.run([sys.executable, script, json_path, md],
                          capture_output=True, text=True).stdout

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
footer = "".join(lits).replace("\\n", "\n").replace('\\"', '"') + "- `late.py`"

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

  # Part 2: the completeness keys must be in the table pr-agent actually reads them from.
  if python3 - "$sp/settings/configuration.toml" "$repo_root/files/preflight.toml" <<'PY'
import re, sys, tomllib

defaults_path, ours_path = sys.argv[1:3]

# Where pr-agent's OWN defaults declare each key: the ground truth for which section it reads.
wanted = ("num_max_findings", "extra_instructions", "enable_large_pr_chunking", "max_number_of_calls")
sections = {}
section = None
for line in open(defaults_path, encoding="utf-8", errors="replace"):
    m = re.match(r"^\[(\w+)\]", line)
    if m:
        section = m.group(1)
    m = re.match(r"^(\w+)\s*=", line)
    if m and m.group(1) in wanted and m.group(1) not in sections:
        sections[m.group(1)] = section

wrong = [k for k in wanted if sections.get(k) != "pr_reviewer"]
if wrong:
    print("pr-agent no longer reads these from [pr_reviewer]: " + ", ".join(wrong))
    sys.exit(2)

ours = tomllib.load(open(ours_path, "rb"))
missing = [k for k in wanted if k not in ours.get("pr_reviewer", {})]
if missing:
    print("files/preflight.toml does not set these under [pr_reviewer]: " + ", ".join(missing))
    sys.exit(3)
PY
  then ok "the completeness keys sit in the section pr-agent reads" "REQ-HOOK-29"
  else bad "the completeness keys sit in the section pr-agent reads" "REQ-HOOK-29" \
        "each key under [pr_reviewer]" "not where pr-agent reads it" \
        "a completeness key is in the wrong table or was renamed upstream, so the finding cap or chunking is silently inert while every check stays green"
  fi
}

# ---------------------------------------------------------------------------- live end-to-end
# Needs the installed helpers and an API key, so it is skipped when either is absent.

case_e2e_real_review() {
  if ! command -v preflight >/dev/null 2>&1; then
    skip "a real review then commit passes end to end" "REQ-HOOK-23" "preflight not on PATH"; return
  fi
  if [ ! -f "${PREFLIGHT_HOME:-$HOME/.config/preflight}/.secrets.toml" ]; then
    skip "a real review then commit passes end to end" "REQ-HOOK-23" "no configured key"; return
  fi
  local d; d="$(new_repo e2e)"
  reset_case "$d"
  printf '\n\ndef sub(a, b):\n    return a - b\n' >> "$d/util.py"
  git -C "$d" add util.py
  if ! ( cd "$d" && preflight review ) >/dev/null 2>&1; then
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
        "the coverage marker's structural restriction is inert on real output; re-check files/preflight's COVERAGE_RE handling"
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
REQ-HOOK-22 REQ-HOOK-26 REQ-HOOK-27 REQ-HOOK-28 REQ-HOOK-29'

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

say "preflight hook integration tests"
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
    case_coverage_marker_matches_real_footer
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
