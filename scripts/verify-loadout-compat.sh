#!/usr/bin/env bash
# 로컬 Loadout 호환 계약의 읽기 전용 점검기.
set -euo pipefail

ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_FILE="$ROOT/CLAUDE.md"
SETTINGS="$ROOT/.claude/settings.json"
BACKENDS="$ROOT/_shared/backends.json"
MCP_CONFIG="$ROOT/.mcp.json"
DISPATCHER="$ROOT/_shared/adapters/call_worker.sh"
NATIVE_RECEIPT="$ROOT/_shared/adapters/native_worker_receipt.sh"
GATE="$ROOT/_shared/adapters/gate.sh"
SCOPE_CHECK="$ROOT/_shared/adapters/scope_check.sh"
failures=0

ok() { printf 'PASS %s\n' "$1"; }
ng() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

marker_count() { grep -Fxc "$1" "$CLAUDE_FILE" 2>/dev/null || true; }

[ "$(marker_count '<!-- store:knot:start -->')" = 1 ] \
  && [ "$(marker_count '<!-- store:knot:end -->')" = 1 ] \
  && ok 'store:knot marker pair' || ng 'store:knot marker pair'
[ "$(marker_count '<!-- store:guard:start -->')" = 1 ] \
  && [ "$(marker_count '<!-- store:guard:end -->')" = 1 ] \
  && ok 'store:guard marker pair' || ng 'store:guard marker pair'

if jq -e '.workers["codex-main"].call_type == "cli" and .workers["codex-main"].brief_mode == "stdin" and .workers["codex-main"].cli.args_template == ["exec", "--sandbox", "workspace-write", "-"] and .workers["codex-critic"].call_type == "cli" and .workers["codex-critic"].brief_mode == "stdin" and .workers["codex-critic"].cli.args_template == ["exec", "--sandbox", "read-only", "-"]' "$BACKENDS" >/dev/null; then
  ok 'Codex standard path uses gated CLI dispatcher'
else
  ng 'Codex standard path uses gated CLI dispatcher'
fi

if jq -e '.mcpServers == {}' "$MCP_CONFIG" >/dev/null; then
  ok 'workspace direct MCP servers are disabled'
else
  ng 'workspace direct MCP servers are disabled'
fi

if grep -Fq 'mcp) die "MCP 직접 호출은 표준 경로가 아님' "$DISPATCHER" \
  && grep -Fq 'none|tasks-only) [ -n "${GATE_TASK:-}" ] && wd="$ROOT/tasks/$GATE_TASK"' "$DISPATCHER" \
  && grep -Fq 'G0 — 인터랙티브 전용' "$GATE"; then
  ok 'dispatcher rejects MCP and isolates local task scopes'
else
  ng 'dispatcher rejects MCP and isolates local task scopes'
fi

if [ -f "$NATIVE_RECEIPT" ] \
  && bash -n "$NATIVE_RECEIPT" \
  && grep -Fq 'native_worker_receipt.sh start claude-main' "$CLAUDE_FILE" \
  && grep -Fq 'reserve-external' "$NATIVE_RECEIPT" \
  && grep -Fq 'complete-external' "$NATIVE_RECEIPT" \
  && grep -Fq 'sync-task' "$NATIVE_RECEIPT" \
  && grep -Fq '역할 불일치' "$NATIVE_RECEIPT"; then
  ok 'native Claude worker has a Hub receipt boundary'
else
  ng 'native Claude worker has a Hub receipt boundary'
fi

scope_tmp="$(mktemp -d)"; before="$scope_tmp/before"; trap 'rm -rf -- "$scope_tmp"' EXIT
if git init -q "$scope_tmp/repo" \
  && mkdir -p "$scope_tmp/repo/tasks/compat-scope" \
  && printf 'tasks/*\n' >"$scope_tmp/repo/.gitignore" \
  && bash "$SCOPE_CHECK" --snapshot "$scope_tmp/repo/tasks/compat-scope" >"$before" \
  && : >"$scope_tmp/repo/tasks/compat-scope/artifact.txt" \
  && bash "$SCOPE_CHECK" "$scope_tmp/repo/tasks/compat-scope" tasks-only "$before" compat-scope >/dev/null; then
  ok 'tasks-only accepts writes inside task cwd in a Git workspace'
else
  ng 'tasks-only accepts writes inside task cwd in a Git workspace'
fi

before_none="$scope_tmp/before-none"; none_out="$scope_tmp/none-out"
none_rc=0
if bash "$SCOPE_CHECK" --snapshot "$scope_tmp/repo/tasks/compat-scope" >"$before_none" \
  && : >"$scope_tmp/repo/tasks/compat-scope/none-violation.txt"; then
  bash "$SCOPE_CHECK" "$scope_tmp/repo/tasks/compat-scope" none "$before_none" compat-scope >"$none_out" || none_rc=$?
