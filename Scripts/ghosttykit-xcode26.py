"""What Ghostty v1.3.1's build needs to get past Xcode 26
(Scripts/build-ghosttykit.sh puts these in front of the real tools).

  sdk <real sdk> <shim>  A macOS SDK whose usr/lib stubs list arm64-macos
                         wherever they list arm64e-macos; symlinks to the
                         real SDK for everything else. Zig 0.15.2's Mach-O
                         linker matches a .tbd's targets exactly, and the
                         26.4+ SDKs list only arm64e for libsystem_c,
                         libsystem_malloc…: not even `zig build`'s own
                         runner links (ziglang/zig#31665).

  libtool <args>         libtool, with each archive it is handed repacked
                         first so every member starts 8-byte aligned. Zig's
                         archives don't pad their members, and Xcode 26's
                         libtool drops a misaligned 64-bit member with only
                         a warning — libghostty-fat.a came out without
                         libghostty itself, imgui, wuffs.
"""

import os
import re
import subprocess
import sys
import tempfile

# MARK: sdk

TARGETS = re.compile(r"(targets:\s*\[)([^\]]*)(\])", re.S)


def patch_tbd(text):
    def one(m):
        items = m.group(2)
        if "arm64e-macos" in items and not re.search(r"\barm64-macos\b", items):
            items = items.replace("arm64e-macos", "arm64-macos, arm64e-macos", 1)
        return m.group(1) + items + m.group(3)

    return TARGETS.sub(one, text)


def mirror(src, dst, descend):
    """dst a real directory of symlinks into src, except the .tbd files
    (patched copies) and the directories `descend` names (mirrored)."""
    os.makedirs(dst, exist_ok=True)
    for name in sorted(os.listdir(src)):
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if name in descend and os.path.isdir(s) and not os.path.islink(s):
            mirror(s, d, descend[name])
        elif name.endswith(".tbd") and os.path.isfile(s):
            with open(s, encoding="utf-8") as f:
                text = f.read()
            with open(d, "w", encoding="utf-8") as f:
                f.write(patch_tbd(text))
        else:
            os.symlink(s, d)


def sdk(real, shim):
    # libSystem and what it re-exports are all the build links natively.
    mirror(os.path.realpath(real), shim, {"usr": {"lib": {"system": {}}}})


# MARK: libtool

MAGIC = b"!<arch>\n"


def members(path):
    """(name, data) of each member of a BSD archive, its symbol table aside."""
    with open(path, "rb") as f:
        blob = f.read()
    if not blob.startswith(MAGIC):
        raise SystemExit(f"ghosttykit-xcode26: {path} is not an archive")
    at = len(MAGIC)
    while at + 60 <= len(blob):
        header = blob[at : at + 60]
        if header[58:60] != b"`\n":
            raise SystemExit(f"ghosttykit-xcode26: {path}: bad member header at {at}")
        name = header[0:16].decode("ascii").rstrip()
        size = int(header[48:58].decode("ascii").strip())
        data = blob[at + 60 : at + 60 + size]
        if name.startswith("#1/"):
            length = int(name[3:])
            name, data = data[:length].rstrip(b"\0").decode("utf-8"), data[length:]
        elif name.endswith("/") and name not in ("/", "//"):
            name = name[:-1]
        elif name in ("/", "//"):
            raise SystemExit(f"ghosttykit-xcode26: {path} is a GNU archive")
        if not name.startswith("__.SYMDEF"):
            yield name, data
        at += 60 + size + (size & 1)


def repack(src, dst):
    """src's members written again, each one's data 8-byte aligned (the
    name padded with NULs, as cctools does); libtool writes the index."""
    out = bytearray(MAGIC)
    for name, data in members(src):
        encoded = name.encode("utf-8")
        length = len(encoded)
        while (len(out) + 60 + length) % 8:
            length += 1
        body = encoded + b"\0" * (length - len(encoded)) + data
        while (len(out) + 60 + len(body)) % 8:
            body += b"\0"
        header = f"#1/{length:<13}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(body):<10}`\n"
        assert len(header) == 60
        out += header.encode("ascii") + body
    with open(dst, "wb") as f:
        f.write(out)


def libtool(args):
    with tempfile.TemporaryDirectory(prefix="ghosttykit-libtool-") as tmp:
        argv = ["/usr/bin/libtool"]
        for i, arg in enumerate(args):
            is_output = i > 0 and args[i - 1] == "-o"
            if not is_output and arg.endswith(".a") and os.path.isfile(arg):
                copy = os.path.join(tmp, f"{i}-{os.path.basename(arg)}")
                repack(arg, copy)
                arg = copy
            argv.append(arg)
        sys.exit(subprocess.call(argv))


if __name__ == "__main__":
    command, rest = sys.argv[1], sys.argv[2:]
    if command == "sdk":
        sdk(*rest)
    elif command == "libtool":
        libtool(rest)
    else:
        raise SystemExit(f"ghosttykit-xcode26: unknown command {command}")
