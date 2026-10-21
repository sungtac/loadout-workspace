#!/usr/bin/env bash
# call_worker.sh — backends.json 디스패처 (cli/api 전용).
# native만 오케스트레이터가 직접 호출한다. MCP 직접 호출은 표준 경로가 아니다.
# 사용: call_worker.sh <role> <brief-file> [payload-file]
#   payload-file(선택): brief 한도(1200자)와 별도인 동봉 자료(예: sources/gemini-packet.md).
#   디스패처가 brief 뒤에 결합해 전달 — brief 본문 inline 금지 규칙과 충돌 없이 대용량 자료 전달.
#   미리보기: call_worker.sh --merged-preview <brief-file> <payload-file>  (백엔드 호출 없이 결합 결과 출력)
# 사전 게이트: gate.sh(승인·[APPROVAL]·brief 위치/한도·외부쓰기 조건·D5) 통과 못 하면 exit 9.
# 사후 검사: write_scope 패턴이면 scope_check.sh로 scope 밖 변경 보고(status=scope_violation, exit 10, 비파괴).
# 반환: stdout에 result envelope(JSON). exit 0=성공, 비0=실패/거부.
set -euo pipefail

# ── 임시자원 추적 + 강제 정리(die·인터럽트·정상 모두) ──
# 추적을 bash 배열이 아니라 레지스트리 '파일'에 적는다: mktmp/mktmpd는 거의 항상
# `X="$(mktmp)"` 명령 치환(= 서브셸)에서 호출되는데, 서브셸의 배열 append는 부모 셸에
# 반영되지 않아 cleanup이 그 임시파일을 보지 못하고 전부 누수됐다. 파일에 적으면
# 서브셸이 append한 경로가 디스크에 남아 부모 EXIT trap이 반드시 정리한다.
_TMP_REGISTRY="$(mktemp "${TMPDIR:-/tmp}/call_worker-tmps.XXXXXX")"
GW_DISPATCH_ID=""; GW_COMPLETED=0   # Hub 게이트웨이 예약 상태(중복완료 방지 플래그)
cleanup() {  # 항상 0: EXIT trap이 종료코드 덮어쓰지 않도록
  local rc=$? p
  # 예약이 완료 기록 없이 남으면(시그널·중도 die) dedup 교착을 막기 위해 실패로 완료 처리.
  # gateway_complete는 예약 직전 정의되므로 GW_DISPATCH_ID가 설정됐다면 반드시 존재한다.
  if [ -n "${GW_DISPATCH_ID:-}" ] && [ "${GW_COMPLETED:-0}" = 0 ]; then
    gateway_complete failed "$rc" || true
  fi
  if [ -f "$_TMP_REGISTRY" ]; then
    while IFS= read -r p; do [ -n "$p" ] && rm -rf -- "$p"; done <"$_TMP_REGISTRY"
    rm -f -- "$_TMP_REGISTRY"
  fi
  return 0
}
on_signal() { trap - EXIT INT TERM; cleanup; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM
mktmp()  { local t; t="$(mktemp)";    printf '%s\n' "$t" >>"$_TMP_REGISTRY"; printf '%s' "$t"; }
mktmpd() { local t; t="$(mktemp -d)"; printf '%s\n' "$t" >>"$_TMP_REGISTRY"; printf '%s' "$t"; }

die() { echo "call_worker: $1" >&2; exit "${2:-1}"; }

PREVIEW=0
if [ "${1:-}" = "--merged-preview" ]; then PREVIEW=1; shift; set -- "_preview" "$@"; fi

ROLE="${1:-}"; BRIEF="${2:-}"; PAYLOAD="${3:-}"
[ -n "$ROLE" ] && [ -n "$BRIEF" ] || die "usage: call_worker.sh <role> <brief-file> [payload-file]" 64

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${MULTIAGENT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BACKENDS="$ROOT/_shared/backends.json"

command -v jq >/dev/null 2>&1 || die "jq 필요(JSON 파싱)" 5
[ "$PREVIEW" = 1 ] || [ -f "$BACKENDS" ] || die "backends.json 없음: $BACKENDS" 5

# timeout: coreutils timeout/gtimeout 우선, 없으면 portable bash 폴백(둘 다 유한 보장)
TIMEOUT_BIN=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN=timeout
[ -z "$TIMEOUT_BIN" ] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN=gtimeout
run_limited() {  # run_limited <secs> -- <cmd...>
  local t="$1"; shift; [ "$1" = "--" ] && shift
  if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" -k 5 "$t" "$@"; return $?; fi
  # 폴백: python3 러너(결정적, 프로세스그룹 TERM→KILL). python3은 시스템 필수 의존성.
  command -v python3 >/dev/null 2>&1 || die "timeout 유틸 또는 python3 필요" 5
  python3 "$SCRIPT_DIR/_run.py" "$t" "$@"; return $?
}

# brief 절대경로화 + 검증 ('--'로 옵션 하이재킹 방어)
case "$BRIEF" in *..*) die "brief 경로에 '..' 금지" 6;; esac
[ -f "$BRIEF" ] || die "brief 파일 없음: $BRIEF" 6
BRIEF="$(cd "$(dirname -- "$BRIEF")" && pwd)/$(basename -- "$BRIEF")"

# 사전 게이트(fail-closed): 승인·[APPROVAL]·brief 위치/한도·외부쓰기 조건·D5 (gate.sh 정본, preview는 비경유)
GATE_REPO="-"; GATE_SCOPE="none"
if [ "$PREVIEW" != 1 ]; then
  gate_json="$(MULTIAGENT_ROOT="$ROOT" bash "$SCRIPT_DIR/gate.sh" --json "$BRIEF")" || die "게이트 거부 (gate.sh exit $?)" 9
  GATE_TASK="$(jq -r .task <<<"$gate_json")"; GATE_ROLE="$(jq -r .role <<<"$gate_json")"
  GATE_REPO="$(jq -r .target_repo <<<"$gate_json")"; GATE_SCOPE="$(jq -r .write_scope <<<"$gate_json")"
  # 승인된 역할(brief 경로) == 호출 역할(첫 인자). 불일치 = 미승인 백엔드 실행이므로 거부
  [ "$GATE_ROLE" = "$ROLE" ] || die "역할 불일치: brief는 $GATE_ROLE 승인, 호출은 $ROLE" 9
fi

# payload(선택) — brief 한도 밖 동봉 자료. brief 뒤에 결합한 임시 brief로 치환.
if [ -n "$PAYLOAD" ]; then
  case "$PAYLOAD" in *..*) die "payload 경로에 '..' 금지" 6;; esac
  [ -f "$PAYLOAD" ] || die "payload 파일 없음: $PAYLOAD" 6
  MERGED="$(mktmp)"
  { cat -- "$BRIEF"
    printf '\n\n---\n\n# 동봉 자료 (payload — orchestrator가 결합. 이 자료만 사용하고 파일 열지 말 것)\n\n'
    cat -- "$PAYLOAD"
  } >"$MERGED"
  BRIEF="$MERGED"
