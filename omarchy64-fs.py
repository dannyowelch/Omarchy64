#!/usr/bin/python3
"""Descriptor-retained reads and installs for omarchy64 state files.

Every parent is opened with openat(O_DIRECTORY|O_NOFOLLOW) from /, the
directory fd is kept, and the leaf is created/replaced with
O_CREAT|O_EXCL|O_NOFOLLOW plus renameat on that same fd.

Plugin tree installs walk the same way, keep the destination directory
fd through copy/delete, refuse symlink and directory swaps, and exec the
installed controller via that fd.
"""
from __future__ import annotations

import argparse
import errno
import fcntl
import glob
import json
import os
import stat
import subprocess
import sys

PLUGIN_OWNED = {"omarchy", "toggles", "hypr"}
DEFAULT_LIMIT = 65536
JOYMAP_ABS_HAT0X = 16
PLUGIN_FILE_LIMIT = 2 * 1024 * 1024
PLUGIN_MAX_FILES = 64
PLUGIN_MAX_DEPTH = 8
TREE_SKIP = frozenset({".git", "__pycache__", "install-local.sh"})
TREE_EXEC = frozenset({"omarchy64-ctl", "omarchy64-fs.py", "omarchy64-run.py"})


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


def _open_dir_component(dirfd: int, name: str) -> int:
    try:
        return os.open(name, _dir_flags(), dir_fd=dirfd)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR) and _is_symlink(dirfd, name):
            raise OSError(errno.ELOOP, "refusing symlink", name) from exc
        raise


def _file_flags(write: bool = False) -> int:
    flags = (os.O_WRONLY if write else os.O_RDONLY) | os.O_NOFOLLOW | os.O_CLOEXEC
    flags |= getattr(os, "O_NONBLOCK", 0)
    return flags


def _verify_walk_dir(fd: int, name: str, *, created: bool, owned: bool) -> None:
    st = os.fstat(fd)
    uid = os.getuid()
    if not stat.S_ISDIR(st.st_mode):
        raise OSError(errno.ENOTDIR, "not a directory", name)
    if created and st.st_uid != uid:
        raise OSError(errno.EPERM, "unowned directory", name)
    if owned:
        if st.st_uid != uid:
            raise OSError(errno.EPERM, "unowned directory", name)
        os.fchmod(fd, 0o700)
        return
    if st.st_uid not in (0, uid):
        raise OSError(errno.EPERM, "unowned ancestor", name)
    if st.st_uid == uid:
        if st.st_mode & 0o022:
            raise OSError(errno.EPERM, "writable ancestor", name)
    elif st.st_mode & 0o002 and not (st.st_mode & stat.S_ISVTX):
        raise OSError(errno.EPERM, "world-writable ancestor", name)


def open_parent(path: str, create: bool = True) -> tuple[int, str]:
    """Return (dirfd, leaf name) for path, walking from / without following symlinks."""
    parts, name = _abs_parts(path)
    dirfd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    owned = False
    try:
        for comp in parts:
            if comp in PLUGIN_OWNED:
                owned = True
            nxt = None
            created = False
            try:
                nxt = _open_dir_component(dirfd, comp)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(comp, 0o700, dir_fd=dirfd)
                created = True
                nxt = _open_dir_component(dirfd, comp)
            try:
                _verify_walk_dir(nxt, comp, created=created, owned=owned)
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


def _valid_entry_name(name: str) -> bool:
    if not name or name in (".", "..") or "/" in name or "\0" in name:
        return False
    return all(ch.isalnum() or ch in "._-" for ch in name)


def _same_inode(left: os.stat_result, right: os.stat_result) -> bool:
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def _assert_same_dir(parent_fd: int, name: str, dirfd: int) -> None:
    st = os.fstat(dirfd)
    if not stat.S_ISDIR(st.st_mode):
        raise OSError(errno.ENOTDIR, "not a directory", name)
    try:
        seen = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError as exc:
        raise OSError(errno.ENOENT, "directory disappeared", name) from exc
    if stat.S_ISLNK(seen.st_mode):
        raise OSError(errno.ELOOP, "directory replaced with symlink", name)
    if not _same_inode(st, seen):
        raise OSError(errno.EPERM, "directory identity mismatch", name)


def _blocking(fd: int) -> None:
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl & ~os.O_NONBLOCK)


def _read_all(fd: int, limit: int) -> bytes:
    _blocking(fd)
    data = b""
    while len(data) <= limit:
        chunk = os.read(fd, min(8192, limit + 1 - len(data)))
        if not chunk:
            break
        data += chunk
    if len(data) > limit:
        raise OSError(errno.EFBIG, f"file exceeds {limit} bytes")
    return data


