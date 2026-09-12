#!/usr/bin/python3
"""Descriptor-retained reads and installs for omarchy64 state files.

Every parent is opened with openat(O_DIRECTORY|O_NOFOLLOW) from /, the
directory fd is kept, and the leaf is created/replaced with
O_CREAT|O_EXCL|O_NOFOLLOW plus renameat on that same fd.
"""
from __future__ import annotations

import argparse
import errno
import fcntl
import glob
import os
import stat
import sys

PLUGIN_OWNED = {"omarchy", "toggles", "hypr"}
DEFAULT_LIMIT = 65536
JOYMAP_ABS_HAT0X = 16


def _die(msg: str, code: int = 1) -> None:
    print(f"omarchy64-fs: {msg}", file=sys.stderr)
    raise SystemExit(code)


def _abs_parts(path: str) -> tuple[list[str], str]:
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        _die(f"path must be absolute: {path}")
    parent, name = os.path.split(path)
    if not name or name in (".", "..") or "/" in name or "\0" in name:
        _die(f"invalid destination name: {path}")
    parts: list[str] = []
    for comp in parent.split("/"):
        if not comp or comp == ".":
            continue
        if comp == ".." or "/" in comp or "\0" in comp:
            _die(f"invalid path component in {path}")
        parts.append(comp)
    return parts, name


def _dir_flags() -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    flags |= getattr(os, "O_NONBLOCK", 0)
    return flags


def open_parent(path: str, create: bool = True) -> tuple[int, str]:
    """Return (dirfd, leaf name) for path, walking from / without following symlinks."""
    parts, name = _abs_parts(path)
    dirfd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    uid = os.getuid()
    owned = False
    try:
        for comp in parts:
            if comp in PLUGIN_OWNED:
                owned = True
            nxt = None
            created = False
            try:
                nxt = os.open(comp, _dir_flags(), dir_fd=dirfd)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(comp, 0o700, dir_fd=dirfd)
                created = True
                nxt = os.open(comp, _dir_flags(), dir_fd=dirfd)
            try:
                st = os.fstat(nxt)
                if not stat.S_ISDIR(st.st_mode):
                    raise OSError(errno.ENOTDIR, "not a directory", comp)
                if created and st.st_uid != uid:
                    raise OSError(errno.EPERM, "unowned directory", comp)
                if owned and st.st_uid == uid:
                    os.fchmod(nxt, 0o700)
            except Exception:
                os.close(nxt)
                raise
            os.close(dirfd)
            dirfd = nxt
        return dirfd, name
    except Exception:
        os.close(dirfd)
        raise


def _is_symlink(dirfd: int, name: str) -> bool:
    try:
        st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return stat.S_ISLNK(st.st_mode)


def _is_reg(dirfd: int, name: str) -> bool:
    try:
        st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return stat.S_ISREG(st.st_mode)


