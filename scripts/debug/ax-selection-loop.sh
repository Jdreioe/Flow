#!/bin/zsh

set -euo pipefail

readonly flow_app="/tmp/flow-trace-derived-data/Build/Products/Debug/Flow.app"
readonly flow_executable="/private/tmp/flow-trace-derived-data/Build/Products/Debug/Flow.app/Contents/MacOS/Flow"
readonly zen_executable="/Applications/Zen.app/Contents/MacOS/zen"
readonly fixture="$(cd "$(dirname "$0")" && pwd)/ax-selection-fixture.html"
readonly capture_delay="${1:-3}"
readonly selection_mode="${2:-early}"
readonly retry_delay="${3:-3}"
readonly force_accessibility="${4:-false}"
readonly fixture_url="file://${fixture}?mode=${selection_mode}"
readonly zen_profile="$(mktemp -d /tmp/flow-ax-zen-profile.XXXXXX)"
zen_pid=""

cleanup() {
  if [[ -n "$zen_pid" ]] && kill -0 "$zen_pid" 2>/dev/null; then
    kill "$zen_pid"
    wait "$zen_pid" 2>/dev/null || true
  fi
  if [[ "$zen_profile" == /tmp/flow-ax-zen-profile.* ]]; then
    rm -rf -- "$zen_profile"
  fi
}
trap cleanup EXIT

if [[ "$force_accessibility" == "true" ]]; then
  cp "$(dirname "$0")/zen-force-accessibility.js" "$zen_profile/user.js"
fi

if [[ ! -x "$flow_app/Contents/MacOS/Flow" ]]; then
  print -u2 "Missing trace build at $flow_app"
  exit 2
fi

terminate_exact_processes() {
  local executable="$1"
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    print "Stopping pid=$pid executable=$executable"
    kill "$pid"
  done < <(ps -Ao pid=,command= | awk -v executable="$executable" '$2 == executable { print $1 }')
}

terminate_exact_processes "$zen_executable"
terminate_exact_processes "$flow_executable"
sleep 1

open -n "$flow_app"
sleep 0.5
"$zen_executable" -no-remote -profile "$zen_profile" "$fixture_url" >/dev/null 2>&1 &
zen_pid="$!"
sleep "$capture_delay"

open -a Zen
sleep 0.2
xcrun swift -e \
  'import Foundation; DistributedNotificationCenter.default().post(name: Notification.Name("com.hojmoseit.flow.debug.capture-selection"), object: nil)'
sleep "$retry_delay"
open -a Zen
sleep 0.2
xcrun swift -e \
  'import Foundation; DistributedNotificationCenter.default().post(name: Notification.Name("com.hojmoseit.flow.debug.capture-selection"), object: nil)'
sleep 0.5

readonly trace_path="$(find /private/var/folders -name flow-axfull.jsonl -type f -print 2>/dev/null | head -n 1)"
if [[ -z "$trace_path" ]]; then
  print -u2 "Trace file was not created"
  exit 2
fi

readonly first_result="$(jq -r 'select(.event == "capture_finished") | .result' "$trace_path" | head -n 1)"
readonly last_result="$(jq -r 'select(.event == "capture_finished") | .result' "$trace_path" | tail -n 1)"
readonly non_zen_captures="$(jq -s '[
  .[] | select(.event == "capture_started" and .bundle != "app.zen-browser.zen")
] | length' "$trace_path")"
jq -c 'select(
  .event == "flow_started" or
  .event == "prepare" or
  .event == "capture_started" or
  .event == "capture_finished"
)' "$trace_path"

if [[ "$non_zen_captures" == 0 && "$selection_mode" == "early" && "$first_result" != success_* && "$last_result" == success_* ]]; then
  print "PASS first=$first_result after_reselection=$last_result"
  exit 0
fi

if [[ "$non_zen_captures" == 0 && "$selection_mode" == "late" && "$first_result" == success_* ]]; then
  print "PASS first_after_ax=$first_result"
  exit 0
fi

if [[ "$non_zen_captures" == 0 && "$force_accessibility" == "true" && "$first_result" == success_* ]]; then
  print "PASS forced_accessibility_first=$first_result"
  exit 0
fi

if [[ "$non_zen_captures" == 0 && "$selection_mode" == "early-sticky" && "$first_result" != success_* && "$last_result" == success_* ]]; then
  print "PASS first=$first_result repeated_without_reselection=$last_result retry_delay=$retry_delay"
  exit 0
fi

print -u2 "FAIL first=${first_result:-missing} after_reselection=${last_result:-missing} non_zen_captures=$non_zen_captures"
exit 1
