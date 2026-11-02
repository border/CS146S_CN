#!/bin/bash
# Scenario tests for scripts/sync-upstream.sh.
# Builds a throwaway "upstream" repo and a clone in a temp dir for each case.
# Run with: /bin/bash scripts/tests/test-sync-upstream.sh
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/sync-upstream.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export SYNC_NOTIFY_STDOUT=1   # print notifications instead of calling osascript
export SYNC_FETCH_RETRIES=2 SYNC_FETCH_DELAY=0

commit_file() { # repo file content message
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add "$2" && git -C "$1" commit -qm "$4"
}

# Creates $case/up (upstream) and $case/local (clone wired with "upstream" remote).
setup_case() {
  local dir="$WORK/$1"
  mkdir -p "$dir/up"
  git -C "$dir/up" init -q -b main
  commit_file "$dir/up" a.txt base "base"
  git clone -q "$dir/up" "$dir/local"
  git -C "$dir/local" remote add upstream "$dir/up"
  echo "$dir"
}

run_sync() { # dir [extra args...]
  local dir="$1"; shift
  OUT="$(SYNC_UPSTREAM_URL="$dir/up" SYNC_LOG_FILE="$dir/sync.log" \
    /bin/bash "$SCRIPT" --repo "$dir/local" "$@" 2>&1)"
  CODE=$?
}

check() { # name condition-result
  if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1"; echo "$OUT" | sed 's/^/       | /'; fi
}

contains() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

echo "case: up to date -> no notification"
d=$(setup_case uptodate)
run_sync "$d" --notify
check "exit 0" $([ $CODE -eq 0 ]; echo $?)
check "no NOTIFY" $(! contains "NOTIFY:"; echo $?)
check "log written" $([ -s "$d/sync.log" ]; echo $?)

echo "case: fast-forward"
d=$(setup_case ff)
commit_file "$d/up" b.txt new "feat: upstream change"
run_sync "$d" --notify
check "exit 0" $([ $CODE -eq 0 ]; echo $?)
check "notifies merged count" $(contains "NOTIFY: 已合并 1 个上游提交"; echo $?)
check "notifies subject" $(contains "feat: upstream change"; echo $?)
check "local has file" $([ -f "$d/local/b.txt" ]; echo $?)

echo "case: diverged -> merge commit"
d=$(setup_case diverged)
commit_file "$d/up" b.txt up "up change"
commit_file "$d/local" c.txt local "local change"
run_sync "$d" --notify
check "exit 0" $([ $CODE -eq 0 ]; echo $?)
check "merge commit created" $([ "$(git -C "$d/local" rev-list --parents -1 HEAD | wc -w | tr -d ' ')" = 3 ]; echo $?)
check "both files present" $([ -f "$d/local/b.txt" ] && [ -f "$d/local/c.txt" ]; echo $?)

echo "case: conflict -> abort and notify"
d=$(setup_case conflict)
commit_file "$d/up" a.txt upstream-version "up edit"
commit_file "$d/local" a.txt local-version "local edit"
before=$(git -C "$d/local" rev-parse HEAD)
run_sync "$d" --notify
check "exit 3" $([ $CODE -eq 3 ]; echo $?)
check "notifies conflict" $(contains "冲突"; echo $?)
check "merge aborted (no MERGE_HEAD)" $([ ! -f "$d/local/.git/MERGE_HEAD" ]; echo $?)
check "HEAD unchanged" $([ "$(git -C "$d/local" rev-parse HEAD)" = "$before" ]; echo $?)
check "worktree clean" $([ -z "$(git -C "$d/local" status --porcelain)" ]; echo $?)

echo "case: conflict in manual mode -> left in conflict state"
d=$(setup_case conflict-manual)
commit_file "$d/up" a.txt upstream-version "up edit"
commit_file "$d/local" a.txt local-version "local edit"
run_sync "$d"
check "exit 3" $([ $CODE -eq 3 ]; echo $?)
check "MERGE_HEAD kept for manual resolution" $([ -f "$d/local/.git/MERGE_HEAD" ]; echo $?)
check "lists conflicted file" $(contains "a.txt"; echo $?)

echo "case: dirty worktree -> skip and notify"
d=$(setup_case dirty)
commit_file "$d/up" b.txt new "up change"
printf 'wip\n' >>"$d/local/a.txt"
run_sync "$d" --notify
check "exit 2" $([ $CODE -eq 2 ]; echo $?)
check "notifies uncommitted" $(contains "未提交"; echo $?)
check "not merged" $([ ! -f "$d/local/b.txt" ]; echo $?)

echo "case: not on main -> skip and notify"
d=$(setup_case branch)
commit_file "$d/up" b.txt new "up change"
git -C "$d/local" checkout -qb feature
run_sync "$d" --notify
check "exit 2" $([ $CODE -eq 2 ]; echo $?)
check "notifies branch" $(contains "feature"; echo $?)

echo "case: upstream remote missing -> added"
d=$(setup_case addremote)
git -C "$d/local" remote remove upstream
run_sync "$d" --notify
check "exit 0" $([ $CODE -eq 0 ]; echo $?)
check "remote added" $([ "$(git -C "$d/local" remote get-url upstream)" = "$d/up" ]; echo $?)

echo "case: upstream remote points elsewhere -> error"
d=$(setup_case wrongurl)
git -C "$d/local" remote set-url upstream "$WORK/nowhere"
run_sync "$d" --notify
check "exit 1" $([ $CODE -eq 1 ]; echo $?)
check "notifies error" $(contains "NOTIFY:"; echo $?)

echo "case: fetch failure -> error notification"
d=$(setup_case fetchfail)
rm -rf "$d/up"
run_sync "$d" --notify
check "exit 1" $([ $CODE -eq 1 ]; echo $?)
check "notifies fetch failure" $(contains "fetch"; echo $?)
check "retried fetch" $(contains "fetch attempt 1 failed"; echo $?)

echo "case: merge stops without conflict (hook fails) -> error, not conflict"
d=$(setup_case hookfail)
commit_file "$d/up" b.txt up "up change"
commit_file "$d/local" c.txt local "local change"
printf '#!/bin/sh\nexit 1\n' >"$d/local/.git/hooks/pre-merge-commit"
chmod +x "$d/local/.git/hooks/pre-merge-commit"
before=$(git -C "$d/local" rev-parse HEAD)
run_sync "$d" --notify
check "exit 1" $([ $CODE -eq 1 ]; echo $?)
check "not reported as conflict" $(! contains "存在冲突"; echo $?)
check "notifies failure" $(contains "NOTIFY: 同步失败"; echo $?)
check "merge aborted (no MERGE_HEAD)" $([ ! -f "$d/local/.git/MERGE_HEAD" ]; echo $?)
check "HEAD unchanged" $([ "$(git -C "$d/local" rev-parse HEAD)" = "$before" ]; echo $?)

echo "case: merged commits are listed in the log"
d=$(setup_case logged)
commit_file "$d/up" b.txt new "feat: logged change"
run_sync "$d" --notify
check "log lists merged commit" $(grep -q "feat: logged change" "$d/sync.log"; echo $?)

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