def _open_leaf_dir(parent_fd: int, name: str, create: bool) -> int:
    if not _valid_entry_name(name):
        raise OSError(errno.EINVAL, "invalid destination name", name)
    if _is_symlink(parent_fd, name):
        raise OSError(errno.ELOOP, "refusing symlink", name)
    created = False
    try:
        fd = _open_dir_component(parent_fd, name)
    except FileNotFoundError:
        if not create:
            raise
        os.mkdir(name, 0o700, dir_fd=parent_fd)
        created = True
        fd = _open_dir_component(parent_fd, name)
    try:
        _verify_walk_dir(fd, name, created=created, owned=True)
        _assert_same_dir(parent_fd, name, fd)
        return fd
    except Exception:
        os.close(fd)
        raise


def _remove_nofollow(dirfd: int, name: str, parent_dev: int | None = None, depth: int = 0) -> None:
    if not name or name in (".", "..") or "/" in name or "\0" in name:
        raise OSError(errno.EINVAL, "invalid name", name)
    if depth > PLUGIN_MAX_DEPTH:
        raise OSError(errno.ELOOP, "plugin tree too deep")
    if parent_dev is None:
        parent_dev = os.fstat(dirfd).st_dev
    st = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    if st.st_dev != parent_dev:
        raise OSError(errno.EXDEV, "refusing to cross mount", name)
    if stat.S_ISLNK(st.st_mode) or stat.S_ISREG(st.st_mode):
        os.unlink(name, dir_fd=dirfd)
        return
    if not stat.S_ISDIR(st.st_mode):
        raise OSError(errno.EINVAL, "refusing special file", name)
    sub = _open_dir_component(dirfd, name)
    try:
        if os.fstat(sub).st_dev != parent_dev:
            raise OSError(errno.EXDEV, "refusing to cross mount", name)
        for child in os.listdir(sub):
            _remove_nofollow(sub, child, parent_dev, depth + 1)
    finally:
        os.close(sub)
    os.rmdir(name, dir_fd=dirfd)


def _install_file_at(src_dirfd: int, src_name: str, dst_dirfd: int, dst_name: str, mode: int) -> None:
    if _is_symlink(src_dirfd, src_name):
        raise OSError(errno.ELOOP, f"refusing source symlink: {src_name}")
    sfd = os.open(src_name, _file_flags(False), dir_fd=src_dirfd)
    try:
        st = os.fstat(sfd)
        if not stat.S_ISREG(st.st_mode):
            raise OSError(errno.EINVAL, "not a regular file", src_name)
        if st.st_size > PLUGIN_FILE_LIMIT:
            raise OSError(errno.EFBIG, f"file exceeds {PLUGIN_FILE_LIMIT} bytes", src_name)
        data = _read_all(sfd, PLUGIN_FILE_LIMIT)
    finally:
        os.close(sfd)
    try:
        existing = os.stat(dst_name, dir_fd=dst_dirfd, follow_symlinks=False)
    except FileNotFoundError:
        existing = None
    if existing is not None:
        if stat.S_ISLNK(existing.st_mode):
            os.unlink(dst_name, dir_fd=dst_dirfd)
        elif stat.S_ISDIR(existing.st_mode):
            raise OSError(errno.EISDIR, "refusing to replace directory", dst_name)
        elif not stat.S_ISREG(existing.st_mode):
            raise OSError(errno.EINVAL, "refusing special file", dst_name)
    tmp = f".{dst_name}.{os.getpid()}.{os.urandom(8).hex()}.tmp"
    fd = -1
    try:
        fd = os.open(tmp, _file_flags(True) | os.O_CREAT | os.O_EXCL, mode, dir_fd=dst_dirfd)
        os.fchmod(fd, mode)
        _blocking(fd)
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            if n <= 0:
                raise OSError("short write")
            view = view[n:]
        os.fsync(fd)
        os.rename(tmp, dst_name, src_dir_fd=dst_dirfd, dst_dir_fd=dst_dirfd)
        os.fsync(dst_dirfd)
        tmp = None
    finally:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp is not None:
            try:
                os.unlink(tmp, dir_fd=dst_dirfd)
            except OSError:
                pass


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


def _config_home() -> str:
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        if not os.path.isabs(xdg):
            _die("XDG_CONFIG_HOME must be absolute")
        return xdg
    home = os.environ.get("HOME") or ""
    if not os.path.isabs(home):
        _die("HOME must be absolute")
    return os.path.join(home, ".config")


def _plugin_dest(plugin_id: str) -> str:
    dest = os.path.join(_config_home(), "omarchy", "plugins", plugin_id)
    parts, name = _abs_parts(dest)
    if name != plugin_id or len(parts) < 2 or parts[-2:] != ["omarchy", "plugins"]:
        _die("refusing destination outside omarchy/plugins")
    return dest


def _plugin_id_from(src_dir: int) -> str:
    if _is_symlink(src_dir, "manifest.json"):
        raise OSError(errno.ELOOP, "refusing symlink: manifest.json")
    fd = os.open("manifest.json", _file_flags(False), dir_fd=src_dir)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise OSError(errno.EINVAL, "manifest.json is not a regular file")
        raw = _read_all(fd, DEFAULT_LIMIT)
    finally:
        os.close(fd)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        _die("invalid manifest.json")
    plugin_id = data.get("id") if isinstance(data, dict) else None
    if not isinstance(plugin_id, str) or not _valid_entry_name(plugin_id):
        _die("invalid plugin id")
    return plugin_id


