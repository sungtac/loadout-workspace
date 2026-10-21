#!/usr/bin/env bash
# native_worker_receipt.sh — Claude native Task 호출의 Hub 영수증 경계.
# 사용:
#   native_worker_receipt.sh start <role> <brief>
#   native_worker_receipt.sh complete <brief> <dispatch-id> <status> [return-code]
# start의 JSON dispatch_id를 native Task 호출 뒤 complete에 그대로 넘긴다.
set -euo pipefail

die() { echo "native_worker_receipt: $1" >&2; exit "${2:-1}"; }
ACTION="${1:-}"; shift || true
ROLE=""; BRIEF=""
case "$ACTION" in
  start) ROLE="${1:-}"; BRIEF="${2:-}"; [ -n "$ROLE" ] && [ -n "$BRIEF" ] || die "usage: start <role> <brief>" 64 ;;
  complete) BRIEF="${1:-}"; DISPATCH_ID="${2:-}"; STATUS="${3:-}"; RETURN_CODE="${4:-}"; [ -n "$BRIEF" ] && [ -n "$DISPATCH_ID" ] && [ -n "$STATUS" ] || die "usage: complete <brief> <dispatch-id> <status> [return-code]" 64 ;;
  *) die "action must be start or complete" 64 ;;
esac

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${MULTIAGENT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
ROOT="$(cd "$ROOT" && pwd -P)"
command -v jq >/dev/null 2>&1 || die "jq 필요(JSON 파싱)" 5
[ -f "$BRIEF" ] || die "brief 파일 없음: $BRIEF" 6
BRIEF="$(cd "$(dirname -- "$BRIEF")" && pwd -P)/$(basename -- "$BRIEF")"

gate_json="$(MULTIAGENT_ROOT="$ROOT" bash "$SCRIPT_DIR/gate.sh" --json "$BRIEF")" || die "게이트 거부" 9
TASK="$(jq -r .task <<<"$gate_json")"; GATE_ROLE="$(jq -r .role <<<"$gate_json")"
[ "$ACTION" != start ] || [ "$ROLE" = "$GATE_ROLE" ] || die "역할 불일치: brief=$GATE_ROLE, 요청=$ROLE" 9

BRIDGE="$ROOT/_local/agent-hub-bridge.json"
HUB_ROOT="${AGENT_HUB_ROOT:-}"; HUB_CLI="${AGENT_HUB_CLI:-}"
[ -n "$HUB_ROOT" ] || [ -f "$BRIDGE" ] || die "Agent Hub bridge 미설정" 5
[ -n "$HUB_ROOT" ] || HUB_ROOT="$(jq -r '.hub_root // empty' "$BRIDGE")"
[ -n "$HUB_CLI" ] || HUB_CLI="$(jq -r '.cli // "agent-hub"' "$BRIDGE" 2>/dev/null || true)"
[ -n "$HUB_CLI" ] || HUB_CLI="agent-hub"
[ -x "$HUB_CLI" ] || command -v "$HUB_CLI" >/dev/null 2>&1 || die "Agent Hub CLI를 찾을 수 없음" 5
TASKMD="$ROOT/tasks/$TASK/task.md"
HUB_TASK_ID="$(grep -m1 -E '^[[:space:]]*agent_hub_task_id:' "$TASKMD" | sed -E 's/^[[:space:]]*agent_hub_task_id:[[:space:]]*//; s/[[:space:]]+#.*$//')"
case "$HUB_TASK_ID" in task-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) die "task.md agent_hub_task_id가 유효하지 않음" 5;; esac

if [ "$ACTION" = start ]; then
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum 필요" 5
  fingerprint="$({ printf '%s\0' "$ROLE"; cat -- "$BRIEF"; } | sha256sum | awk '{print $1}')"
  "$HUB_CLI" gateway --hub-root "$HUB_ROOT" reserve-external --task-id "$HUB_TASK_ID" --channel loadout-native --maximum 32 --fingerprint "$fingerprint" --provider claude
  exit 0
fi

case "$STATUS" in succeeded|failed|timed_out|empty|scope_violation) ;; *) die "허용되지 않는 status: $STATUS" 64;; esac
if [ -n "$RETURN_CODE" ]; then case "$RETURN_CODE" in *[!0-9-]*|'') die "return-code는 정수여야 함" 64;; esac; fi
args=(gateway --hub-root "$HUB_ROOT" complete-external --task-id "$HUB_TASK_ID" --dispatch-id "$DISPATCH_ID" --status "$STATUS")
[ -n "$RETURN_CODE" ] && args+=(--return-code "$RETURN_CODE")
"$HUB_CLI" "${args[@]}"
"$HUB_CLI" loadout --hub-root "$HUB_ROOT" sync-task --project-root "$ROOT" --task-name "$TASK" >/dev/null