fi
if [ "$PREVIEW" = 1 ]; then cat -- "$BRIEF"; exit 0; fi

rec="$(jq -c --arg r "$ROLE" '.workers[$r] // empty' "$BACKENDS")"
[ -n "$rec" ] || die "role 미정의: $ROLE" 2

# Agent Hub 단일 게이트웨이 — Loadout 외부 worker도 작업 원장에 먼저 예약한다.
# bridge 설정이 없거나 task.md의 Hub task ID가 없으면, 직접 CLI 호출은 허용하지 않는다.
BRIDGE="$ROOT/_local/agent-hub-bridge.json"
HUB_ROOT="${AGENT_HUB_ROOT:-}"; HUB_CLI="${AGENT_HUB_CLI:-}"; HUB_TASK_ID=""
if [ -z "$HUB_ROOT" ] && [ -f "$BRIDGE" ]; then HUB_ROOT="$(jq -r '.hub_root // empty' "$BRIDGE")"; fi
if [ -z "$HUB_CLI" ] && [ -f "$BRIDGE" ]; then HUB_CLI="$(jq -r '.cli // "agent-hub"' "$BRIDGE")"; fi
[ -n "$HUB_CLI" ] || HUB_CLI="agent-hub"
[ -n "$HUB_ROOT" ] || die "Agent Hub bridge 미설정: AGENT_HUB_ROOT 또는 $BRIDGE 필요" 5
[ -x "$HUB_CLI" ] || command -v "$HUB_CLI" >/dev/null 2>&1 || die "Agent Hub CLI를 찾을 수 없음: $HUB_CLI" 5
[ -f "$ROOT/tasks/$GATE_TASK/task.md" ] || die "Agent Hub bridge task.md 없음" 5
HUB_TASK_ID="$(grep -m1 -E '^[[:space:]]*agent_hub_task_id:' "$ROOT/tasks/$GATE_TASK/task.md" | sed -E 's/^[[:space:]]*agent_hub_task_id:[[:space:]]*//; s/[[:space:]]+#.*$//')"
case "$HUB_TASK_ID" in task-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) die "task.md agent_hub_task_id가 유효한 Hub task ID가 아님" 5;; esac