fi
if [ "$none_rc" = 10 ] && grep -Fq 'none-violation.txt' "$none_out"; then
  ok 'none scope rejects task-folder writes'
else
  ng 'none scope rejects task-folder writes'
fi

before_root="$scope_tmp/before-root"; root_out="$scope_tmp/root-out"
root_rc=0
if bash "$SCOPE_CHECK" --snapshot "$scope_tmp/repo" >"$before_root" \
  && : >"$scope_tmp/repo/outside-task.txt"; then
  bash "$SCOPE_CHECK" "$scope_tmp/repo" tasks-only "$before_root" compat-scope >"$root_out" || root_rc=$?
fi
if [ "$root_rc" = 10 ] && grep -Fq 'outside-task.txt' "$root_out"; then
  ok 'tasks-only rejects writes outside task folder'
else
  ng 'tasks-only rejects writes outside task folder'
fi

mkdir -p "$scope_tmp/repo/vendor/nested"
git init -q "$scope_tmp/repo/vendor/nested"
printf 'before\n' >"$scope_tmp/repo/vendor/nested/state.txt"
nested_before="$scope_tmp/nested-before"; nested_out="$scope_tmp/nested-out"; nested_rc=0
if bash "$SCOPE_CHECK" --snapshot "$scope_tmp/repo" >"$nested_before" \
  && printf 'after\n' >"$scope_tmp/repo/vendor/nested/state.txt"; then
  bash "$SCOPE_CHECK" "$scope_tmp/repo" 'src/**' "$nested_before" compat-scope >"$nested_out" || nested_rc=$?
fi
if [ "$nested_rc" = 10 ] && grep -Fq 'vendor/nested/state.txt' "$nested_out"; then
  ok 'nested Git repository changes are scope-checked'
else
  ng 'nested Git repository changes are scope-checked'
fi

printf 'base\n' >"$scope_tmp/repo/README"
git -C "$scope_tmp/repo" config user.email verifier@example.invalid
git -C "$scope_tmp/repo" config user.name verifier
git -C "$scope_tmp/repo" add .gitignore README
git -C "$scope_tmp/repo" commit -qm baseline
commit_before="$scope_tmp/commit-before"; commit_out="$scope_tmp/commit-out"; commit_rc=0
if bash "$SCOPE_CHECK" --snapshot "$scope_tmp/repo" >"$commit_before" \
  && printf 'outside committed change\n' >>"$scope_tmp/repo/README" \
  && git -C "$scope_tmp/repo" add README \
  && git -C "$scope_tmp/repo" commit -qm outside-change; then
  bash "$SCOPE_CHECK" "$scope_tmp/repo" 'src/**' "$commit_before" compat-scope >"$commit_out" || commit_rc=$?
fi
if [ "$commit_rc" = 10 ] && grep -Fq '.git/.scope-git-policy-state' "$commit_out"; then
  ok 'committed out-of-scope changes are detected'
else
  ng 'committed out-of-scope changes are detected'
fi

: >"$scope_tmp/corrupt-before"
corrupt_rc=0
bash "$SCOPE_CHECK" "$scope_tmp/repo" none "$scope_tmp/corrupt-before" compat-scope >/dev/null 2>&1 || corrupt_rc=$?
if [ "$corrupt_rc" = 12 ]; then
  ok 'corrupt scope snapshot is rejected with exit 12'
else
  ng 'corrupt scope snapshot is rejected with exit 12'
fi

if grep -Fq '`none`/`tasks-only` 는 현재 `tasks/<task>/` 폴더를 cwd로 격리' "$CLAUDE_FILE" \
  && grep -Fq '`none`·`tasks-only`는 task cwd로 격리' "$ROOT/CHANGELOG.md"; then
  ok 'cwd policy documentation is synchronized'
else
  ng 'cwd policy documentation is synchronized'
fi

if jq -e '.hooks.Stop | map(.hooks[]?.command // "") | any(test("PATH=.*\\.local/bin.*coach --hook"))' "$SETTINGS" >/dev/null; then
  ok 'Stop hook carries local binary PATH'
else
  ng 'Stop hook carries local binary PATH'
fi

if command -v coach >/dev/null 2>&1 && command -v codexbar >/dev/null 2>&1; then
  ok 'coach and codexbar are discoverable'
else
  ng 'coach and codexbar are discoverable'
fi

