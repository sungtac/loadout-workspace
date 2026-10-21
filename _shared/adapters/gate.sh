#!/usr/bin/env bash
# gate.sh — worker 호출 사전 게이트 (fail-closed). 벤더중립(bash만).
# 사용: gate.sh [--json] <brief-file>
#   task·role은 brief 경로(tasks/<task>/workers/<role>/brief.md)에서 도출한다.
#   call_worker.sh가 자동 호출. native 워커(claude-main)만 오케스트레이터가 호출 전 직접 실행.
#   MCP 직접 호출은 표준 경로가 아니며, Codex·Gemini는 반드시 디스패처를 경유한다.
# 검사: G0 인터랙티브 세션(D5) / G1 brief 위치 / G2 workers_approved / G3 log [APPROVAL]
#       G4 brief 한도(1200자 또는 240단어) / G5 외부 쓰기 조건(write_scope 패턴 시 target_repo·승인·로그)
# 출력: 통과 → stdout "GATE_OK task=<t> role=<r> target_repo=<p|-> write_scope=<s>" exit 0
#       실패 → 모든 실패 항목 stderr, exit 9. 파일을 수정하지 않는다.
set -u

JSON=0; [ "${1:-}" = "--json" ] && { JSON=1; shift; }
BRIEF="${1:-}"
[ -n "$BRIEF" ] || { echo "usage: gate.sh [--json] <brief-file>" >&2; exit 64; }
[ -f "$BRIEF" ] || { echo "gate: brief 파일 없음: $BRIEF" >&2; exit 9; }

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${MULTIAGENT_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
ROOT="$(cd "$ROOT" && pwd -P)"
BRIEF="$(cd "$(dirname -- "$BRIEF")" && pwd -P)/$(basename -- "$BRIEF")"

FAILS=()
fail() { FAILS+=("$1"); }

# G0 — 인터랙티브 전용 (D5)
[ -z "${CLAUDE_JOB_DIR:-}" ] || fail "G0 백그라운드 세션(CLAUDE_JOB_DIR 설정됨) — 인터랙티브 세션에서 실행"

# G1 — brief 위치: $ROOT/tasks/<task>/workers/<role>/brief.md
TASK=""; ROLE=""
REL="${BRIEF#"$ROOT"/}"
if [ "$REL" != "$BRIEF" ] && [[ "$REL" == tasks/*/workers/*/brief.md ]]; then
  TASK="${REL#tasks/}"; TASK="${TASK%%/*}"
  ROLE="${REL#tasks/*/workers/}"; ROLE="${ROLE%%/*}"
  [ "$(printf '%s\n' "$REL" | awk -F/ '{print NF}')" = 5 ] || { fail "G1 brief 경로 깊이 불일치: $REL"; TASK=""; }
else
  fail "G1 brief 위치가 tasks/<task>/workers/<role>/brief.md 형태가 아님: $BRIEF"
fi

TDIR="$ROOT/tasks/$TASK"
TASKMD="$TDIR/task.md"; LOGMD="$TDIR/log.md"

# workers_approved 블록 (task.md yaml 펜스 안, planned_workers 또는 펜스 끝까지)
approved_block() {
  awk '/^workers_approved:/{f=1; next} f && (/^planned_workers:/ || /^```/){exit} f' "$TASKMD" 2>/dev/null
}
# 특정 worker 항목만 (- worker: <role> 부터 다음 - worker: 전까지)
approved_entry() {
  approved_block | awk -v r="$ROLE" '
    /^[[:space:]]*-[[:space:]]*worker:/ { cur = ($0 ~ ("worker:[[:space:]]*" r "[[:space:]]*$")) }
    cur { print }'
}

# log.md의 실제 [APPROVAL] 항목만: HTML 주석(<!-- -->, _templates/log.md의 형식 예시 블록 포함)은 제외하고
# "[timestamp] [APPROVAL]" 태그 위치에 있는 줄만 인정한다(본문에 인용된 [APPROVAL]·템플릿 예시 잔존으로 통과 금지).
approval_lines() {
  awk '{
    sub(/\r$/, ""); line = $0; out = ""
    # 렌더링 기준(CommonMark): 블록 주석은 줄 첫머리 <!-- 에서만 열리고 --> 에서 닫힌다.
    # 항목 본문 중간의 짝 없는 "<!--"는 문자열일 뿐 — 뒤따르는 항목을 숨기지 않는다.
    if (!inc && line ~ /^[ \t]*<!--/) { inc = 1; line = substr(line, index(line, "<!--") + 4) }
    if (inc) { i = index(line, "-->"); if (!i) { print ""; next } line = substr(line, i + 3); inc = 0 }
    # 같은 줄에서 닫히는 인라인 주석만 제거
    while ((i = index(line, "<!--")) && (j = index(substr(line, i + 4), "-->"))) { out = out substr(line, 1, i - 1); line = substr(line, i + 4 + j + 2) }
    print out line
  }' "$LOGMD" 2>/dev/null | grep -E '^\[[^]]*\][[:space:]]*\[APPROVAL\]'
}

if [ -n "$TASK" ]; then
  # G2 — 승인
  if [ ! -f "$TASKMD" ]; then fail "G2 task.md 없음: $TASKMD"
  elif [ -z "$(approved_entry)" ]; then fail "G2 workers_approved에 $ROLE 없음 ($TASKMD)"; fi
  # G3 — [APPROVAL] 로그
  if [ ! -f "$LOGMD" ]; then fail "G3 log.md 없음: $LOGMD"
  elif ! approval_lines | grep -qE "(^|[^[:alnum:]_-])$ROLE([^[:alnum:]_-]|$)"; then fail "G3 log.md에 [APPROVAL] $ROLE 기록 없음"; fi