# 폴백 가용성 사전 점검(경고만): primary가 죽고 나서야 폴백 불가를 아는 것을 방지
while IFS= read -r _fe; do
  [ -n "$_fe" ] && [ -z "${!_fe:-}" ] && \
    echo "call_worker: 경고 — 폴백 필수 env 미설정: $_fe (primary 실패 시 폴백 불가)" >&2
done < <(jq -r '.fallbacks[]?.api.required_env[]? // empty' <<<"$rec")

redact() { sed -E 's/[A-Za-z0-9_-]{32,}/[REDACTED]/g'; }

# 단일 backend 실행 → envelope(JSON)을 stdout, exit code 반환
run_backend() {
  local spec="$1" ctype bmode tmo cwdp model wd input_brief out err errd rc start dur
  ctype="$(jq -r '.call_type' <<<"$spec")"
  model="$(jq -r '.model // "?"' <<<"$spec")"
  case "$ctype" in
    native) die "native는 오케스트레이터 직접 호출(디스패처 비경유)" 3 ;;
    mcp) die "MCP 직접 호출은 표준 경로가 아님 — CLI/API 디스패처 계약을 사용" 3 ;;
    cli|api) ;;
    *) die "잘못된 call_type: $ctype" 7 ;;
  esac
  bmode="$(jq -r '.brief_mode // "content"' <<<"$spec")"
  tmo="$(jq -r '.timeout // 300' <<<"$spec")"
  cwdp="$(jq -r '.cwd_policy // "repo_root"' <<<"$spec")"

  case "$cwdp" in
    isolated_tmp) wd="$(mktmpd)";;
    # target: none/tasks-only는 해당 task 폴더로 격리한다. 패턴 scope만
    # 승인된 target_repo를 cwd로 쓴다. 환경변수 fallback은 허용하지 않는다.
    target)       wd="$ROOT"
                  case "$GATE_SCOPE" in
                    none|tasks-only) [ -n "${GATE_TASK:-}" ] && wd="$ROOT/tasks/$GATE_TASK" ;;
                    *) [ "$GATE_REPO" != "-" ] && wd="$GATE_REPO" ;;
                  esac;;
    *)            wd="$ROOT";;
  esac

  # Codex의 local scope는 task 폴더에서 실행된다. 기존 brief가 workspace-root 상대경로를
  # 쓰더라도 오해하지 않도록, 실행 시점의 경로 계약을 앞에 붙인다(원본 brief는 수정하지 않음).
  input_brief="$BRIEF"
  case "$ctype:$cwdp:$GATE_SCOPE" in
    cli:target:none|cli:target:tasks-only)
      input_brief="$(mktmp)"
      {
        printf '%s\n\n' '# Dispatcher runtime context (generated — authoritative)'
        printf '%s\n' "- Current working directory: $wd"
        printf '%s\n' "- Workspace root: $ROOT"
        printf '%s\n\n' '- For files in this task use local paths (for example `task.md`, `context.md`, `workers/...`). For workspace-level files use an absolute path. Do not prefix task-local paths with `tasks/<task>/`.'
        cat -- "$BRIEF"
      } >"$input_brief"
      ;;
  esac

  local -a cmd=()
  if [ "$ctype" = "cli" ]; then
    local command_bin args_json a
    command_bin="$(jq -r '.cli.command' <<<"$spec")"
    case "$command_bin" in agy|codex|claude) ;; *) die "command allowlist 위반: $command_bin" 7;; esac
    cmd+=("$command_bin")
    args_json="$(jq -r '.cli.args_template[]' <<<"$spec")"   # jq 실패 시 set -e 트리거
    while IFS= read -r a; do
      case "$a" in
        "@brief")         cmd+=("$input_brief");;
        "@brief_content") cmd+=("$(cat -- "$input_brief")");;
        *)                cmd+=("$a");;
      esac
    done <<<"$args_json"
    # codex 워커: 기본은 git 요구(안전망). git 없으면 명확히 실패. 옵트아웃 시에만 우회.
    if [ "$command_bin" = "codex" ]; then
      # task 내부 산출물만 다루는 호출은 sandbox cwd가 task 폴더로 한정된다.
      # 생성 직후 Git이 없는 작업공간에서도 이 안전한 경우만 자동 우회한다.
      if [ "${MULTIAGENT_CODEX_SKIP_GIT:-0}" = "1" ] || { ! git -C "$wd" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ "$GATE_SCOPE" = "none" || "$GATE_SCOPE" = "tasks-only" ]]; }; then
        local -a _nc=(); local _ins=0 _x
        for _x in "${cmd[@]}"; do
          _nc+=("$_x")
          if [ "$_ins" = 0 ] && [ "$_x" = "exec" ]; then _nc+=("--skip-git-repo-check"); _ins=1; fi
        done
        cmd=("${_nc[@]}")
      elif ! command -v git >/dev/null 2>&1; then
        die "codex 워커는 git이 필요합니다. git 설치 후 재시도하거나, 위험을 감수하면 MULTIAGENT_CODEX_SKIP_GIT=1 로 우회하세요." 8
      fi
    fi

  else
    local ref reqenv brief_pass
    ref="$(jq -r '.api.ref' <<<"$spec")"
    case "$ref" in adapters/*) ;; *) die "api.ref는 adapters/ 내부만" 7;; esac
    case "$ref" in *..*) die "api.ref에 '..' 금지" 7;; esac
    [ -f "$ROOT/_shared/$ref" ] || die "api 스크립트 없음: $ref" 4
    while IFS= read -r reqenv; do
      [ -n "$reqenv" ] || continue
      if [ -z "${!reqenv:-}" ]; then
        # die 대신 에러 envelope 반환: 폴백 체인에서 실패 사유가 최종 envelope에 남도록
        jq -n --arg model "$model" --arg e "$reqenv" \
          '{status:"error", exit_code:4, backend:"api", model:$model,
            duration_s:0, stdout:"", stderr_sanitized:("필수 env 없음: " + $e + " — 폴백 사용 불가")}'
        return 4
      fi
    done < <(jq -r '.api.required_env[]? // empty' <<<"$spec")
    brief_pass="$(jq -r '.api.brief_pass // "arg1"' <<<"$spec")"
    cmd+=("bash" "$ROOT/_shared/$ref")
    [ "$brief_pass" = "arg1" ] && cmd+=("$input_brief")
    [ "$brief_pass" = "stdin" ] && bmode="stdin"
  fi

  out="$(mktmp)"; err="$(mktmp)"; errd="$(mktmp)"
  # 실행 전 스냅샷(사후 scope_check용). git repo 아니면 검사 불가(skipped). git repo인데 스냅샷 실패면 fail-closed로 호출 거부.
  local snap="" scope_state="skipped"
  if git -C "$wd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    snap="$(mktmp)"; printf '%s\n' "$snap.err" >>"$_TMP_REGISTRY"   # 사이드카도 레지스트리에 등록(시그널 시 누수 방지)
    if ! bash "$SCRIPT_DIR/scope_check.sh" --snapshot "$wd" >"$snap" 2>"$snap.err"; then
      jq -n --arg model "$model" --arg backend "$ctype" --rawfile e "$snap.err" \
        '{status:"scope_error", exit_code:12, backend:$backend, model:$model, duration_s:0, stdout:"",
          stderr_sanitized:("실행 전 스냅샷 실패 — scope 검사 불가하므로 호출 거부: " + $e), scope_check:"error", scope_violations:[]}'
      rm -f "$snap.err"; return 12
    fi; rm -f "$snap.err"
  fi
  start=$(date +%s)
  rc=0
  (
    cd "$wd" || exit 70
    export CI=1 DEBIAN_FRONTEND=noninteractive
    if [ "$bmode" = "stdin" ]; then
      run_limited "$tmo" -- "${cmd[@]}" <"$input_brief"
    else
      run_limited "$tmo" -- "${cmd[@]}" </dev/null
    fi
  ) >"$out" 2>"$err" || rc=$?
  dur=$(( $(date +%s) - start ))

  local status="ok"
  [ "$rc" -ne 0 ] && status="error"
  [ "$rc" -eq 124 ] && status="timeout"

  # 사후 scope 검사(보고만): scope 밖 변경이 있으면 status=scope_violation, exit 10. stdout은 보존.
  # 사후 검사 결과: ok / violation(status=scope_violation, exit 10) /
  # error(status=scope_error, exit 12). 둘 다 폴백 없는 최종 실패.
  local viol="[]"
  if [ -n "$snap" ]; then
    local vf src; vf="$(mktmp)"; printf '%s\n' "$vf.err" >>"$_TMP_REGISTRY"; scope_state="ok"   # 사이드카 등록(누수 방지)
    if bash "$SCRIPT_DIR/scope_check.sh" "$wd" "$GATE_SCOPE" "$snap" "$GATE_TASK" >"$vf" 2>"$vf.err"; then :; else src=$?
      if [ "$src" -eq 10 ]; then viol="$(jq -R . <"$vf" | jq -s .)"; status="scope_violation"; rc=10; scope_state="violation"
      else status="scope_error"; rc=12; scope_state="error"; cat "$vf.err" >>"$err"; fi
      rm -f "$vf.err"
    fi
  fi

  redact <"$err" >"$errd"
  jq -n --arg status "$status" --argjson exit "$rc" \
        --rawfile stdout "$out" --rawfile stderr "$errd" \
        --argjson dur "$dur" --arg backend "$ctype" --arg model "$model" --argjson viol "$viol" --arg sc "$scope_state" \
        '{status:$status, exit_code:$exit, backend:$backend, model:$model,
          duration_s:$dur, stdout:$stdout, stderr_sanitized:$stderr, scope_check:$sc, scope_violations:$viol}'
  return "$rc"
}

# 동일 brief·backend 조합은 한 Hub task에서 한 번만 외부로 나간다.
command -v sha256sum >/dev/null 2>&1 || die "Agent Hub bridge에는 sha256sum 필요" 5
GW_PROVIDER="$(jq -r '.cli.command // .api.ref // "unknown"' <<<"$rec")"
[ "$GW_PROVIDER" = "agy" ] && GW_PROVIDER="antigravity"
GW_FINGERPRINT="$({ printf '%s\0%s\0' "$ROLE" "$rec"; cat -- "$BRIEF"; } | sha256sum | awk '{print $1}')"
# 예약 직전 정의: GW_DISPATCH_ID가 설정되는 순간부터 trap/cleanup이 이 함수를 쓸 수 있어야 한다.
gateway_complete() {
  GW_COMPLETED=1   # 정상 경로 완료 후 EXIT trap의 중복 완료 방지
  "$HUB_CLI" gateway --hub-root "$HUB_ROOT" complete-external --task-id "$HUB_TASK_ID" --dispatch-id "$GW_DISPATCH_ID" --status "$1" --return-code "$2" >/dev/null \
    || { echo "call_worker: 경고 — Agent Hub gateway 완료 영수증 기록 실패" >&2; return 0; }
  "$HUB_CLI" loadout --hub-root "$HUB_ROOT" sync-task --project-root "$ROOT" --task-name "$GATE_TASK" >/dev/null \
    || echo "call_worker: 경고 — Agent Hub 관리 블록 동기화 실패" >&2
}
GW_JSON="$("$HUB_CLI" gateway --hub-root "$HUB_ROOT" reserve-external --task-id "$HUB_TASK_ID" --channel loadout-worker --maximum 32 --fingerprint "$GW_FINGERPRINT" --provider "$GW_PROVIDER")" || die "Agent Hub gateway 예약 거부(중복/한도/원장 오류)" 11
GW_DISPATCH_ID="$(jq -r '.dispatch_id // empty' <<<"$GW_JSON")"
case "$GW_DISPATCH_ID" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) die "Agent Hub gateway가 dispatch ID를 반환하지 않음" 11;; esac

# primary → 실패 시 fallbacks 순차 (set -e 우회: || prc=$?)
prc=0; env_primary="$(run_backend "$rec")" || prc=$?
if [ "$prc" -eq 0 ]; then
  gateway_complete succeeded 0
  jq -n --argjson e "$env_primary" '$e + {fallback_used:false}'
  exit 0
fi
# scope 위반(10)/검사 불가(12)는 재시도 대상이 아닌 최종 실패: 폴백 없이 해당 envelope 보존 (primary·fallback 동일)
if [ "$prc" -eq 10 ] || [ "$prc" -eq 12 ]; then
  gateway_complete scope_violation "$prc"
  jq -n --argjson e "$env_primary" '$e + {fallback_used:false}'
  exit "$prc"
fi
nf="$(jq '.fallbacks | length' <<<"$rec")"
env_fb=""; i=0
# 최종 영수증이 실제로 내보낸 envelope와 일치하도록 '마지막 시도'의 rc·envelope를 추적
last_env="$env_primary"; last_rc="$prc"
while [ "$i" -lt "${nf:-0}" ]; do
  fb="$(jq -c --argjson i "$i" '.fallbacks[$i]' <<<"$rec")"
  frc=0; env_fb="$(run_backend "$fb")" || frc=$?
  last_env="$env_fb"; last_rc="$frc"
  if [ "$frc" -eq 0 ]; then
    gateway_complete succeeded 0
    jq -n --argjson e "$env_fb" '$e + {fallback_used:true}'
    exit 0
  fi
  if [ "$frc" -eq 10 ] || [ "$frc" -eq 12 ]; then
    gateway_complete scope_violation "$frc"
    jq -n --argjson e "$env_fb" '$e + {fallback_used:true}'
    exit "$frc"
  fi
  i=$((i+1))
done
if [ "$last_rc" -eq 124 ]; then
  gateway_complete timed_out "$last_rc"
else
  gateway_complete failed "$last_rc"
fi
jq -n --argjson e "$last_env" '$e + {fallback_used:true}'
exit 1
