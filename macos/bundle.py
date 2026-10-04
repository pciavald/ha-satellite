"""Mach-O helpers for macos/build.sh, run with the bundled interpreter.

  bundle.py libmpv LIBMPV DEST [MODULE...]
                                 copy libmpv and every library it needs (outside
                                 /usr/lib and /System) into DEST, pointing each
                                 reference at @loader_path and dropping rpaths;
                                 each MODULE (PyAV's extension modules, built
                                 against the same FFmpeg) is rewritten in place
                                 to load its libraries from DEST
  bundle.py list KIND DIR...     NUL-separated Mach-O files under DIR, deepest
                                 first; KIND is libraries or executables
  bundle.py check APP            fail when a Mach-O file of APP is not arm64, or
                                 loads a library from outside APP and the system
                                 (rpaths resolved in order, as dyld does), or
                                 holds two copies of an FFmpeg library
"""

import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

SYSTEM = ("/usr/lib/", "/System/Library/")
LOAD_COMMANDS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LAZY_LOAD_DYLIB", "LC_LOAD_UPWARD_DYLIB"}
MH_EXECUTE = 2
THIN_MAGIC = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}
FAT_MAGIC = (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")
# One copy of each in a process: libmpv and PyAV must share them
FFMPEG = ("libavcodec", "libavdevice", "libavfilter", "libavformat", "libavutil", "libpostproc", "libswresample", "libswscale")


def ffmpeg_library(path) -> str | None:
    """The FFmpeg library a file name is a copy of (libavcodec.63.dylib, libavcodec-2.63.dylib...), else None."""
    stem = os.path.basename(str(path)).split(".", 1)[0].split("-", 1)[0]
    return stem if stem in FFMPEG else None


def filetype(path: Path):
    """Mach-O file type (MH_EXECUTE, MH_DYLIB, MH_BUNDLE...), None for other files."""
    if path.is_symlink() or not path.is_file():
        return None
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic in FAT_MAGIC:
            (count,) = struct.unpack(">I", f.read(4))
            if count == 0 or count > 16:  # also the magic of Java class files
                return None
            entry = f.read(20 if magic == FAT_MAGIC[0] else 32)
            offset = struct.unpack(">I", entry[8:12])[0] if magic == FAT_MAGIC[0] else struct.unpack(">Q", entry[8:16])[0]
            f.seek(offset)
            magic = f.read(4)
        if magic not in THIN_MAGIC:
            return None
        f.read(8)
        return struct.unpack(THIN_MAGIC[magic] + "I", f.read(4))[0]


def load_commands(path: Path):
    """(id, [loaded libraries], [rpaths]) of the arm64 slice."""
    out = subprocess.run(["otool", "-arch", "arm64", "-l", str(path)], check=True, capture_output=True, text=True).stdout
    ident, loads, rpaths, cmd = None, [], [], None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            cmd = line.split()[1]
        elif line.startswith(("name ", "path ")):
            value = line.split(" ", 1)[1].rsplit(" (offset", 1)[0]
            if cmd == "LC_ID_DYLIB":
                ident = value
            elif cmd in LOAD_COMMANDS:
                loads.append(value)
            elif cmd == "LC_RPATH":
                rpaths.append(value)
    return ident, loads, rpaths


def resolve(reference: str, origin: Path, rpaths, executable_dir=None):
    """Where `reference`, loaded by `origin`, is found; None when it is not."""
    loader = str(origin.parent)

    def expand(path: str):
        if path.startswith("@loader_path"):
            return loader + path[len("@loader_path") :]
        if path.startswith("@executable_path"):
            return None if executable_dir is None else str(executable_dir) + path[len("@executable_path") :]
        return path

    if reference.startswith("@rpath/"):
        for rpath in rpaths:
            base = expand(rpath)
            if base and os.path.exists(os.path.join(base, reference[len("@rpath/") :])):
                return Path(os.path.realpath(os.path.join(base, reference[len("@rpath/") :])))
        return None
    path = expand(reference)
    return Path(os.path.realpath(path)) if path and os.path.exists(path) else None


def bundle_libmpv(libmpv: Path, dest: Path, modules=()):
    dest.mkdir(parents=True, exist_ok=True)
    names = {Path(os.path.realpath(libmpv)): "libmpv.dylib"}
    queue = list(names) + [Path(module) for module in modules]
    edits = {}
    while queue:
        source = queue.pop()
        _ident, loads, rpaths = load_commands(source)
        prefix = "@loader_path/" if source in names else "@loader_path/" + os.path.relpath(dest, source.parent) + "/"
        changes = []
        for reference in loads:
            if reference.startswith(SYSTEM) or reference.startswith("@loader_path/") and source not in names:
                continue
            found = resolve(reference, source, rpaths)
            if found is None:
                sys.exit(f"{source}: cannot find {reference}")
            if ".framework/" in str(found):
                sys.exit(f"{source}: {reference} is a framework, which is not bundled")
            if found not in names:
                name = os.path.basename(reference)
                taken = set(names.values())
                stem, suffix = name.split(".", 1) if "." in name else (name, "")
                count = 1
                while name in taken:  # two builds of one library (Nix closures)
                    count += 1
                    name = f"{stem}-{count}.{suffix}" if suffix else f"{stem}-{count}"
                names[found] = name
                queue.append(found)
            changes += ["-change", reference, prefix + names[found]]
        edits[source] = (changes, rpaths)
    for source, name in names.items():
        target = dest / name
        shutil.copyfile(source, target)
        os.chmod(target, 0o755)
        relink(target, ["-id", "@rpath/" + name], *edits[source])
    for module in modules:
        relink(Path(module), [], *edits[Path(module)])
    duplicates = sorted(name for name in names.values() if "-" in name.split(".", 1)[0] and ffmpeg_library(name))
    if duplicates:
        sys.exit(f"two builds of FFmpeg in libmpv's and PyAV's closure: {', '.join(duplicates)}")
    print(f"bundled {len(names)} libraries into {dest}, relinked {len(modules)} modules")


def relink(target: Path, args, changes, rpaths):
    args = args + changes
    for rpath in rpaths:
        args += ["-delete_rpath", rpath]
    if args:
        result = subprocess.run(["install_name_tool", *args, str(target)], check=False, capture_output=True, text=True)
        if result.returncode:
            sys.exit(f"install_name_tool failed on {target}: {result.stderr.strip()}")
    _ident, loads, left = load_commands(target)
    bad = [ref for ref in loads if not ref.startswith(SYSTEM + ("@loader_path/",))]
    if bad or left:
        sys.exit(f"{target}: still loads {bad} or searches {left}")


def macho_files(directories):
    files = []
    for directory in directories:
        for root, _dirs, entries in os.walk(directory):
            for entry in entries:
                path = Path(root, entry)
                kind = filetype(path)
                if kind is not None:
                    files.append((path, kind))
    files.sort(key=lambda item: (-len(item[0].parts), str(item[0])))
    return files


def check(app: Path):
    contents = app / "Contents"
    python_bin = contents / "Resources/python/bin"
    app_root = os.path.realpath(app) + os.sep
    problems = []
    files = macho_files([contents])
    for path, _kind in files:
        archs = subprocess.run(["lipo", "-archs", str(path)], check=True, capture_output=True, text=True).stdout.split()
        if "arm64" not in archs:
            problems.append(f"{path}: no arm64 slice ({' '.join(archs)})")
            continue
        _ident, loads, rpaths = load_commands(path)
        executable_dir = contents / "MacOS" if path.parent.name == "MacOS" else python_bin
        for reference in loads:
            if reference.startswith(SYSTEM):
                continue
            found = resolve(reference, path, rpaths, executable_dir)
            if found is None or not str(found).startswith(app_root):
                problems.append(f"{path}: loads {reference} ({found or 'missing'})")
    copies = {}
    for path, _kind in files:
        library = ffmpeg_library(path)
        if library:
            copies.setdefault(library, []).append(path)
    for library, paths in sorted(copies.items()):
        if len(paths) > 1:
            problems.append(f"{len(paths)} copies of {library}: {', '.join(str(path) for path in paths)}")
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        sys.exit(f"{len(problems)} problems in {app}")
    print(f"checked {len(files)} Mach-O files: arm64, nothing loaded from outside the app, one copy of FFmpeg")


def main():
    command, args = sys.argv[1], sys.argv[2:]
    if command == "libmpv":
        bundle_libmpv(Path(args[0]), Path(args[1]), [Path(module) for module in args[2:]])
    elif command == "list":
        wanted = args[0]
        for path, kind in macho_files(args[1:]):
            if (kind == MH_EXECUTE) == (wanted == "executables"):
                sys.stdout.write(f"{path}\0")
    elif command == "check":
        check(Path(args[0]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
