#!/bin/bash
# Sync the original course repo (upstream) into the local branch.
#
# Usage:
#   scripts/sync-upstream.sh [--notify] [--branch NAME] [--repo DIR]
#
#   --notify   scheduled mode: show a macOS notification when something was
#              merged, skipped or failed (silent when already up to date), and
#              abort the merge on conflict so the repo is never left half-merged.
#   --branch   local branch to update (default: main; upstream branch has the same name)
#   --repo     repository path (default: the repo containing this script)
#
# Exit codes: 0 up to date / merged, 1 error, 2 skipped (dirty or wrong branch), 3 conflict.
# Never pushes to origin.
#
# Environment overrides (mainly for tests):
#   SYNC_UPSTREAM_URL    upstream URL (default: the Lucaswang81 GitHub repo)
#   SYNC_LOG_FILE        log path (default: ~/Library/Logs/cs146s-sync.log)
#   SYNC_NOTIFY_STDOUT=1 print "NOTIFY: ..." instead of calling osascript
#   SYNC_FETCH_RETRIES   fetch attempts before giving up (default: 3)
#   SYNC_FETCH_DELAY     seconds between fetch attempts (default: 30)

set -u

readonly DEFAULT_UPSTREAM_URL="https://github.com/Lucaswang81/CS146S_CN.git"
readonly UPSTREAM_REMOTE="upstream"
readonly NOTIFY_TITLE="CS146S_CN 上游同步"

# Unattended run: never prompt for credentials, give up on a stalled transfer.
export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=60

UPSTREAM_URL="${SYNC_UPSTREAM_URL:-$DEFAULT_UPSTREAM_URL}"
LOG_FILE="${SYNC_LOG_FILE:-$HOME/Library/Logs/cs146s-sync.log}"
FETCH_RETRIES="${SYNC_FETCH_RETRIES:-3}"
FETCH_DELAY="${SYNC_FETCH_DELAY:-30}"
BRANCH="main"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY=0

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$line"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  echo "$line" >>"$LOG_FILE" 2>/dev/null || true
}

# Only notifies in --notify mode; message is passed as argv so quotes are safe.
notify() {
  [ "$NOTIFY" -eq 1 ] || return 0
  if [ "${SYNC_NOTIFY_STDOUT:-0}" = "1" ]; then
    echo "NOTIFY: $1"
    return 0
  fi
  osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
    -e 'end run' "$1" "$NOTIFY_TITLE" >/dev/null 2>&1 || log "WARN: osascript notification failed"
}

fail() { # exit-code message
  log "ERROR: $2"
  notify "同步失败：$2"
  exit "$1"
}

skip() {
  log "SKIP: $1"
  notify "上游有更新但未合并：$1"
  exit 2
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --notify) NOTIFY=1 ;;
      --branch) [ $# -ge 2 ] || fail 1 "--branch 缺少参数"; BRANCH="$2"; shift ;;
      --repo) [ $# -ge 2 ] || fail 1 "--repo 缺少参数"; REPO="$2"; shift ;;
      -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) fail 1 "未知参数：$1" ;;
    esac
    shift
  done
}

ensure_upstream_remote() {
  local current
  if ! current="$(git remote get-url "$UPSTREAM_REMOTE" 2>/dev/null)"; then
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL" || fail 1 "无法添加 $UPSTREAM_REMOTE 远端"
    log "added remote $UPSTREAM_REMOTE -> $UPSTREAM_URL"
  elif [ "$current" != "$UPSTREAM_URL" ]; then
    fail 1 "$UPSTREAM_REMOTE 远端指向 ${current}，预期 $UPSTREAM_URL"
  fi
}

# Retries cover the minutes right after wake when the network is not back yet.
fetch_upstream() {
  local attempt=1
  while ! git fetch --quiet "$UPSTREAM_REMOTE"; do
    [ "$attempt" -ge "$FETCH_RETRIES" ] && return 1
    log "fetch attempt $attempt failed, retrying in ${FETCH_DELAY}s"
    sleep "$FETCH_DELAY"
    attempt=$((attempt + 1))
  done
}

# Conflict: in --notify mode roll back; in manual mode leave it for the user.
handle_conflict() {
  local files
  files="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
  if [ -z "$files" ]; then
    # Merge stopped for another reason (e.g. hook or commit signing failed).
    [ "$NOTIFY" -eq 1 ] && git merge --abort
    fail 1 "git merge 未完成（非冲突原因，如钩子或签名失败），详见日志"
  fi
  if [ "$NOTIFY" -eq 1 ]; then
    git merge --abort
    log "CONFLICT: $files (merge aborted)"
    notify "上游有更新但存在冲突（${files}），已撤销合并，请手动运行 scripts/sync-upstream.sh 处理"
  else
    log "CONFLICT: $files"
    echo "合并冲突文件：$files"
    echo "解决后执行 git add <文件> && git commit；放弃合并执行 git merge --abort"
  fi
  exit 3
}

main() {
  parse_args "$@"
  cd "$REPO" 2>/dev/null || fail 1 "仓库目录不存在：$REPO"
  git rev-parse --git-dir >/dev/null 2>&1 || fail 1 "不是 git 仓库：$REPO"

  ensure_upstream_remote
  fetch_upstream || fail 1 "git fetch $UPSTREAM_REMOTE 失败（网络或权限问题）"

  local target="$UPSTREAM_REMOTE/$BRANCH"
  git rev-parse --verify --quiet "$target" >/dev/null || fail 1 "上游不存在分支 $BRANCH"

  local count
  count="$(git rev-list --count "$BRANCH..$target" 2>/dev/null)" || fail 1 "本地不存在分支 $BRANCH"
  if [ "$count" -eq 0 ]; then
    log "up to date with $target"
    exit 0
  fi

  local current
  current="$(git symbolic-ref --quiet --short HEAD || echo DETACHED)"
  [ "$current" = "$BRANCH" ] || skip "当前在 $current 分支，不是 ${BRANCH}（${count} 个新提交待合并）"
  [ -z "$(git status --porcelain --untracked-files=no)" ] \
    || skip "工作区有未提交的改动（$count 个新提交待合并）"

  local subject old_head
  subject="$(git log -1 --format=%s "$target")"
  old_head="$(git rev-parse HEAD)"
  if ! git merge --no-edit "$target"; then
    [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] && handle_conflict
    fail 1 "git merge $target 失败"
  fi

  log "merged $count commit(s) from $target:"
  git log --oneline "$old_head..HEAD" | while read -r line; do log "  $line"; done
  notify "已合并 $count 个上游提交，最新：$subject"
}

main "$@"