def atomic_install(path: str, data: bytes, mode: int = 0o600, if_absent: bool = False) -> None:
    dirfd, name = open_parent(path, create=True)
    tmp = None
    fd = -1
    try:
        if _is_symlink(dirfd, name):
            raise OSError(errno.ELOOP, f"refusing to write through symlink: {path}")
        if if_absent and _is_reg(dirfd, name):
            return
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | os.O_CLOEXEC
            | getattr(os, "O_NONBLOCK", 0)
        )
        tmp = f".{name}.{os.getpid()}.{os.urandom(8).hex()}.tmp"
        fd = os.open(tmp, flags, mode, dir_fd=dirfd)
        os.fchmod(fd, mode)
        fl = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, fl & ~os.O_NONBLOCK)
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            if n <= 0:
                raise OSError("short write")
            view = view[n:]
        os.fsync(fd)
        if _is_symlink(dirfd, name):
            raise OSError(errno.ELOOP, f"refusing to write through symlink: {path}")
        if if_absent and _is_reg(dirfd, name):
            os.close(fd)
            fd = -1
            os.unlink(tmp, dir_fd=dirfd)
            tmp = None
            return
        os.rename(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        os.fsync(dirfd)
        tmp = None
    finally:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp is not None:
            try:
                os.unlink(tmp, dir_fd=dirfd)
            except OSError:
                pass
        os.close(dirfd)


def read_file(path: str, limit: int) -> bytes:
    dirfd, name = open_parent(path, create=False)
    fd = -1
    try:
        flags = (
            os.O_RDONLY
            | os.O_NOFOLLOW
            | os.O_CLOEXEC
            | getattr(os, "O_NONBLOCK", 0)
        )
        fd = os.open(name, flags, dir_fd=dirfd)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise OSError(errno.EINVAL, "not a regular file", path)
        if st.st_nlink != 1:
            raise OSError(errno.EPERM, "refusing hard-linked file", path)
        fl = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, fl & ~os.O_NONBLOCK)
        data = b""
        while len(data) <= limit:
            chunk = os.read(fd, min(8192, limit + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        if len(data) > limit:
            raise OSError(errno.EFBIG, f"file exceeds {limit} bytes", path)
        return data
    finally:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        os.close(dirfd)


def mkdir_p(path: str) -> None:
    dirfd, name = open_parent(os.path.join(path, ".keep"), create=True)
    os.close(dirfd)
    del name


def _abs_bits(js_name: str) -> int:
    path = f"/sys/class/input/{js_name}/device/capabilities/abs"
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(path, flags)
        try:
            raw = os.read(fd, 64).decode("utf-8", "replace")
        finally:
            os.close(fd)
        return int(raw.split()[0], 16)
    except (OSError, ValueError):
        return 0x3


def generate_joymap() -> bytes:
    lines = [
        "# generated by omarchy64-ctl for the current SDL/js devices",
        "",
        "!CLEAR",
    ]
    nodes = sorted(glob.glob("/dev/input/js*"))
    if not nodes:
        nodes = ["js0"]
    for i, node in enumerate(nodes):
        name = os.path.basename(node)
        bits = _abs_bits(name)
        lines.append(f"# {name}")
        lines += [
            f"{i} 0 0 1 8",
            f"{i} 0 1 1 4",
            f"{i} 0 2 1 2",
            f"{i} 0 3 1 1",
            f"{i} 1 0 1 16",
            f"{i} 1 1 1 16",
            f"{i} 1 2 1 16",
            f"{i} 1 3 1 16",
        ]
        if bits & (1 << JOYMAP_ABS_HAT0X):
            lines += [
                f"{i} 2 0 1 1",
                f"{i} 2 1 1 2",
                f"{i} 2 2 1 4",
                f"{i} 2 3 1 8",
            ]
        lines.append("")
    return ("\n".join(lines) + "\n").encode("utf-8")


def _read_stdin(limit: int) -> bytes:
    data = b""
    while len(data) <= limit:
        chunk = os.read(sys.stdin.fileno(), min(8192, limit + 1 - len(data)))
        if not chunk:
            break
        data += chunk
    if len(data) > limit:
        _die(f"input exceeds {limit} bytes")
    return data


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="omarchy64-fs")
    parser.add_argument("action", choices=("install", "install-if-absent", "read", "mkdir", "joymap"))
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("path")
    args = parser.parse_args(argv)
    limit = args.limit
    if limit < 1 or limit > 1024 * 1024:
        _die("invalid --limit")
    path = args.path
    try:
        if args.action == "install":
            atomic_install(path, _read_stdin(limit))
        elif args.action == "install-if-absent":
            atomic_install(path, _read_stdin(limit), if_absent=True)
        elif args.action == "read":
            sys.stdout.buffer.write(read_file(path, limit))
        elif args.action == "mkdir":
            mkdir_p(path)
        elif args.action == "joymap":
            atomic_install(path, generate_joymap())
    except FileNotFoundError:
        if args.action == "read":
            return 2
        _die("path not found", 2)
    except OSError as exc:
        _die(str(exc), 1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
