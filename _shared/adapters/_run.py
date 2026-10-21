#!/usr/bin/env python3
"""_run.py — call_worker.sh의 timeout 러너 폴백(coreutils timeout/gtimeout 부재 시).
사용: _run.py <timeout_s> <cmd> [args...]
stdin/stdout/stderr를 그대로 통과시키고, 자식 종료코드를 그대로 반환.
timeout 초과 시 프로세스 그룹 종료(TERM→KILL) 후 exit 124. 결정적(레이스 없음)."""
import os
import signal
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: _run.py <timeout_s> <cmd> [args...]\n")
        return 64
    timeout = float(sys.argv[1])
    cmd = sys.argv[2:]
    try:
        proc = subprocess.Popen(cmd, start_new_session=True)  # 자식 프로세스 그룹 분리
    except FileNotFoundError:
        return 127
    try:
        rc = proc.wait(timeout=timeout)
        # 비타임아웃 경로에서 자식이 시그널로 죽으면 wait()가 음수(-N)를 반환한다.
        # 셸 관례(128+시그널)로 정규화해 혼란스러운 256−N 종료코드를 피한다. (타임아웃은 아래에서 124 유지)
        return 128 + (-rc) if rc < 0 else rc
    except subprocess.TimeoutExpired:
        # 타임아웃은 우리가 종료시킨 것이므로 자식의 신호-사망 코드(-15 등)가 아니라
        # 항상 124를 반환한다(coreutils timeout 의미와 일치, docstring 보장).
        _kill_group(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # 직접 자식이 SIGTERM에 먼저 죽어도, TERM을 무시하는 손자가 같은 세션에
        # 남을 수 있다. 그룹 리더(직접 자식)의 생사와 무관하게 항상 SIGKILL까지
        # 올려 그룹 전체를 확실히 제거한다(start_new_session이므로 pgid == proc.pid;
        # 리더가 죽어도 멤버가 있는 한 이 pgid로 그룹에 신호를 보낼 수 있다).
        _kill_group(proc.pid, signal.SIGKILL)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        return 124


def _kill_group(pgid: int, sig: int) -> None:
    # start_new_session=True로 자식을 띄웠으므로 자식 PID가 곧 프로세스그룹 ID다.
    # getpgid()는 리더가 종료하면 ProcessLookupError가 나지만, pgid를 직접 쓰면
    # 멤버(손자 등)가 남아 있는 한 그룹에 신호를 보낼 수 있다.
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


if __name__ == "__main__":
    sys.exit(main())
