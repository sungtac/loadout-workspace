#!/usr/bin/env bash
# scope_check.sh — write_scope 사후 검사 (보고만, 파일 비접촉). 벤더중립(bash+git).
# 사용: scope_check.sh --snapshot <repo>                         # 실행 전 스냅샷을 stdout으로 (버전 표식+줄 레코드)
#       scope_check.sh <repo> <write_scope> <before-file> [task]  # 실행 후 대조
#   스냅샷 레코드 = "XY<TAB>hex(path)<TAB>hash" 한 줄. path는 <repo> 기준 상대경로(git 루트가 상위여도 정규화),
#   hex 인코딩이라 탭·줄바꿈 파일명도 손실 없음(BSD grep은 -z와 -f 조합이 불안정해 NUL 레코드 대신 사용).
#   hash = 내용 해시(git hash-object) → 기존 dirty/untracked 재수정도 검출.
#   write_scope: none | tasks-only | "src/**, tests/**" (콤마 구분 glob; * 가 / 를 넘어 매칭)
#   tasks-only 는 작업 폴더를 repo로 받을 때는 그 내부 전체, 루트를 repo로 받을 때는
#   tasks/<task>/* 만 허용([task] 인자 필수). rename은 원본·목적지 둘 다 검사.
#   <repo> 밖(같은 git 루트의 다른 경로) 변경은 항상 위반.
# 출력: scope 밖 변경 경로를 stdout 한 줄씩. exit 10=위반 / 0=정상 / 12=검사 불가(비git·git 명령 실패·스냅샷 손상) / 64=usage
#   ignored 파일도 검사한다. 파일을 절대 수정하지 않는다.
set -uo pipefail
hexenc() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
hexdec() { printf "$(sed 's/../\\x&/g' <<<"$1")"; }

toplevel() { git -C "$1" rev-parse --show-toplevel 2>/dev/null; }

