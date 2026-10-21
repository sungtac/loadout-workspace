#!/usr/bin/env bash
# 로컬 정본(LOADOUT_LOCAL_COMPAT.md) 인식 Loadout doctor 래퍼 — 읽기 전용.
#
# 플러그인 store.py --doctor는 generic canon(hook.json)과 비교하므로, 이 워크스페이스가
# 의도적으로 적용한 로컬 보정(Stop 훅의 ~/.local/bin PATH 접두사 — LOADOUT_LOCAL_COMPAT.md
# 정본)을 "불일치"로 오탐한다. 이 래퍼는 플러그인 doctor를 그대로 돌리되, 그 guard(claude)
# 훅 WARN을 로컬 정본과 대조해 '의도된 보정=정상(INFO)'으로 재판정하고 집계도 다시 쓴다.
# 플러그인 원본(netwaif/loadout)은 수정하지 않는다(로컬 정본 원칙).
#
# 사용: scripts/loadout-doctor.sh
# 플러그인 경로 재정의: LOADOUT_PLUGIN_DIR=<...>/configure-store/generator scripts/loadout-doctor.sh
set -euo pipefail

ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$ROOT/.claude/settings.json"

# 플러그인 generator 탐색(버전 독립; 최신 버전 선택). env로 재정의 가능.
GEN="${LOADOUT_PLUGIN_DIR:-}"
if [ -z "$GEN" ]; then
  GEN="$(ls -d "$HOME"/.claude/plugins/cache/loadout/loadout/*/skills/configure-store/generator 2>/dev/null | sort -V | tail -n1 || true)"
fi
if [ -z "$GEN" ] || [ ! -f "$GEN/store.py" ]; then
  echo "[error] loadout 플러그인 generator를 찾을 수 없음 — LOADOUT_PLUGIN_DIR로 지정하세요." >&2
  exit 2
fi
STORE="$GEN/store.py"
CANON_HOOK="$GEN/fragments/guard/hook.json"

echo "== loadout doctor (로컬 정본 인식 래퍼) =="
echo "   플러그인: $STORE"
echo "   로컬 정본: $ROOT/LOADOUT_LOCAL_COMPAT.md"
echo

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
raw_rc=0
python3 "$STORE" --target "$ROOT" --doctor >"$tmp" 2>&1 || raw_rc=$?

# 재판정 + 집계 재작성은 python이 담당(견고한 JSON/문자열 비교). 종료코드로 신호.
#   0 = FAIL 없음·실제 WARN 없음, 2 = 실제 WARN 있음(FAIL 없음), 1 = FAIL 또는 guard 로컬정본 불일치
set +e
python3 - "$tmp" "$SETTINGS" "$CANON_HOOK" <<'PY'
import json, re, sys
report_path, settings_path, canon_path = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(report_path, encoding="utf-8").read().splitlines()

WARN_SIG = "guard(claude): Stop 훅이 hook.json 정본과 불일치"

# 로컬 정본 판정: 설치된 guard(claude) 훅이 canonical과 'PATH 보정'만 다른가?
#   "benign"  = 의도된 로컬 보정(재판정 대상)
#   "exact"   = 이미 canonical과 완전 일치
#   "mismatch"= 그 외(진짜 불일치/판정 불가)
def guard_hook_state():
    try:
        stop = json.load(open(settings_path)).get("hooks", {}).get("Stop", [])
        canon = json.load(open(canon_path))["hooks"][0]["command"]
    except Exception:
        return "mismatch"
    cmds = [h.get("command", "") for e in stop for h in (e.get("hooks") or [])
            if "coach --hook" in h.get("command", "")]
    if len(cmds) != 1:
        return "mismatch"
    installed = cmds[0]
    if installed.strip() == canon.strip():
        return "exact"
    m = re.match(r'^\s*PATH=(?:"[^"]*\.local/bin[^"]*"|[^;]*\.local/bin[^;]*)\s*;\s*(.*)$',
                 installed, re.S)
    return "benign" if (m and m.group(1).strip() == canon.strip()) else "mismatch"

state = guard_hook_state()
out = []
for ln in lines:
    if ln.strip().startswith("진단 결과:"):
        continue  # 재집계 후 새로 쓴다
    if state == "benign" and WARN_SIG in ln:
        out.append("  [INFO] guard(claude): Stop 훅이 로컬 정본(LOADOUT_LOCAL_COMPAT.md "
                   "— ~/.local/bin PATH 보정)과 일치 — 플러그인 generic canon과의 차이는 의도됨")
    else:
        out.append(ln)

fails = sum(1 for ln in out if "[FAIL]" in ln)
warns = sum(1 for ln in out if "[WARN]" in ln)

verdict = ("FAIL " + str(fails) + "건" if fails else "구조 이상 없음") \
    + (f", WARN {warns}건" if warns else "")
# 끝의 빈 줄 정리 후 재판정 집계 추가
while out and not out[-1].strip():
    out.pop()
out.append("")
out.append(f"  진단 결과(로컬 정본 재판정): {verdict}")
if state == "benign":
    out.append("  ⌙ generic doctor의 guard(claude) 훅 WARN 1건은 의도된 로컬 보정으로")
    out.append("    확인됨 → 실제 결함 아님(재설치하지 말 것).")
elif state == "mismatch":
    out.append("  ⚠️ guard(claude) Stop 훅이 로컬 정본(PATH 보정)과도 불일치 — 실제 점검 필요.")

print("\n".join(out))

if fails or state == "mismatch":
    sys.exit(1)
sys.exit(2 if warns else 0)
PY
rc=$?
set -e
exit "$rc"
