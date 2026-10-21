# Codex MultiAgent Orchestration — Operating Rules

## External/Paid Model Approval

- Do not run external or paid model CLIs, MCPs, or agent bridges without explicit user approval for that specific task.
- This includes, but is not limited to, `claude`, `gemini`, `openai`, `llm`, Claude Code MCP, Gemini MCP, and similar tools.
- A request to translate, summarize, review, research, or process a large file does not imply approval to use external paid models.
- Before using an external paid model, state the exact tool/model, why it is needed, and that it may consume tokens, quota, or money. Wait for explicit approval.
- Local shell commands, file parsing, format validation, current Codex reasoning, and edits inside this workspace are allowed unless the user says otherwise.

## Architecture

```
Orchestrator (current provider: Codex or Claude, internal reasoning)
└── Worker Pool (separate worker/model calls — approval required)
    ├── codex-main      [engineer] large, separable implementation · analysis · tests · local verification · image generation
    ├── claude-critic   [reviewer · strategist quality gate] Codex output review · adversarial critique
    └── gemini          [multimodal] multimodal · long document · third-party perspective
```

Slot→assignee mapping is owned by `_shared/capability-profile.md` (variable layer — update only the profile when a new model generation shifts the verdict). The engineer and computer-use slots default to the Orchestrator itself.

**Important**: The Orchestrator's internal reasoning is not a worker. A separate `codex-main`, `claude-critic`, or `gemini` call is a worker/model call and must pass the approval gate for the task.

## Operating Principles

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

**Layered application**: The full four principles above bind the Orchestrator (this session) only. The single source of truth for the worker layer is the fixed "Worker 행동 규약" block in `_templates/worker-brief.md` — principles ② and ③ as-is; principle ① translated (workers are one-shot/headless with no user-question channel → state assumptions, surface uncertainty and mismatches in result.md Issues/Caveats); the principle ④ loop is orchestrator-only (combined with the Verification Checklist loop). Never instruct a worker brief to ask the user.

> Source: [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills) (MIT) — adapted. See `NOTICE`.

## Task Lifecycle

1. Create `tasks/<task-name>/task.md` (`status: pending`) — **use the `_templates/task.md` format exactly** (`## 메타` yaml fence + `## Goal`; no `---` frontmatter — the mat monitor parses this format). If the new folder is a follow-up, handoff, or sub-step of an existing task, first apply `_shared/orchestrator-rules.md` §3 "new task-folder creation gate" before creating it.
2. Read `_shared/routing.md` and choose the minimum worker set.
3. Confirm **target_repo** when the task will produce external files:
   - If `codex-main` is planned, or the task creates code, docs, or images for another repo, ask for `target_repo` before filling `task.md`.
   - If the user says there is no external target, or the task is analysis/review/planning only, keep outputs under `tasks/<task>/artifacts/`.
   - If the user already provided a path, do not ask again.
4. Every worker used (the entire pool, including cross-vendor `claude-main`/`claude-critic`) must be explicitly recorded in `task.md` `workers_approved` before any worker call.
5. Write each worker's brief **exactly at `tasks/<task>/workers/<role>/brief.md`** (Korean <= 1200 chars / English <= 240 words). Use a per-worker folder — do NOT flatten to `<role>_brief.md`.
6. Run the approved worker and save the original response **at `tasks/<task>/workers/<role>/result.md`** (same per-worker folder). `claude-critic`·`gemini` workers MUST be called through the dispatcher (`call_worker.sh`); the dispatcher always runs gate and, in a Git workspace, runs scope_check automatically (non-Git → `scope_check: skipped`; the Codex sandbox and task cwd are the write boundary). A native `codex-main` call MUST first reserve a Hub receipt with `native_worker_receipt.sh start codex-main <brief>` and record `complete` with the same `dispatch_id` after the call; this path also passes gate, and a native call without a Hub task ID is forbidden. Calling MCP directly is not the standard path and is forbidden.
7. Execute the `result.md` Verification Checklist.
8. Append verification results to `log.md` with `[VERIFICATION]`. When the task is finished, update `status` in `task.md` to `done`.
9. On completion, append lessons, classified: **general lessons about running the system itself** → `_shared/learnings.md` (tracked/public). **Lessons specific to one external project** (mat·hwpx, etc.) → `_local/learnings.md` (git-untracked; create if absent). `_local/learnings.md` is not loaded unless explicitly requested.

