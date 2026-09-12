#!/usr/bin/python3
"""Run omarchy64-ctl in an isolated session with byte and time bounds.

The child is a new session leader. Overflow, deadline, and SIGTERM/SIGINT
send TERM to the process group, then KILL after --kill-ms. PR_SET_PDEATHSIG
kills the child if this supervisor is SIGKILL'd. Output is copied with a
hard cap so the shell never sees unbounded stdout or stderr.
"""
from __future__ import annotations

import argparse
import ctypes
import fcntl
import os
import select
import signal
import subprocess
import sys
import time

PR_SET_PDEATHSIG = 1


def _prctl_pdeathsig(sig: int) -> None:
    try:
        ctypes.CDLL(None, use_errno=True).prctl(PR_SET_PDEATHSIG, sig, 0, 0, 0)
    except OSError:
        pass


def _preexec() -> None:
    os.setsid()
    _prctl_pdeathsig(signal.SIGKILL)
    if os.getppid() == 1:
        os._exit(1)


def _nonblock(fd: int) -> None:
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)


def _killpg(pid: int, sig: int) -> None:
    try:
        os.killpg(pid, sig)
    except OSError:
        try:
            os.kill(pid, sig)
        except OSError:
            pass


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="omarchy64-run")
    parser.add_argument("--term-ms", type=int, default=8000)
    parser.add_argument("--kill-ms", type=int, default=1000)
    parser.add_argument("--out-bytes", type=int, default=65536)
    parser.add_argument("--err-bytes", type=int, default=4096)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    cmd = args.command
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        print("omarchy64-run: missing command", file=sys.stderr)
        return 2
    if cmd[0] != os.path.abspath(cmd[0]) or not os.path.isfile(cmd[0]):
        print("omarchy64-run: command must be an absolute executable path", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env["PATH"] = "/usr/bin:/bin"
    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONUSERBASE", None)
    env.pop("BASH_ENV", None)
    env.pop("ENV", None)
    env.pop("LD_PRELOAD", None)

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        close_fds=True,
        env=env,
        preexec_fn=_preexec,
    )
    assert proc.stdout is not None and proc.stderr is not None
    _nonblock(proc.stdout.fileno())
    _nonblock(proc.stderr.fileno())

    deadline = time.monotonic() + max(args.term_ms, 1) / 1000.0
    kill_grace = max(args.kill_ms, 1) / 1000.0
    out_lim = max(args.out_bytes, 1)
    err_lim = max(args.err_bytes, 1)
    out_n = 0
    err_n = 0
    killing = False
    kill_at = 0.0
    overflow = False
    timed_out = False
    pgid = proc.pid

    def begin_kill(reason: str) -> None:
        nonlocal killing, kill_at, overflow, timed_out
        if reason == "overflow":
            overflow = True
        if reason == "timeout":
            timed_out = True
        if killing:
            return
        killing = True
        kill_at = time.monotonic() + kill_grace
        _killpg(pgid, signal.SIGTERM)

    def on_signal(sig: int, _frame: object) -> None:
        begin_kill("signal")

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    streams = {
        proc.stdout.fileno(): ("out", proc.stdout, sys.stdout.buffer),
        proc.stderr.fileno(): ("err", proc.stderr, sys.stderr.buffer),
    }

    while True:
        now = time.monotonic()
        if not killing and now >= deadline:
            begin_kill("timeout")
        if killing and now >= kill_at:
            _killpg(pgid, signal.SIGKILL)

        fds = [fd for fd in streams]
        if not fds:
            break
        timeout = 0.05
        if killing:
            timeout = min(timeout, max(0.0, kill_at - now))
        else:
            timeout = min(timeout, max(0.0, deadline - now))
        readable, _, _ = select.select(fds, [], [], timeout)
        for fd in readable:
            kind, src, dst = streams[fd]
            chunk = src.read(4096)
            if not chunk:
                src.close()
                del streams[fd]
                continue
            if kind == "out":
                room = out_lim - out_n
                out_n += len(chunk)
                if room > 0:
                    dst.write(chunk[:room])
                    dst.flush()
                if out_n > out_lim:
                    begin_kill("overflow")
            else:
                room = err_lim - err_n
                err_n += len(chunk)
                if room > 0:
                    dst.write(chunk[:room])
                    dst.flush()
                if err_n > err_lim:
                    begin_kill("overflow")

        rc = proc.poll()
        if rc is not None and not streams:
            break
        if rc is not None and killing and now >= kill_at:
            break

    if proc.poll() is None:
        _killpg(pgid, signal.SIGKILL)
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass

    if overflow:
        print("omarchy64-run: output exceeds limit", file=sys.stderr)
        return 1
    if timed_out:
        print("omarchy64-run: controller timed out", file=sys.stderr)
        return 124
    rc = proc.returncode
    if rc is None:
        return 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