guard_status="$(coach guard status 2>&1 || true)"
if printf '%s\n' "$guard_status" | sed -n '1p' | grep -Fq '요금가드: off'; then
  ok 'guard remains off'
else
  ng 'guard remains off'
fi

if [ -n "${KNOT_VAULT:-}" ]; then
  if [ -d "$KNOT_VAULT" ] && python3 "$KNOT_VAULT/scripts/lint.py" "$KNOT_VAULT" >/dev/null; then
    ok 'KNOT_VAULT directory and schema lint'
  else
    ng 'KNOT_VAULT directory and schema lint'
  fi
elif [ -s "$HOME/.config/knot/vault" ]; then
  vault="$(grep -m1 -v '^[[:space:]]*$' "$HOME/.config/knot/vault" || true)"   # 비어 있지 않은 첫 줄 (LOADOUT_LOCAL_COMPAT.md)
  if [ -d "$vault" ] && python3 "$vault/scripts/lint.py" "$vault" >/dev/null; then
    ok 'knot pointer directory and schema lint'
  else
    ng 'knot pointer directory and schema lint'
  fi
else
  ok 'knot intentionally inactive'
fi

# ── Codex·Claude 공통 파이프라인 문서 정합 (CLAUDE.md ↔ AGENTS.md ↔ backends.json) ──
AGENTS_FILE="$ROOT/AGENTS.md"
arch_workers() { sed -n '/^## Architecture/,/^## /p' "$1" | sed -nE 's/^[[:space:]│├└─]*(claude-main|codex-[a-z]+|gemini[a-z-]*|[a-z]+-[a-z]+)[[:space:]]+\[.*/\1/p' | sort -u; }
backend_workers="$(jq -r '.workers | keys[]' "$BACKENDS" | sort -u)"
if [ -n "$(arch_workers "$CLAUDE_FILE")" ] \
  && [ "$(arch_workers "$CLAUDE_FILE")" = "$backend_workers" ] \
  && [ "$(arch_workers "$AGENTS_FILE")" = "$backend_workers" ]; then
  ok 'CLAUDE.md and AGENTS.md worker pools match backends.json'
else
  ng 'CLAUDE.md and AGENTS.md worker pools match backends.json'
fi
parity_ok=1
for needle in 'call_worker.sh' '_shared/adapters/gate.sh' 'native_worker_receipt.sh start claude-main' \
  'reentry-check.sh' 'scope_violation' 'exit 10' 'exit 12' 'scope_check: skipped' '_shared/capability-profile.md'; do
  grep -Fq -- "$needle" "$CLAUDE_FILE" && grep -Fq -- "$needle" "$AGENTS_FILE" || { parity_ok=0; printf '  parity missing: %s\n' "$needle" >&2; }
done
grep -Fq 'default to the Orchestrator itself' "$AGENTS_FILE" && parity_ok=0
if [ "$parity_ok" = 1 ]; then
  ok 'AGENTS.md describes the same common pipeline as CLAUDE.md'
else
  ng 'AGENTS.md describes the same common pipeline as CLAUDE.md'
fi

# ── 공통 파이프라인 동작 회귀 (가짜 Hub CLI·가짜 codex — 외부 모델·네트워크 호출 없음) ──
pipe="$scope_tmp/pipe"; ws="$pipe/ws"; fakebin="$pipe/bin"
mkdir -p "$ws/tasks/t/workers/claude-main" "$ws/tasks/t/workers/codex-main" "$ws/_local" "$fakebin"
cp -R "$ROOT/_shared" "$ROOT/_templates" "$ws/"
cat >"$fakebin/agent-hub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_HUB_LOG"
case "$*" in *reserve-external*) printf '{"dispatch_id":"0123456789abcdef0123456789abcdef"}\n';; esac
EOF
cat >"$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; echo fake-codex
EOF
cat >"$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_CLAUDE_ARGS"; cat >"$FAKE_CLAUDE_STDIN"; echo fake-claude
EOF
chmod +x "$fakebin/agent-hub" "$fakebin/codex" "$fakebin/claude"
printf '{"hub_root":"%s","cli":"%s"}\n' "$pipe/hub" "$fakebin/agent-hub" >"$ws/_local/agent-hub-bridge.json"
sed 's/^agent_hub_task_id: N\/A$/agent_hub_task_id: task-0123456789abcdef0123456789abcdef/; s/^workers_approved: \[\]$/workers_approved:\n  - worker: claude-main\n  - worker: codex-main/' \
  "$ROOT/_templates/task.md" >"$ws/tasks/t/task.md"
