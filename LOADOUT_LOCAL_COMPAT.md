# Loadout 로컬 호환 계약

이 파일은 Marketplace 플러그인 원본을 수정하지 않고 이 작업공간에서만 적용하는 운영 계약이다.

## 실행 경로

- `codex-main`과 `codex-critic`의 표준 경로는 `_shared/adapters/call_worker.sh`의 CLI 디스패처다.
- 디스패처는 `gate.sh`를 항상 실행하고, Git 작업공간이면 `scope_check.sh`도 자동 실행한다. 비Git 작업공간에서는 `scope_check` 결과가 `skipped`이며 Codex sandbox와 task cwd 격리가 쓰기 경계다.
- `none`·`tasks-only` Codex 작업은 `tasks/<task>/`가 cwd다. task 내부 파일은 로컬 상대경로, workspace 수준 파일은 절대경로로 brief에 적는다.
- MCP를 수동으로 직접 호출하는 것은 이 작업공간의 표준 경로가 아니며, gate와 scope 검사를 우회할 수 있으므로 사용하지 않는다.

## knot Vault 해석

1. `KNOT_VAULT` 환경변수가 설정돼 있으면 그 경로가 정본이다.
2. 없으면 `~/.config/knot/vault`의 비어 있지 않은 첫 줄을 Vault 경로로 사용한다.
3. 둘 다 없으면 knot은 비활성(no-op)이다. 이 상태에서 Vault를 자동 생성하거나 지식을 기록하지 않는다.

## goal 요금가드

- Stop Hook은 `~/.local/bin`을 PATH에 추가한 뒤 `coach --hook`을 호출한다.
  - 이 PATH 보정 때문에 플러그인 generic doctor(`store.py --doctor`)는 "guard(claude): Stop 훅이 hook.json 정본과 불일치"로 **오탐(WARN)**한다. 이는 의도된 로컬 보정이므로 canon으로 재설치하지 말 것(재설치하면 PATH 보정이 제거돼 최소 환경에서 `coach` 미발견 → guard 무력화). 로컬 정본을 인식하는 `scripts/loadout-doctor.sh`가 이 WARN을 정상(INFO)으로 재판정한다.
- 현재 guard는 `off`다. 활성화 전에는 `coach guard status`로 정책을 재확인한다.
- guard가 중지한 작업은 자동 재할당하지 않는다. 재개·handoff는 사용자의 명시적 지시와 Agent Hub 원장 계약이 준비된 뒤에만 수행한다.

## 업데이트와 검증

- Marketplace 업데이트 뒤에는 `bash scripts/verify-loadout-compat.sh`를 실행한다.
- 구성 점검(doctor)은 플러그인 `store.py --doctor` 대신 **`bash scripts/loadout-doctor.sh`**(로컬 정본 인식 래퍼)를 사용한다. generic doctor를 그대로 돌리되 로컬 보정으로 인한 오탐을 재판정한다(읽기 전용, 플러그인 미수정).
- 검증 실패 시 플러그인 캐시를 직접 편집하지 않고, 로컬 계약을 갱신하거나 upstream 이슈로 관리한다.