fi

# G4 — brief 한도: 한글 비율 30% 초과면 한글 brief(≤1200자), 아니면 영문 brief(≤240단어)
# 문자수는 로캘 비의존으로 센다: `wc -m`은 LC_ALL=C에서 바이트를 세어 한글 brief가 ~3배로
# 부풀고 한도 판정이 뒤집힌다. UTF-8 코드포인트 수 = 전체 바이트 − continuation 바이트(0x80-0xBF).
# 아래 한글 바이트 집계와 동일하게 LC_ALL=C 바이트 기반으로 세어 결정적으로 판정한다.
bytes=$(wc -c <"$BRIEF" | tr -d ' ')
cont=$(LC_ALL=C grep -o $'[\x80-\xBF]' "$BRIEF" | wc -l | tr -d ' ')
chars=$((bytes - cont)); words=$(wc -w <"$BRIEF" | tr -d ' ')
# 일부 UTF-8 로캘은 범위식 [가-힣]을 유효하지 않은 collation으로 해석한다.
# 바이트 단위 C 로캘에서 UTF-8 코드포인트 범위를 세어, 경고 없이 결정적으로 판정한다.
hangul=$(LC_ALL=C grep -o $'[\xEA-\xED][\x80-\xBF][\x80-\xBF]' "$BRIEF" | wc -l | tr -d ' ')
if [ $((hangul * 10)) -gt $((chars * 3)) ]; then
  [ "$chars" -le 1200 ] || fail "G4 brief 한도 초과(한글): ${chars}자 > 1200자"
else
  [ "$words" -le 240 ] || fail "G4 brief 한도 초과(영문): ${words}단어 > 240단어"
fi

# G5 — 외부 쓰기 조건
yaml_val() { # yaml_val <key> — brief에서 첫 매치, CR(CRLF 파일)·따옴표·주석 제거
  grep -m1 -E "^[[:space:]]*$1:" "$BRIEF" | tr -d '\r' | sed -E "s/^[[:space:]]*$1:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//"
}
SCOPE="$(yaml_val write_scope)"; [ -n "$SCOPE" ] || SCOPE="none"
REPO="$(yaml_val target_repo)"
case "$REPO" in ""|N/A|n/a|-) REPO="-";; esac
case "$SCOPE" in
  none|tasks-only) ;;
  *)
    if [ "$REPO" = "-" ]; then fail "G5 write_scope 패턴('$SCOPE')인데 brief에 target_repo 없음"
    elif [ "${REPO#/}" = "$REPO" ]; then fail "G5 target_repo가 절대경로 아님: $REPO"
    elif [ ! -d "$REPO" ]; then fail "G5 target_repo 디렉터리 없음: $REPO"; fi
    if [ -n "$TASK" ] && [ -f "$TASKMD" ]; then
      # 승인 항목의 target_repo·write_scope 가 brief 값과 정확히 일치해야 (다르면 기존 승인 무효 — orchestrator-rules §3)
      a_scope="$(approved_entry | grep -m1 -E '^[[:space:]]*write_scope:' | tr -d '\r' | sed -E "s/^[[:space:]]*write_scope:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//")"
      a_repo="$(approved_entry | grep -m1 -E '^[[:space:]]*target_repo:' | tr -d '\r' | sed -E "s/^[[:space:]]*target_repo:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//")"
      [ -n "$a_scope" ] || fail "G5 task.md workers_approved의 $ROLE 항목에 write_scope 승인 없음"
      [ -n "$a_repo" ]  || fail "G5 task.md workers_approved의 $ROLE 항목에 target_repo 승인 없음"
      [ -z "$a_scope" ] || [ "$a_scope" = "$SCOPE" ] || fail "G5 write_scope 승인값('$a_scope') ≠ brief('$SCOPE') — 재승인 필요"
      [ -z "$a_repo" ]  || [ "$a_repo" = "$REPO" ]   || fail "G5 target_repo 승인값('$a_repo') ≠ brief('$REPO') — 재승인 필요"
    fi
    if [ -n "$TASK" ] && [ -f "$LOGMD" ]; then
      # 같은 role·같은 write_scope 값이 한 줄에 있는 [APPROVAL] 만 인정 (다른 워커·이전 범위의 승인 로그는 무효)
      approval_lines | grep -E "(^|[^[:alnum:]_-])$ROLE([^[:alnum:]_-]|$)" | grep -qF -- "$SCOPE" \
        || fail "G5 log.md [APPROVAL]에 '$ROLE' + write_scope '$SCOPE' 를 함께 담은 외부 쓰기 승인 기록 없음"
    fi
    ;;
esac

if [ "${#FAILS[@]}" -gt 0 ]; then
  printf 'gate: 거부 (%d건)\n' "${#FAILS[@]}" >&2
  printf '  - %s\n' "${FAILS[@]}" >&2
  exit 9
fi
if [ "$JSON" = 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo "gate: --json 은 jq 필요" >&2; exit 5; }
  jq -nc --arg t "$TASK" --arg r "$ROLE" --arg p "$REPO" --arg s "$SCOPE" '{task:$t, role:$r, target_repo:$p, write_scope:$s}'
else
  printf 'GATE_OK task=%s role=%s target_repo=%s write_scope=%s\n' "$TASK" "$ROLE" "$REPO" "$SCOPE"
fi