cp "$ROOT/_templates/log.md" "$ws/tasks/t/log.md"
cp "$ROOT/_templates/context.md" "$ws/tasks/t/context.md"
printf 'Plan it.\n' >"$ws/tasks/t/workers/claude-main/brief.md"
printf 'target_repo: N/A\nwrite_scope: tasks-only\n\nDo it.\n' >"$ws/tasks/t/workers/codex-main/brief.md"
pipe_env=(env -u AGENT_HUB_ROOT -u AGENT_HUB_CLI -u CLAUDE_JOB_DIR -u CALL_WORKER_ATTEMPT MULTIAGENT_ROOT="$ws" FAKE_HUB_LOG="$pipe/hub.log" FAKE_CLAUDE_ARGS="$pipe/claude.args" FAKE_CLAUDE_STDIN="$pipe/claude.stdin" PATH="$fakebin:$PATH")

# 템플릿 log.md의 주석 속 형식 예시 [APPROVAL]/[COMPLETE]는 실제 항목이 아니다
if ! "${pipe_env[@]}" bash "$ws/_shared/adapters/gate.sh" "$ws/tasks/t/workers/claude-main/brief.md" >/dev/null 2>&1 \
  && "${pipe_env[@]}" bash "$ws/_shared/reentry-check.sh" "$ws/tasks/t" >/dev/null 2>&1; then
  ok 'template log examples neither satisfy the approval gate nor trip re-entry'
else
  ng 'template log examples neither satisfy the approval gate nor trip re-entry'
fi
printf '[2026-01-01 00:00] [APPROVAL] claude-main 승인\n[2026-01-01 00:00] [APPROVAL] codex-main 승인\n' >>"$ws/tasks/t/log.md"

# native 영수증: 32hex Hub task ID 수용, native가 아닌 워커 거부
: >"$pipe/hub.log"; native_rc=0; native_bad_rc=0
native_out="$("${pipe_env[@]}" bash "$ws/_shared/adapters/native_worker_receipt.sh" start claude-main "$ws/tasks/t/workers/claude-main/brief.md" 2>/dev/null)" || native_rc=$?
"${pipe_env[@]}" bash "$ws/_shared/adapters/native_worker_receipt.sh" start codex-main "$ws/tasks/t/workers/codex-main/brief.md" >/dev/null 2>&1 || native_bad_rc=$?
if [ "$native_rc" = 0 ] && [ "$(jq -r .dispatch_id <<<"$native_out")" = 0123456789abcdef0123456789abcdef ] \
  && [ "$native_bad_rc" = 9 ] && [ "$(grep -c reserve-external "$pipe/hub.log")" = 1 ]; then
  ok 'native receipt accepts task-<32hex> and only native workers'
else
  ng 'native receipt accepts task-<32hex> and only native workers'
fi

# 디스패처: cli 경로가 없는 native 역할은 Hub 예약 전에 exit 3, backend 사전중단도 JSON envelope 유지
jq 'del(.workers["claude-main"].cli)' "$ROOT/_shared/backends.json" >"$ws/_shared/backends.json"
: >"$pipe/hub.log"; disp_native_rc=0
"${pipe_env[@]}" bash "$ws/_shared/adapters/call_worker.sh" claude-main "$ws/tasks/t/workers/claude-main/brief.md" >/dev/null 2>&1 || disp_native_rc=$?
jq '.workers["codex-main"].cli.command = "sh"' "$ROOT/_shared/backends.json" >"$ws/_shared/backends.json"
disp_die_rc=0
disp_die_out="$("${pipe_env[@]}" bash "$ws/_shared/adapters/call_worker.sh" codex-main "$ws/tasks/t/workers/codex-main/brief.md" 2>/dev/null)" || disp_die_rc=$?
cp "$ROOT/_shared/backends.json" "$ws/_shared/backends.json"
disp_ok_rc=0
disp_ok_out="$("${pipe_env[@]}" bash "$ws/_shared/adapters/call_worker.sh" codex-main "$ws/tasks/t/workers/codex-main/brief.md" 2>/dev/null)" || disp_ok_rc=$?
if [ "$disp_native_rc" = 3 ] && ! grep -q 'claude-main\|--provider unknown' "$pipe/hub.log" \
  && [ "$disp_die_rc" = 1 ] && jq -e '.status == "error" and .exit_code == 7 and .fallback_used == false' >/dev/null 2>&1 <<<"$disp_die_out" \
  && [ "$disp_ok_rc" = 0 ] && jq -e '.status == "ok" and (.stdout | contains("fake-codex"))' >/dev/null 2>&1 <<<"$disp_ok_out"; then
  ok 'dispatcher refuses native before Hub reservation and always emits an envelope'
else
  ng 'dispatcher refuses native before Hub reservation and always emits an envelope'
