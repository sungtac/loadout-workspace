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
chmod +x "$fakebin/agent-hub" "$fakebin/codex"
printf '{"hub_root":"%s","cli":"%s"}\n' "$pipe/hub" "$fakebin/agent-hub" >"$ws/_local/agent-hub-bridge.json"
sed 's/^agent_hub_task_id: N\/A$/agent_hub_task_id: task-0123456789abcdef0123456789abcdef/; s/^workers_approved: \[\]$/workers_approved:\n  - worker: claude-main\n  - worker: codex-main/' \
  "$ROOT/_templates/task.md" >"$ws/tasks/t/task.md"
cp "$ROOT/_templates/log.md" "$ws/tasks/t/log.md"
cp "$ROOT/_templates/context.md" "$ws/tasks/t/context.md"
printf 'Plan it.\n' >"$ws/tasks/t/workers/claude-main/brief.md"
printf 'target_repo: N/A\nwrite_scope: tasks-only\n\nDo it.\n' >"$ws/tasks/t/workers/codex-main/brief.md"
pipe_env=(env -u AGENT_HUB_ROOT -u AGENT_HUB_CLI -u CLAUDE_JOB_DIR MULTIAGENT_ROOT="$ws" FAKE_HUB_LOG="$pipe/hub.log" PATH="$fakebin:$PATH")

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

# 디스패처: native 역할은 Hub 예약 전에 exit 3, backend 사전중단도 JSON envelope 유지
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

if bash "$ROOT/_shared/check-invariants.sh" >/dev/null; then
  ok 'system invariants pass from compatibility verifier'
else
  ng 'system invariants pass from compatibility verifier'
fi

[ "$failures" -eq 0 ]
