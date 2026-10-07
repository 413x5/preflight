#!/usr/bin/env bash
# Integration tests for the preflight commit hook.
#
#   tests/run.sh              # run everything (a few minutes)
#   tests/run.sh hook         # only the hook cases
#   tests/run.sh e2e          # only the live-endpoint cases
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
# Traceability: every case declares the requirement it guards, as [REQ-HOOK-nn], and the mapping is
# listed in tests/README.md. A case that fails names its requirement in the output.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
hook="$repo_root/files/preflight-hook"

which_cases="${1:-all}"
pass=0; fail=0; skipped=0

# Reject an unrecognized group rather than running nothing and reporting success. A typo in a CI step
# (`./tests/run.sh hok`) would otherwise exit 0 with "0 passed" and look green.
case "$which_cases" in
  all|hook|e2e) ;;
  *) echo "tests: unknown case group '$which_cases' (expected one of: all, hook, e2e)" >&2; exit 2 ;;
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

ok()   { printf '  %sPASS%s  %s  [%s]\n' "$c_pass" "$c_off" "$1" "$2"; pass=$((pass+1)); }
bad()  { printf '  %sFAIL%s  %s  [%s]\n        expected exit %s, got %s\n%s' \
           "$c_fail" "$c_off" "$1" "$2" "$3" "$4" "${5:-}"; fail=$((fail+1)); }
skip() { printf '  %sSKIP%s  %s  (%s)\n' "$c_skip" "$c_off" "$1" "$2"; skipped=$((skipped+1)); }

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
  [ -f "$d/src/guard.py" ] || { skip "git rm --cached of a nested reviewed file is blocked" "fixture"; return; }
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
    skip "removing a gitlink without reviewing it is blocked" "submodule fixture unavailable"
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
    skip "the hook enforces inside a linked worktree" "worktree unsupported here"; return
  fi
  if [ ! -f "$wt/.githooks/pre-commit" ]; then
    skip "the hook enforces inside a linked worktree" "hooks not present in the worktree"
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

# ---------------------------------------------------------------------------- live end-to-end
# Needs the installed helpers and an API key, so it is skipped when either is absent.

case_e2e_real_review() {
  if ! command -v preflight >/dev/null 2>&1; then
    skip "a real review then commit passes end to end" "preflight not on PATH"; return
  fi
  if [ ! -f "${PREFLIGHT_HOME:-$HOME/.config/preflight}/.secrets.toml" ]; then
    skip "a real review then commit passes end to end" "no configured key"; return
  fi
  local d; d="$(new_repo e2e)"
  reset_case "$d"
  printf '\n\ndef sub(a, b):\n    return a - b\n' >> "$d/util.py"
  git -C "$d" add util.py
  if ! ( cd "$d" && preflight review ) >/dev/null 2>&1; then
    skip "a real review then commit passes end to end" "review could not run"; return
  fi
  local verdict
  verdict="$(python3 - "$d/.preflight/review.meta.json" <<'PY'
import json, sys
print((json.load(open(sys.argv[1])).get("gate") or {}).get("verdict", ""))
PY
)"
  if [ "$verdict" != "pass" ]; then
    skip "a real review then commit passes end to end" "review verdict was '$verdict'"
    return
  fi
  local got
  git -C "$d" -c commit.gpgsign=false commit -m "feat: sub" >/dev/null 2>&1; got=$?
  if [ "$got" = 0 ]; then ok "a real review then commit passes end to end" "REQ-HOOK-23"
  else bad "a real review then commit passes end to end" "REQ-HOOK-23" 0 "$got" ""; fi
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
    case_missing_helper_fails_closed_unset_home
  say ""
fi

if [ "$which_cases" = "all" ] || [ "$which_cases" = "e2e" ]; then
  say "live end-to-end (needs the installed helpers and a key)"
  run_group case_e2e_real_review
  say ""
fi

say "$pass passed, $fail failed, $skipped skipped"
[ "$fail" = 0 ] || exit 1
# Nothing ran and nothing failed would be indistinguishable from success in a CI log.
[ "$((pass + fail + skipped))" -gt 0 ] || { echo "tests: no cases ran" >&2; exit 2; }
exit 0
