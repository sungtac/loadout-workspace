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
# 이 경계는 backends.json에서 call_type=native인 워커 전용이다. cli/api 워커는 call_worker.sh가
# 예약·완료 영수증을 직접 남기므로, 여기서 예약하면 디스패처(gate·scope 검사)를 우회한 수동 호출에 영수증이 생긴다.
BACKENDS="$ROOT/_shared/backends.json"
[ -f "$BACKENDS" ] || die "backends.json 없음: $BACKENDS" 5
[ "$(jq -r --arg r "$GATE_ROLE" '.workers[$r].call_type // empty' "$BACKENDS")" = native ] \
  || die "native 워커 아님: $GATE_ROLE — call_worker.sh 디스패처를 사용" 9

BRIDGE="$ROOT/_local/agent-hub-bridge.json"
HUB_ROOT="${AGENT_HUB_ROOT:-}"; HUB_CLI="${AGENT_HUB_CLI:-}"
[ -n "$HUB_ROOT" ] || [ -f "$BRIDGE" ] || die "Agent Hub bridge 미설정" 5
[ -n "$HUB_ROOT" ] || HUB_ROOT="$(jq -r '.hub_root // empty' "$BRIDGE")"
[ -n "$HUB_ROOT" ] || die "Agent Hub bridge 미설정: AGENT_HUB_ROOT 또는 $BRIDGE의 hub_root 필요" 5
[ -n "$HUB_CLI" ] || HUB_CLI="$(jq -r '.cli // "agent-hub"' "$BRIDGE" 2>/dev/null || true)"
[ -n "$HUB_CLI" ] || HUB_CLI="agent-hub"
[ -x "$HUB_CLI" ] || command -v "$HUB_CLI" >/dev/null 2>&1 || die "Agent Hub CLI를 찾을 수 없음" 5
TASKMD="$ROOT/tasks/$TASK/task.md"
HUB_TASK_ID="$(grep -m1 -E '^[[:space:]]*agent_hub_task_id:' "$TASKMD" | tr -d '\r' | sed -E 's/^[[:space:]]*agent_hub_task_id:[[:space:]]*//; s/[[:space:]]+#.*$//')"
# Hub task ID = task-<32hex> (call_worker.sh·_templates/task.md와 동일 계약)
[[ "$HUB_TASK_ID" =~ ^task-[0-9a-f]{32}$ ]] || die "task.md agent_hub_task_id가 유효하지 않음" 5

if [ "$ACTION" = start ]; then
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum 필요" 5
  fingerprint="$({ printf '%s\0' "$ROLE"; cat -- "$BRIEF"; } | sha256sum | awk '{print $1}')"
  "$HUB_CLI" gateway --hub-root "$HUB_ROOT" reserve-external --task-id "$HUB_TASK_ID" --channel loadout-native --maximum 32 --fingerprint "$fingerprint" --provider claude
  exit 0
fi

[[ "$DISPATCH_ID" =~ ^[0-9a-f]{32}$ ]] || die "dispatch-id는 start가 반환한 32자리 hex여야 함" 64
case "$STATUS" in succeeded|failed|timed_out|empty|scope_violation) ;; *) die "허용되지 않는 status: $STATUS" 64;; esac
if [ -n "$RETURN_CODE" ]; then case "$RETURN_CODE" in *[!0-9-]*|'') die "return-code는 정수여야 함" 64;; esac; fi
args=(gateway --hub-root "$HUB_ROOT" complete-external --task-id "$HUB_TASK_ID" --dispatch-id "$DISPATCH_ID" --status "$STATUS")
[ -n "$RETURN_CODE" ] && args+=(--return-code "$RETURN_CODE")
"$HUB_CLI" "${args[@]}"
"$HUB_CLI" loadout --hub-root "$HUB_ROOT" sync-task --project-root "$ROOT" --task-name "$TASK" >/dev/null