> When resuming an existing task, start with `_shared/orchestrator-rules.md` section 3 re-entry protocol, not step 1. The first re-anchor action is `bash _shared/reentry-check.sh tasks/<task>` (status↔log consistency + per-role brief/result table).

## Context Rules

| File | Limit | Purpose |
|------|-------|---------|
| `context.md` | Korean <= 1500 chars / English <= 300 words | Current snapshot only, not history |
| `brief.md` | Korean <= 1200 chars / English <= 240 words | Only what the worker needs |
| `sources/` | Unlimited | Source material, referenced by path |
| `artifacts/` | Unlimited | Raw outputs and generated files |

Measurement:

```bash
wc -m tasks/<task>/context.md
wc -w tasks/<task>/context.md
```

If `context.md` exceeds the limit, append history to `log.md`, then keep only the current snapshot. Never inline long source files into `context.md` or `brief.md`; pass paths. A call that needs a large attached document (e.g. a gemini source review) uses a `sources/` packet file plus the dispatcher payload argument (`call_worker.sh <role> <brief> <packet>`) — the brief limit and the no-inline rule still hold.

## Approval Gate

- Never call a worker that is missing from `workers_approved` (applies to the entire worker pool).
- **Enforcement**: `_shared/adapters/gate.sh` decides fail-closed (G2 approval · G3 `[APPROVAL]` log entry · G1 brief location · G4 length limit · G5 external-write conditions · G0 interactive session). Automatic through the dispatcher (claude-critic·gemini); run it before native calls only (Task Lifecycle step 6).
- Worker approval is task-specific and includes purpose and any external write scope.
- The Orchestrator's internal reasoning does not require approval.
- External paid model tools still require explicit user approval even if the task is already created.

## Verification

Before accepting a worker result, execute the `result.md` Verification Checklist and append the result to `log.md`.

Default checks:
- [ ] output matches `brief.md` `Output Format`
- [ ] referenced paths exist
- [ ] `task.md` constraints are satisfied
- [ ] `Do NOT` items are not violated

## log.md Rules

- Append-only. Do not edit or delete prior log entries.
- Format: `[YYYY-MM-DD HH:MM] [TAG] content`
- Allowed tags: `DECISION | WORKER_CALL | VERIFICATION | ERROR | APPROVAL | COMPLETE`

## Worker File Write Policy

| Worker | Default write permission | External repo write |
|--------|--------------------------|---------------------|
| codex-main | `tasks/<task>/` outputs/diffs | Conditional |
| claude-critic | None; Orchestrator records the dispatcher response | Never |
| gemini | None; Orchestrator records the dispatcher response | Never |

### `write_scope` Values

- `none` — no writes
- `tasks-only` — write only inside `tasks/<task>/`
- `"src/**, tests/**"` style patterns — external repo paths allowed only when all 4 conditions below are met

### codex-main External Repo Write Conditions

All 4 are required:

1. `brief.md` includes `target_repo: <absolute path>`.
2. `brief.md` includes `write_scope: <allowed path pattern>`.
3. `task.md` `workers_approved` includes `codex-main` and the approved `write_scope`.
4. `log.md` has a separate `[APPROVAL]` entry for external write approval.

If any condition is missing, `codex-main` writes only inside `tasks/<task>/`, preferably as a diff or patch for user/orchestrator application.

**Enforcement**: pre-call = `gate.sh` G5 — the approval entry's `target_repo` and `write_scope` must **exactly match** the brief, and the `[APPROVAL]` log line must name the same worker together with the `write_scope` value (a changed value requires re-approval). Post-call = `scope_check.sh` — compares before/after snapshots (status + content hash) and **reports** out-of-scope changes (status `scope_violation`, exit 10, never auto-reverts — acceptance is the orchestrator's decision). With `none`/`tasks-only` the cwd is isolated to the current `tasks/<task>/` folder, and `tasks-only` allows only that task folder. Ignored files are included in the Git check; only non-git targets are `scope_check: skipped`. A failed check is reported separately as `scope_error` (exit 12, no fallback).

Workers must never edit `_shared/`, `_templates/`, or another task folder unless the current task is explicitly a system maintenance task.

## AGENTS.md Scope

These workspace-specific orchestration rules do not apply in other directories (intended isolation). The common completion/verification loop rules apply separately through Codex's and Claude's global guidance. Do not copy this orchestration policy into unrelated projects.

<!-- store:agent-loop:start -->
## 에이전트 루프