fi

# 양 provider: Codex 오케스트레이터는 claude-main을 디스패처 cli 경로로 부른다 — 읽기 전용·격리 플래그,
# brief는 stdin, Hub 영수증은 provider claude로 같은 gate 아래 예약
cp "$ROOT/_shared/backends.json" "$ws/_shared/backends.json"
: >"$pipe/hub.log"; cm_rc=0
: >"$pipe/claude.args"; : >"$pipe/claude.stdin"   # 이전 실행 잔여물 제거(검사는 이번 호출만 본다)
cm_out="$("${pipe_env[@]}" bash "$ws/_shared/adapters/call_worker.sh" claude-main "$ws/tasks/t/workers/claude-main/brief.md" 2>/dev/null)" || cm_rc=$?
cm_args="$(tr '\n' ' ' <"$pipe/claude.args" 2>/dev/null || true)"
cm_flags=1
for f in -p '--permission-mode plan' '--safe-mode' '--restricted' '--no-session-persistence'; do
  case " $cm_args" in *" $f "*) ;; *) cm_flags=0 ;; esac
done
if [ "$cm_rc" = 0 ] && jq -e '.status == "ok" and (.stdout | contains("fake-claude"))' >/dev/null 2>&1 <<<"$cm_out" \
  && [ "$cm_flags" = 1 ] \
  && grep -q 'Plan it.' "$pipe/claude.stdin" 2>/dev/null && grep -q 'reserve-external.*--provider claude' "$pipe/hub.log"; then
  ok 'claude-main is reachable through the dispatcher (Codex orchestrator) read-only'
else
  ng 'claude-main is reachable through the dispatcher (Codex orchestrator) read-only'
fi

# 1회 재시도: CALL_WORKER_ATTEMPT=2는 다른 Hub 지문, 3회차는 예약 전 거부
: >"$pipe/hub.log"
"${pipe_env[@]}" bash "$ws/_shared/adapters/call_worker.sh" codex-main "$ws/tasks/t/workers/codex-main/brief.md" >/dev/null 2>&1 || true
"${pipe_env[@]}" CALL_WORKER_ATTEMPT=2 bash "$ws/_shared/adapters/call_worker.sh" codex-main "$ws/tasks/t/workers/codex-main/brief.md" >/dev/null 2>&1 || true
att3_rc=0; "${pipe_env[@]}" CALL_WORKER_ATTEMPT=3 bash "$ws/_shared/adapters/call_worker.sh" codex-main "$ws/tasks/t/workers/codex-main/brief.md" >/dev/null 2>&1 || att3_rc=$?
fps="$({ grep -o -- '--fingerprint [0-9a-f]*' "$pipe/hub.log" || true; } | sort -u | wc -l)"
if [ "$fps" = 2 ] && [ "$(grep -c reserve-external "$pipe/hub.log")" = 2 ] && [ "$att3_rc" = 64 ]; then
  ok 'a retry is a distinct Hub request and only one retry is allowed'
else
  ng 'a retry is a distinct Hub request and only one retry is allowed'
fi