def _sync_dir(src_fd: int, dst_fd: int, *, depth: int, files: list[int]) -> None:
    if depth > PLUGIN_MAX_DEPTH:
        raise OSError(errno.ELOOP, "plugin tree too deep")
    keep: set[str] = set()
    for name in sorted(os.listdir(src_fd)):
        if name in TREE_SKIP:
            continue
        if not _valid_entry_name(name):
            raise OSError(errno.EINVAL, "invalid source name", name)
        st = os.stat(name, dir_fd=src_fd, follow_symlinks=False)
        if stat.S_ISLNK(st.st_mode):
            raise OSError(errno.ELOOP, f"refusing source symlink: {name}")
        if stat.S_ISREG(st.st_mode):
            files[0] += 1
            if files[0] > PLUGIN_MAX_FILES:
                raise OSError(errno.EFBIG, "too many plugin files")
            mode = 0o700 if name in TREE_EXEC else 0o600
            _install_file_at(src_fd, name, dst_fd, name, mode)
            keep.add(name)
        elif stat.S_ISDIR(st.st_mode):
            ssub = _open_dir_component(src_fd, name)
            try:
                dsub = _open_leaf_dir(dst_fd, name, create=True)
                try:
                    _sync_dir(ssub, dsub, depth=depth + 1, files=files)
                finally:
                    os.close(dsub)
            finally:
                os.close(ssub)
            keep.add(name)
        else:
            raise OSError(errno.EINVAL, "refusing special file", name)
    for name in os.listdir(dst_fd):
        if name not in keep:
            _remove_nofollow(dst_fd, name)


def _run_installed_ctl(dest_fd: int) -> None:
    fd = os.open("omarchy64-ctl", _file_flags(False), dir_fd=dest_fd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise OSError(errno.EINVAL, "omarchy64-ctl is not a regular file")
        if st.st_uid != os.getuid():
            raise OSError(errno.EPERM, "unowned omarchy64-ctl")
        if st.st_nlink != 1:
            raise OSError(errno.EPERM, "refusing hard-linked omarchy64-ctl")
        if st.st_mode & 0o077:
            raise OSError(errno.EPERM, "omarchy64-ctl mode is too open")
    finally:
        os.close(fd)
    env = os.environ.copy()
    env["PATH"] = "/usr/bin:/bin"
    for key in (
        "PYTHONPATH",
        "PYTHONHOME",
        "PYTHONUSERBASE",
        "BASH_ENV",
        "ENV",
        "LD_PRELOAD",
        "PERL5LIB",
        "PERL5OPT",
    ):
        env.pop(key, None)
    script = f"/proc/self/fd/{dest_fd}/omarchy64-ctl"
    try:
        proc = subprocess.run(
            ["/usr/bin/bash", script, "ensure-rules"],
            stdout=subprocess.DEVNULL,
            pass_fds=(dest_fd,),
            env=env,
            timeout=8,
        )
    except subprocess.TimeoutExpired:
        _die("installed controller timed out")
    if proc.returncode != 0:
        _die(f"installed controller failed ({proc.returncode})")


def install_plugin(src_path: str) -> str:
    src_parent = src_dir = parent_fd = dest_fd = -1
    try:
        src_parent, src_name = open_parent(src_path, create=False)
        src_dir = _open_dir_component(src_parent, src_name)
        _verify_walk_dir(src_dir, src_name, created=False, owned=False)
        plugin_id = _plugin_id_from(src_dir)
        dest = _plugin_dest(plugin_id)
        parent_fd, dest_name = open_parent(dest, create=True)
        if dest_name != plugin_id:
            _die("destination name mismatch")
        dest_fd = _open_leaf_dir(parent_fd, dest_name, create=True)
        ident = os.fstat(dest_fd)
        _sync_dir(src_dir, dest_fd, depth=0, files=[0])
        if not _same_inode(ident, os.fstat(dest_fd)):
            raise OSError(errno.EPERM, "directory identity mismatch", dest)
        _assert_same_dir(parent_fd, dest_name, dest_fd)
        _run_installed_ctl(dest_fd)
        _assert_same_dir(parent_fd, dest_name, dest_fd)
        return dest
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            _die(f"refusing symlink in plugin install path: {exc}")
        raise
    finally:
        for fd in (dest_fd, parent_fd, src_dir, src_parent):
            if fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass


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
    parser.add_argument(
        "action",
        choices=("install", "install-if-absent", "read", "mkdir", "joymap", "install-plugin"),
    )
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    parser.add_argument("path", nargs="?", default="")
    args = parser.parse_args(argv)
    limit = args.limit
    if limit < 1 or limit > 1024 * 1024:
        _die("invalid --limit")
    path = args.path
    try:
        if args.action == "install-plugin":
            if not path:
                _die("missing source path")
            sys.stdout.write(install_plugin(path) + "\n")
            return 0
        if not path:
            _die("missing path")
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