### 입력 (루프 시작 조건)
- 목표는 검증 가능한 완료조건과 함께 받는다. 표준 입력 3종: 목표 프롬프트 · 채점표(합격 기준 체크리스트) · 참고자료. (양식: `prep/goal-prompt.template.md`, `prep/채점표.template.md`)
- 완료조건 없는 목표는 시작 전에 되물어 확정한다.

### 실행 규율
- 산출물마다 [생성 → 채점표 검수 → 미달 지적 → 수정] 루프를 돈다. 전 항목 PASS = 합격.
- 이터레이션 캡: 산출물별 최대 횟수를 정해두고, 도달 시 멈추고 사람에게 보고한다.
- 환경 문제(도구 미설치 등)는 먼저 자동 해결을 시도하고, 안 되면 그때만 멈추고 알린다.

### 합격 처리 규율
- 실물 산출물이 있어야 완료다. "텍스트만 + 사용자가 수동으로" 핸드오프는 미완.
- BLOCKED를 합격으로 처리하지 않는다.

### 예외 시 사람 호출
- 막히거나 캡 도달 시 알림(디스코드 등) → 해당 건 보류, 가능한 다른 산출물은 계속 진행.
- 철학: 무결점 자율이 아니라 "예외 시 알림 + 개입 채널"이 안전망이다.

### 조건부
- [멀티에이전트도 설치된 경우] 검수를 워커에 디스패치한다 — 메이커가 만든 산출물을 다른 모델이 채점한다(텍스트=codex-critic, 이미지=gemini, `_shared/routing.md` 준수). 루프 진행은 task 폴더(task.md·log.md·workers/)에 기록한다(모니터링 도구가 읽음).
- [요금가드도 설치된 경우] 가드 발동 시 루프를 멈추고 알린다.
<!-- store:agent-loop:end -->

### 공통 루프 적용 범위
이 조각의 Claude 전용 표현과 일률적 질문·채점표·워커 호출은 전역 provider-neutral orchestrator loop 지침보다 우선하지 않는다. 현재 Codex 또는 Claude 오케스트레이터가 작업 크기에 맞게 루프를 진행하며, Hub 전환 시 기존 원장 계약을 따른다.

<!-- store:knot:start -->
## knot — 지식 vault (선택)
환경변수 $KNOT_VAULT 가 설정돼 있고 현재 작업이 거기 저장된 지속가치 지식과 관련될 때만:
먼저 $KNOT_VAULT/wiki/ 의 관련 페이지를 참고하고, 새로 알게 된 지속가치 있는 내용은
$KNOT_VAULT/prompts/ingest.md 규약대로 ingest를 고려한다.
$KNOT_VAULT 미설정이거나 무관한 작업에서는 이 절을 무시한다.
<!-- store:knot:end -->

<!-- store:guard:start -->
## goal 요금가드 (Codex)

`/goal` 자율 루프가 주간 사용량 한도에 닿으면 자동으로 멈추는 안전장치다. 판정 정책은 `coach`(usage-coach)가 단일 정본으로 갖고, Codex에서는 외부 워처 `_shared/guard/codex_goal_watch.mjs`가 그 결정을 집행한다(Codex `/goal` 런타임은 Stop 훅 정지를 무시 — 실측. 네이티브 정지 = `thread/goal/clear`).

- 전제: codexbar + `coach`(PATH에 있어야). 미설치·조회 실패·플래그 off는 전부 fail-open — 작업을 죽이지 않는다.
- 실행 3단계 (포트 셋이 같아야 함, 기본 47931):
  1. 가드용 ws app-server 기동: `codex app-server --listen ws://127.0.0.1:47931`
  2. `/goal` 세션을 그 서버에 attach해서 시작: `codex --remote ws://127.0.0.1:47931` (`--remote` 없이 띄우면 워처가 thread를 못 본다)
  3. 워처 실행: `node _shared/guard/codex_goal_watch.mjs`
- 런타임 스위치: `coach guard on` / `coach guard off` / 상태·미리보기 `coach guard status`.
- ⚠️ loopback ws 서버는 무인증(127.0.0.1 바인드만) — 신뢰된 단일 사용자 머신 가정, 원격 노출 금지.
- 상세(환경변수·동작·끄기): `_shared/guard/README.md`
- 받기 — coach: https://github.com/netwaif/usage-coach · codexbar: https://github.com/steipete/CodexBar
<!-- store:guard:end -->

## Local Loadout Compatibility

이 작업공간의 실행 경로·knot Vault 해석·guard 활성화 조건은 `LOADOUT_LOCAL_COMPAT.md`가 정본이다. Marketplace 플러그인 원본은 직접 수정하지 않는다.