# 실제 Agent Hub CLI 계약 회귀: 위 가짜 agent-hub는 어떤 인자도 받아들이므로 두 저장소 사이의 인자 드리프트를 못 잡는다.
# 임시 Hub root·임시 작업공간 사본만 사용(실제 runtime·tasks/ 미접촉), backend는 가짜 codex — 모델·네트워크 호출 없음.
real_hub="$(command -v agent-hub 2>/dev/null || true)"
[ -n "$real_hub" ] || { [ -x "$HOME/agent-hub/.venv/bin/agent-hub" ] && real_hub="$HOME/agent-hub/.venv/bin/agent-hub"; } || true
real_hub_case() { # <case-dir> <call_worker sed 식 또는 빈 값> → 0 = 전체 계약 통과 (errexit 비활성 문맥에서 호출 — 단계마다 명시 반환)
  local d="$1" w hub t out did rc
  w="$d/ws"; hub="$d/hub"; t="$w/tasks/rt"
  mkdir -p "$hub" "$w/_local" "$d/bin" && cp -R "$ROOT/_shared" "$ROOT/_templates" "$w/" || return 1
  [ -z "$2" ] || sed -i "$2" "$w/_shared/adapters/call_worker.sh" || return 1
  printf '#!/usr/bin/env bash\ncat >/dev/null; echo fake-codex\n' >"$d/bin/codex" && chmod +x "$d/bin/codex" || return 1
  mkdir -p "$t/workers/claude-main" "$t/workers/codex-main" || return 1
  sed 's/^workers_approved: \[\]$/workers_approved:\n  - worker: claude-main\n  - worker: codex-main/' "$ROOT/_templates/task.md" >"$t/task.md" || return 1
  { cat "$ROOT/_templates/log.md"; printf '[2026-01-01 00:00] [APPROVAL] claude-main 승인\n[2026-01-01 00:00] [APPROVAL] codex-main 승인\n'; } >"$t/log.md" || return 1
  printf 'Plan it.\n' >"$t/workers/claude-main/brief.md"
  printf 'target_repo: N/A\nwrite_scope: tasks-only\n\nDo it.\n' >"$t/workers/codex-main/brief.md"
  printf '{"hub_root":"%s","cli":"%s"}\n' "$hub" "$real_hub" >"$w/_local/agent-hub-bridge.json"
  local -a e=(env -u AGENT_HUB_ROOT -u AGENT_HUB_CLI -u CLAUDE_JOB_DIR -u CALL_WORKER_ATTEMPT MULTIAGENT_ROOT="$w" PATH="$d/bin:$PATH")
  "$real_hub" init --hub-root "$hub" >/dev/null 2>&1 || return 2
  out="$("$real_hub" loadout --hub-root "$hub" bind-task --project-root "$w" --task-name rt --title compat-real-hub --scope personal 2>/dev/null)" || return 3
  [[ "$(jq -r .task_id <<<"$out" 2>/dev/null)" =~ ^task-[0-9a-f]{32}$ ]] \
    && grep -Fxq "agent_hub_task_id: $(jq -r .task_id <<<"$out")" "$t/task.md" || return 3
  out="$("${e[@]}" bash "$w/_shared/adapters/call_worker.sh" codex-main "$t/workers/codex-main/brief.md" 2>/dev/null)" || return 4
  jq -e '.status == "ok" and (.stdout | contains("fake-codex"))' >/dev/null 2>&1 <<<"$out" || return 4
  # call_worker의 complete-external·sync-task 실패는 경고뿐이라 rc로 안 보인다 — 원장 블록으로 확인
  grep -Fq 'External worker receipts: `1` total, `0` pending' "$t/task.md" || return 4
  rc=0; "${e[@]}" bash "$w/_shared/adapters/call_worker.sh" codex-main "$t/workers/codex-main/brief.md" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 11 ] || return 5
  "${e[@]}" CALL_WORKER_ATTEMPT=2 bash "$w/_shared/adapters/call_worker.sh" codex-main "$t/workers/codex-main/brief.md" >/dev/null 2>&1 || return 6
  out="$("${e[@]}" bash "$w/_shared/adapters/native_worker_receipt.sh" start claude-main "$t/workers/claude-main/brief.md" 2>/dev/null)" || return 7
  did="$(jq -r '.dispatch_id // empty' <<<"$out" 2>/dev/null)"; [[ "$did" =~ ^[0-9a-f]{32}$ ]] || return 7
  out="$("${e[@]}" bash "$w/_shared/adapters/native_worker_receipt.sh" complete "$t/workers/claude-main/brief.md" "$did" succeeded 0 2>/dev/null)" || return 8
  jq -e '.external_dispatches | length == 3 and all(.status == "succeeded")' >/dev/null 2>&1 <<<"$out" || return 8
  grep -Fq '<!-- agent-hub:ledger:start -->' "$t/task.md" \
    && grep -Fq 'External worker receipts: `3` total, `0` pending' "$t/task.md" || return 9
}
if [ -z "$real_hub" ]; then
  printf 'SKIP real Agent Hub contract (agent-hub CLI not found)\n'
else
  real_rc=0; real_hub_case "$scope_tmp/real-hub" '' || real_rc=$?
  if [ "$real_rc" = 0 ]; then
    ok 'loadout adapters satisfy the real Agent Hub CLI contract (bind, dispatch, dedup, retry, native receipt, ledger sync)'
  else
    ng "loadout adapters satisfy the real Agent Hub CLI contract (failed at step $real_rc)"
  fi
  # 음성 대조: 사본 call_worker.sh의 인자 하나를 바꾸면 실제 CLI가 거부해야 한다(가짜 Hub라면 통과했을 드리프트)
  drift_rc=0; real_hub_case "$scope_tmp/real-hub-drift" 's/--fingerprint "\$GW_FINGERPRINT"/--finger-print "$GW_FINGERPRINT"/' || drift_rc=$?
  if [ "$drift_rc" = 4 ]; then
    ok 'real Agent Hub contract check catches CLI argument drift'
  else
    ng "real Agent Hub contract check catches CLI argument drift (got step $drift_rc)"
  fi
fi