snapshot() { # snapshot <repo> → stdout 형식표식+레코드. 실패 시 exit 12.
  local repo="$1" top prefix raw st path src p hash meta_hash
  top="$(toplevel "$repo")" || { echo "scope_check: git repo 아님: $repo" >&2; return 12; }
  repo="$(cd "$repo" && pwd -P)"; prefix="${repo#"$top"}"; prefix="${prefix#/}"   # repo가 루트면 ""
  raw="$(mktemp)" || return 12
  # ignored task artifacts도 scope 밖 쓰기 탐지 대상이다. traditional은 ignored
  # 디렉터리 내부 파일을 개별 보고한다(matching은 디렉터리 하나로 축약해 변경을 놓친다).
  if ! git -C "$top" status --porcelain -z -uall --ignored=traditional >"$raw" 2>/dev/null; then rm -f "$raw"; echo "scope_check: git status 실패: $top" >&2; return 12; fi
  printf '%s\n' '# scope-snapshot-v1'
  local ok=1
  while IFS= read -r -d '' entry; do
    st="${entry:0:2}"; path="${entry:3}"; src=""
    case "$st" in R?|C?|?R|?C) IFS= read -r -d '' src || true;; esac
    for p in "$path" "$src"; do
      [ -n "$p" ] || continue
      if [ -f "$top/$p" ]; then
        hash="$(git -C "$top" hash-object -- "$p" 2>/dev/null)" || { echo "scope_check: hash 실패: $p" >&2; ok=0; continue; }
      else hash="absent"; fi
      # repo 기준 상대경로로 정규화. repo 밖(같은 루트의 다른 경로)은 "../"+절대표기로 남겨 위반으로 잡히게 함
      if [ -n "$prefix" ]; then
        case "$p" in "$prefix"/*) p="${p#"$prefix"/}";; *) p="../$p";; esac
      fi
      printf '%s\t%s\t%s\n' "$st" "$(hexenc "$p")" "$hash"
    done
  done <"$raw"
  # 커밋·ref 이동과 .git 정책(config/hooks) 변경은 working-tree status에 나타나지 않는다.
  # 별도 합성 레코드로 기록해 scope 밖 커밋·hook 주입을 탐지한다.
  meta_hash="$(
    {
      git -C "$top" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' 'UNBORN'
      git -C "$top" symbolic-ref -q HEAD 2>/dev/null || true
      git -C "$top" config --null --list --show-origin 2>/dev/null || true
      hooks_dir="$(git -C "$top" rev-parse --git-path hooks 2>/dev/null)"
      case "$hooks_dir" in /*) ;; *) hooks_dir="$top/$hooks_dir";; esac
      [ -d "$hooks_dir" ] && find "$hooks_dir" -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum 2>/dev/null || true
    } | git hash-object --stdin 2>/dev/null
  )" || { echo "scope_check: git 관리영역 해시 실패" >&2; ok=0; }
  [ -n "$meta_hash" ] && printf 'G \t%s\t%s\n' "$(hexenc '.git/.scope-git-policy-state')" "$meta_hash"
  # 중첩 Git 저장소는 상위 git status가 디렉터리 하나로만 요약할 수 있다.
  # 각 중첩 저장소의 상태를 합성 레코드로 넣어 내부 변경도 before/after에 반영한다.
  while IFS= read -r -d '' gitdir; do
    nested="${gitdir%/.git}"
    [ "$nested" = "$top" ] && continue
    nested_rel="${nested#"$top"/}"
    # 실제 파일별 레코드로 좁은 패턴(vendor/lib/src/** 등)도 정확히 판정한다.
    while IFS= read -r -d '' nested_file; do
      record_path="${nested_file#"$top"/}"
      nested_hash="$(git hash-object -- "$nested_file" 2>/dev/null)" \
        || { echo "scope_check: 중첩 git 파일 해시 실패: $record_path" >&2; ok=0; continue; }
      if [ -n "$prefix" ]; then
        case "$record_path" in "$prefix"/*) record_path="${record_path#"$prefix"/}";; *) record_path="../$record_path";; esac
      fi
      printf 'S \t%s\t%s\n' "$(hexenc "$record_path")" "$nested_hash"
    done < <(find "$nested" -path "$nested/.git" -prune -o -type f -print0 2>/dev/null)
    nested_hash="$(git -C "$nested" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' 'UNBORN')"
    record_path="$nested_rel/.git/.scope-git-ref-state"
    if [ -n "$prefix" ]; then
      case "$record_path" in "$prefix"/*) record_path="${record_path#"$prefix"/}";; *) record_path="../$record_path";; esac
    fi
    printf 'S \t%s\t%s\n' "$(hexenc "$record_path")" "$nested_hash"
  done < <(find "$top" \( -type d -o -type f \) -name .git -print0 2>/dev/null)
  rm -f "$raw"
  [ "$ok" = 1 ] || return 12
  return 0
}

if [ "${1:-}" = "--snapshot" ]; then
  REPO="${2:-}"; [ -n "$REPO" ] || { echo "usage: scope_check.sh --snapshot <repo>" >&2; exit 64; }
  out="$(mktemp)"; snapshot "$REPO" >"$out"; rc=$?
  [ "$rc" = 0 ] && cat "$out"; rm -f "$out"; exit "$rc"
fi

REPO="${1:-}"; SCOPE="${2:-}"; BEFORE="${3:-}"; TASK="${4:-}"
[ -n "$REPO" ] && [ -n "$SCOPE" ] && [ -n "$BEFORE" ] || { echo "usage: scope_check.sh <repo> <write_scope> <before-file> [task]" >&2; exit 64; }
[ -f "$BEFORE" ] || { echo "scope_check: before 스냅샷 없음: $BEFORE" >&2; exit 64; }
IFS= read -r snapshot_header <"$BEFORE" || true
[ "$snapshot_header" = '# scope-snapshot-v1' ] || { echo "scope_check: before 스냅샷 형식 오류" >&2; exit 12; }
toplevel "$REPO" >/dev/null || { echo "scope_check: git repo 아님 — 검사 불가: $REPO" >&2; exit 12; }

PATS=()
case "$SCOPE" in
  none)       ;;
  tasks-only)
    [ -n "$TASK" ] || { echo "scope_check: tasks-only 는 [task] 인자 필요" >&2; exit 64; }
    # call_worker는 tasks-only에서 repo(cwd) 자체를 tasks/<task>로 넘긴다.
    # snapshot은 repo 기준 상대경로를 내므로 이 경우 "*"가 유일하게 올바른 범위다.
    # 독립 호출로 루트를 받는 기존 계약도 유지한다.
    repo_abs="$(cd "$REPO" && pwd -P)"
    case "$repo_abs" in */tasks/"$TASK") PATS=("*");; *) PATS=("tasks/$TASK/*");; esac
    ;;
  *) IFS=',' read -r -a _raw <<<"$SCOPE"
     for p in "${_raw[@]}"; do p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"; [ -n "$p" ] && PATS+=("$p"); done;;
esac
allowed() { local f="$1" p; case "$f" in ../*) return 1;; esac; for p in "${PATS[@]:-}"; do [ -n "$p" ] && [[ "$f" == $p ]] && return 0; done; return 1; }

AFTER="$(mktemp)"; DIFF="$(mktemp)"; trap 'rm -f "$AFTER" "$DIFF"' EXIT
snapshot "$REPO" >"$AFTER" || { echo "scope_check: after 스냅샷 실패 — 검사 불가" >&2; exit 12; }
# 양방향 차집합 → hex 경로만 추출·중복 제거 → 디코드 후 판정
{ grep -Fxv -f "$BEFORE" "$AFTER" 2>/dev/null; grep -Fxv -f "$AFTER" "$BEFORE" 2>/dev/null; } | cut -f2 | sort -u >"$DIFF" || true
rc=0
while IFS= read -r hex; do
  [ -n "$hex" ] || continue
  path="$(hexdec "$hex"; printf x)"; path="${path%x}"   # 명령치환의 후행 개행 보존
  allowed "$path" || { printf '%s\n' "$path"; rc=10; }
done <"$DIFF"
exit "$rc"
