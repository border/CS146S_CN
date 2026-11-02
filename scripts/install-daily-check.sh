#!/bin/bash
# Install (or remove) a macOS LaunchAgent that runs sync-upstream.sh --notify
# every day at 09:30. If the Mac is asleep at 09:30, launchd runs it on wake.
#
# Usage:
#   scripts/install-daily-check.sh             install / reinstall
#   scripts/install-daily-check.sh --uninstall remove
#   scripts/install-daily-check.sh --print     print the plist without installing
set -eu

readonly LABEL="com.cs146s-cn.sync-upstream"
readonly HOUR=9
readonly MINUTE=30
readonly PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly LOG_FILE="$HOME/Library/Logs/cs146s-sync.log"
readonly DOMAIN="gui/$(id -u)"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/scripts/sync-upstream.sh"

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

render_plist() {
  local script repo log
  script="$(xml_escape "$SCRIPT")"
  repo="$(xml_escape "$REPO")"
  log="$(xml_escape "$LOG_FILE")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$script</string>
    <string>--notify</string>
    <string>--repo</string>
    <string>$repo</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$HOUR</integer>
    <key>Minute</key>
    <integer>$MINUTE</integer>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <!-- sync-upstream.sh writes its own log; keep only stderr (git errors) here -->
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>$log</string>
</dict>
</plist>
EOF
}

uninstall() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "已移除定时任务 $LABEL"
}

# bootout returns before the old job is fully unloaded; bootstrap may fail briefly.
bootstrap_with_retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && return 0
    sleep 1
  done
  launchctl bootstrap "$DOMAIN" "$PLIST"
}

install() {
  [ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT" >&2; exit 1; }
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")"
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  render_plist >"$PLIST"
  plutil -lint "$PLIST" >/dev/null
  bootstrap_with_retry
  printf '已安装：每天 %02d:%02d 同步上游到 %s\n' "$HOUR" "$MINUTE" "$REPO"
  echo "plist：$PLIST"
  echo "日志：$LOG_FILE"
  echo "立即试跑：launchctl kickstart $DOMAIN/$LABEL"
}

case "${1:-}" in
  "") install ;;
  --uninstall) uninstall ;;
  --print) render_plist ;;
  *) echo "用法：$0 [--uninstall|--print]" >&2; exit 1 ;;
esac
