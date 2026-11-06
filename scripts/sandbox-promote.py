#!/usr/bin/env python3
import argparse
import json
import os
import re
import stat
import subprocess
import sys

AGENT_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
WINDOWS_DEVICES = {"con", "prn", "aux", "nul", *(f"com{i}" for i in range(1, 10)), *(f"lpt{i}" for i in range(1, 10))}
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
CHUNK = 65536


class Rejected(Exception):
    pass


def open_dir(name, dir_fd):
    try:
        fd = os.open(name, DIR_FLAGS, dir_fd=dir_fd)
    except OSError as error:
        raise Rejected(f"{name}: not a real directory ({error.strerror})") from None
    if not stat.S_ISDIR(os.fstat(fd).st_mode):
        os.close(fd)
        raise Rejected(f"{name}: not a directory")
    return fd


def split_relative(path):
    if not path or path.startswith("/") or "\\" in path or "\0" in path:
        raise Rejected("path must be a non-empty relative POSIX path")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise Rejected("path must not contain empty, '.' or '..' components")
    return parts


def walk(root_fd, parts, create):
    fds = []
    fd = root_fd
    try:
        for part in parts:
            if create:
                try:
                    os.mkdir(part, 0o755, dir_fd=fd)
                except FileExistsError:
                    pass
            fd = open_dir(part, fd)
            fds.append(fd)
        return fd, fds
    except BaseException:
        for opened in fds:
            os.close(opened)
        raise


def identity(st):
    return (
        st.st_dev,
        st.st_ino,
        stat.S_IFMT(st.st_mode),
        st.st_nlink,
        st.st_size,
        st.st_mtime_ns,
        st.st_ctime_ns,
    )


def promote(scratch_fd, artifacts_fd, rel, max_bytes, remaining):
    parts = split_relative(rel)
    parent, opened = walk(scratch_fd, parts[:-1], create=False)
    try:
        try:
            src = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        except OSError as error:
            raise Rejected(f"cannot open leaf no-follow ({error.strerror})") from None
    finally:
        for fd in opened:
            os.close(fd)
    try:
        before = os.fstat(src)
        if not stat.S_ISREG(before.st_mode):
            raise Rejected("not a regular file")
        if before.st_nlink != 1:
            raise Rejected(f"link count is {before.st_nlink}, expected 1")
        limit = min(max_bytes, remaining)
        if before.st_size > limit:
            raise Rejected(f"size {before.st_size} exceeds limit {limit}")
        chunks = []
        read = 0
        while read < before.st_size:
            chunk = os.read(src, min(CHUNK, before.st_size - read))
            if not chunk:
                break
            chunks.append(chunk)
            read += len(chunk)
        if read != before.st_size or os.read(src, 1):
            raise Rejected("file size changed while reading")
        if identity(os.fstat(src)) != identity(before):
            raise Rejected("file identity, type, link count, size or timestamps changed")
        data = b"".join(chunks)
    finally:
        os.close(src)

    dest_parent, opened = walk(artifacts_fd, parts[:-1], create=True)
    try:
        try:
            dst = os.open(
                parts[-1],
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o644,
                dir_fd=dest_parent,
            )
        except OSError as error:
            raise Rejected(f"cannot create destination exclusively ({error.strerror})") from None
    finally:
        for fd in opened:
            os.close(fd)
    try:
        st = os.fstat(dst)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            raise Rejected("destination is not a single-link regular file")
        view = memoryview(data)
        while view:
            written = os.write(dst, view)
            view = view[written:]
        os.fsync(dst)
    finally:
        os.close(dst)
    return len(data)


def sandbox_running(scratch_path):
    try:
        result = subprocess.run(
            ["docker", "ps", "--all", "--quiet", "--filter", f"label=security-audit.scratch={scratch_path}"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return bool(result.stdout.strip())


def reject_all(reason):
    print(json.dumps({"promoted": [], "rejected": [{"path": "*", "reason": reason}]}))
    return 1


def main():
    parser = argparse.ArgumentParser(
        prog="sandbox-promote",
        description="Copies allowlisted files from agents/<id>/scratch to agents/<id>/artifacts "
        "with no-follow, regular-file, single-link and size checks.",
    )
    parser.add_argument("--agent", required=True, help="agent ID under the agents root")
    parser.add_argument("--max-total", type=int, required=True, help="cumulative byte limit for this call")
    parser.add_argument("files", nargs="+", metavar="PATH:MAX_BYTES", help="scratch-relative file and its byte limit")
    args = parser.parse_args()

    agents_root = os.environ.get("SANDBOX_AGENTS_ROOT")
    if not agents_root:
        parser.error("SANDBOX_AGENTS_ROOT is not set")
    if not AGENT_ID.match(args.agent) or args.agent in WINDOWS_DEVICES:
        parser.error("agent ID must match ^[a-z0-9][a-z0-9_-]{0,63}$ and not be a Windows device name")
    if args.max_total < 0:
        parser.error("--max-total must be non-negative")

    specs = []
    for spec in args.files:
        path, sep, limit = spec.rpartition(":")
        if not sep or not limit.isdigit():
            parser.error(f"{spec}: expected PATH:MAX_BYTES")
        specs.append((path, int(limit)))

    scratch_path = os.path.join(os.path.realpath(agents_root), args.agent, "scratch")
    running = sandbox_running(scratch_path)
    if running is None and os.environ.get("SANDBOX_REQUIRE_DOCKER", "1") == "1":
        return reject_all("cannot confirm the sandbox has exited")
    if running:
        return reject_all("a sandbox for this scratch is still running")

    fds = []
    try:
        try:
            try:
                fds.append(os.open(agents_root, DIR_FLAGS))
            except OSError as error:
                raise Rejected(f"{agents_root}: not a real directory ({error.strerror})") from None
            agent_fd = open_dir(args.agent, fds[-1])
            fds.append(agent_fd)
            scratch_fd = open_dir("scratch", agent_fd)
            fds.append(scratch_fd)
            try:
                os.mkdir("artifacts", 0o755, dir_fd=agent_fd)
            except FileExistsError:
                pass
            except OSError as error:
                raise Rejected(f"artifacts: cannot create ({error.strerror})") from None
            artifacts_fd = open_dir("artifacts", agent_fd)
            fds.append(artifacts_fd)
        except Rejected as error:
            return reject_all(str(error))

        promoted, rejected = [], []
        remaining = args.max_total
        for path, limit in specs:
            try:
                remaining -= promote(scratch_fd, artifacts_fd, path, limit, remaining)
                promoted.append(f"agents/{args.agent}/artifacts/{path}")
            except Rejected as error:
                rejected.append({"path": path, "reason": str(error)})
    finally:
        for fd in fds:
            os.close(fd)

    print(json.dumps({"promoted": promoted, "rejected": rejected}))
    return 1 if rejected else 0


if __name__ == "__main__":
    sys.exit(main())