# 디스패처: args_template 누락은 인자 없는 backend 실행(fail-open) 대신 거부, backend 자체의 exit 12는 scope 결과로 오기록 금지
jq 'del(.workers["codex-main"].cli.args_template)' "$ROOT/_shared/backends.json" >"$ws/_shared/backends.json"
: >"$pipe/hub.log"; noargs_rc=0
noargs_out="$("${pipe_env[@]}" bash "$ws/_shared/adapters/call_worker.sh" codex-main "$ws/tasks/t/workers/codex-main/brief.md" 2>/dev/null)" || noargs_rc=$?
cp "$ROOT/_shared/backends.json" "$ws/_shared/backends.json"
mv "$fakebin/codex" "$fakebin/codex.ok"
printf '#!/usr/bin/env bash\ncat >/dev/null; exit 12\n' >"$fakebin/codex"; chmod +x "$fakebin/codex"
: >"$pipe/hub.log"; be12_rc=0
be12_out="$("${pipe_env[@]}" bash "$ws/_shared/adapters/call_worker.sh" codex-main "$ws/tasks/t/workers/codex-main/brief.md" 2>/dev/null)" || be12_rc=$?
mv -f "$fakebin/codex.ok" "$fakebin/codex"
if [ "$noargs_rc" != 0 ] && jq -e '.exit_code == 7 and (.stdout | contains("fake-codex") | not)' >/dev/null 2>&1 <<<"$noargs_out" \
  && [ "$be12_rc" = 1 ] && jq -e '.status == "error"' >/dev/null 2>&1 <<<"$be12_out" \
  && grep -q -- '--status failed --return-code 12' "$pipe/hub.log" && ! grep -q -- '--status scope_violation' "$pipe/hub.log"; then
  ok 'dispatcher rejects missing args_template and keeps backend exit codes out of scope status'
else
  ng 'dispatcher rejects missing args_template and keeps backend exit codes out of scope status'
fi

# log 주석 처리: 항목 본문 속 짝 없는 "<!--"가 뒤 항목을 숨기지 않는다 (재진입 fail-open·게이트 오거부 방지)
stray="$pipe/stray"; mkdir -p "$stray/tasks/s/workers/claude-main"
sed 's/^agent_hub_task_id: N\/A$/agent_hub_task_id: task-0123456789abcdef0123456789abcdef/; s/^workers_approved: \[\]$/workers_approved:\n  - worker: claude-main/' \
  "$ROOT/_templates/task.md" >"$stray/tasks/s/task.md"
{ cat "$ROOT/_templates/log.md"
  printf '[2026-01-01 00:00] [DECISION] page uses a stray <!-- marker\n[2026-01-01 00:01] [WORKER_CALL] claude-main brief\n[2026-01-01 00:02] [APPROVAL] claude-main 승인 <!-- inline note -->\n'; } >"$stray/tasks/s/log.md"
printf 'Plan it.\n' >"$stray/tasks/s/workers/claude-main/brief.md"
stray_re_rc=0; "${pipe_env[@]}" bash "$ws/_shared/reentry-check.sh" "$stray/tasks/s" >/dev/null 2>&1 || stray_re_rc=$?
if [ "$stray_re_rc" = 11 ] \
  && env -u CLAUDE_JOB_DIR MULTIAGENT_ROOT="$stray" bash "$ws/_shared/adapters/gate.sh" "$stray/tasks/s/workers/claude-main/brief.md" >/dev/null 2>&1; then
  ok 'stray <!-- inside a log entry does not hide later entries'
else
  ng 'stray <!-- inside a log entry does not hide later entries'
fi

# CRLF 저장된 task.md·brief·log도 같은 판정 (CR 때문에 유효한 Hub ID·scope를 거부하지 않음)
cp -R "$ws/tasks/t" "$ws/tasks/crlf"
for f in task.md log.md workers/claude-main/brief.md workers/codex-main/brief.md; do sed -i.bak 's/$/\r/' "$ws/tasks/crlf/$f" && rm -f "$ws/tasks/crlf/$f.bak"; done
crlf_gate_rc=0; crlf_native_rc=0
"${pipe_env[@]}" bash "$ws/_shared/adapters/gate.sh" "$ws/tasks/crlf/workers/codex-main/brief.md" >/dev/null 2>&1 || crlf_gate_rc=$?
"${pipe_env[@]}" bash "$ws/_shared/adapters/native_worker_receipt.sh" start claude-main "$ws/tasks/crlf/workers/claude-main/brief.md" >/dev/null 2>&1 || crlf_native_rc=$?
if [ "$crlf_gate_rc" = 0 ] && [ "$crlf_native_rc" = 0 ]; then
  ok 'CRLF task files pass the same gate and Hub ID checks'
else
  ng 'CRLF task files pass the same gate and Hub ID checks'
fi

# 승인 로그 형식 문서 = gate가 인정하는 형식 (timestamp 없는 예시 금지), 두 진입점 동일 안내
if ! grep -q '`\[APPROVAL\] ' "$ROOT/_shared/approval-policy.md" "$CLAUDE_FILE" "$AGENTS_FILE" \
  && grep -Fq '[APPROVAL] <role>' "$CLAUDE_FILE" && grep -Fq '[APPROVAL] <role>' "$AGENTS_FILE" \
  && grep -Fq 'call_worker.sh claude-main' "$AGENTS_FILE" && grep -Fq 'call_worker.sh claude-main' "$CLAUDE_FILE" \
  && grep -Fq 'Never substitute a direct `claude` CLI/MCP call' "$AGENTS_FILE"; then
  ok 'approval log format and native claude-main path are documented for both orchestrators'
else
  ng 'approval log format and native claude-main path are documented for both orchestrators'
fi

# Codex 요금가드 워처: 정지는 coach exit 10뿐 — 부재·크래시는 fail-open(문서·Claude 훅과 동일)
watch_case() { # <coach 스크립트 본문 또는 빈 값> → shouldStop 결과 JSON
  local d; d="$(mktemp -d "$scope_tmp/watch.XXXX")"; mkdir -p "$d/bin" "$d/home"
  [ -n "$1" ] && { printf '#!/usr/bin/env bash\n%s\n' "$1" >"$d/bin/coach"; chmod +x "$d/bin/coach"; }
  HOME="$d/home" PATH="$d/bin:/usr/bin:/bin" GUARD_PROVIDERS='codex;rm -rf x' node --input-type=module -e '
    import { spawn } from "node:child_process"; import fs from "node:fs";
    const src = fs.readFileSync(process.argv[1], "utf8");
    const pick = (re) => (src.match(re) || [""])[0];
    const code = pick(/const DEFAULT_PROVIDERS[\s\S]*?DEFAULT_PROVIDERS;/) + "\nconst log = () => {};\n"
      + pick(/function shouldStop\(\) \{[\s\S]*?\n\}\n/);
    const shouldStop = new Function("spawn", "process", code + "\nreturn shouldStop;")(spawn, process);
    console.log(JSON.stringify(await shouldStop()));' "$ROOT/_shared/guard/codex_goal_watch.mjs" 2>/dev/null
}
w_absent="$(watch_case '' || true)"; w_crash="$(watch_case 'exit 1' || true)"
w_stop="$(watch_case 'echo "codex 주간 한도 초과"; exit 10' || true)"
if jq -e '.stop == false' >/dev/null 2>&1 <<<"$w_absent" && jq -e '.stop == false' >/dev/null 2>&1 <<<"$w_crash" \
  && jq -e '.stop == true and (.reason | contains("한도"))' >/dev/null 2>&1 <<<"$w_stop" \
  && grep -Fq 'const DEFAULT_PROVIDERS = "claude,codex,antigravity"' "$ROOT/_shared/guard/codex_goal_watch.mjs"; then
  ok 'Codex guard watcher stops only on coach exit 10 (fail-open otherwise)'
else
  ng 'Codex guard watcher stops only on coach exit 10 (fail-open otherwise)'
fi

# doctor 래퍼: 플러그인 doctor 자체가 실패하면 '이상 없음'으로 보고하지 않는다
fakegen="$pipe/fakegen"; mkdir -p "$fakegen/fragments/guard"
canon_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$SETTINGS" | sed -E 's/^PATH="[^"]*";[[:space:]]*//')"
jq -n --arg c "$canon_cmd" '{hooks:[{type:"command", command:$c}]}' >"$fakegen/fragments/guard/hook.json"
printf 'import sys\nsys.exit("[error] simulated doctor crash")\n' >"$fakegen/store.py"
doc_rc=0; LOADOUT_PLUGIN_DIR="$fakegen" bash "$ROOT/scripts/loadout-doctor.sh" >/dev/null 2>&1 || doc_rc=$?
if [ "$doc_rc" = 1 ]; then
  ok 'doctor wrapper fails closed when the plugin doctor itself fails'
else
  ng 'doctor wrapper fails closed when the plugin doctor itself fails'
fi

if bash "$ROOT/_shared/check-invariants.sh" >/dev/null; then
  ok 'system invariants pass from compatibility verifier'
else
  ng 'system invariants pass from compatibility verifier'
fi

[ "$failures" -eq 0 ]
