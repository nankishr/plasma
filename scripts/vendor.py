import argparse
import filecmp
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TARGETS = {
    "linux_x86_64": ("x86_64-linux-gnu", "Linux", "x86_64"),
    "linux_aarch64": ("aarch64-linux-gnu", "Linux", "aarch64"),
    "linux_arm": ("arm-linux-gnueabihf", "Linux", "armv7-a"),
    "linux_x86": ("x86-linux-gnu", "Linux", "i686"),
    "linux_powerpc64le": ("powerpc64le-linux-gnu", "Linux", "ppc64le"),
    "macos_x86_64": ("x86_64-macos", "Darwin", "x86_64"),
    "macos_aarch64": ("aarch64-macos", "Darwin", "arm64"),
}

KEYS = ("crypto_c", "crypto_asm", "jitter_c", "ssl_cc")

APPLE_TOOLS = ("install_name_tool", "otool", "lipo", "libtool")

COPY_RE = re.compile(r"Copying platform assembly files from (\S+) to (\S+)")

ASM_EXTS = (".S", ".s")
C_EXTS = (".c", ".cc", ".cpp")


def say(msg):
    print(msg, flush=True)


def warn(msg):
    print(msg, file=sys.stderr, flush=True)


def short(path):
    path = Path(path)
    try:
        path = path.relative_to(Path.cwd())
    except ValueError:
        pass
    return str(Path(*[p if len(p) <= 16 else p[:8] + "~" for p in path.parts]))


def describe(err):
    if not isinstance(err, subprocess.CalledProcessError):
        return str(err)
    text = (err.stderr or "") + (err.stdout or "")
    lines = [l for l in text.splitlines() if l.strip()]
    start = next((i for i, l in enumerate(lines) if "Error" in l), 0)
    shown = lines[start:start + 8]
    return "cmake failed\n" + "\n".join(f"        {l}" for l in shown)


def zig_wrapper(dir, zig, triple, mode):
    path = dir / f"zig-{mode.replace('+', 'x')}"
    path.write_text(f'#!/bin/sh\nexec "{zig}" {mode} -target {triple} "$@"\n')
    path.chmod(0o755)
    return path


def stub_tools(dir):
    bin = dir / "stubs"
    bin.mkdir()
    for name in APPLE_TOOLS:
        path = bin / name
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
    return bin


def cmake_configure(src, out, system, cpu, cc, cxx):
    cmd = [
        "cmake", "-S", str(src), "-B", str(out), "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        f"-DCMAKE_SYSTEM_NAME={system}",
        f"-DCMAKE_SYSTEM_PROCESSOR={cpu}",
        f"-DCMAKE_C_COMPILER={cc}",
        f"-DCMAKE_CXX_COMPILER={cxx}",
        f"-DCMAKE_ASM_COMPILER={cc}",
        "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
        "-DBUILD_TESTING=OFF",
        "-DBUILD_TOOL=OFF",
        "-DBUILD_LIBSSL=ON",
        "-DDISABLE_GO=ON",
        "-DDISABLE_PERL=ON",
    ]
    env = os.environ.copy()
    if system == "Darwin":
        stubs = stub_tools(out.parent)
        env["PATH"] = f"{stubs}{os.pathsep}{env['PATH']}"
        cmd.append(f"-DCMAKE_INSTALL_NAME_TOOL={stubs / 'install_name_tool'}")
    done = subprocess.run(cmd, check=True, capture_output=True, text=True, env=env)
    text = done.stdout + done.stderr
    return [Path(a).resolve() for a, _ in COPY_RE.findall(text)]


class Resolver:
    def __init__(self, src):
        self.src = src
        self.by_name = {}
        for f in (src / "generated-src").rglob("*"):
            if f.is_file():
                self.by_name.setdefault(f.name, []).append(f)

    def resolve(self, path, origins):
        if path.is_relative_to(self.src):
            return path.relative_to(self.src)
        same = [c for c in self.by_name.get(path.name, []) if filecmp.cmp(c, path, shallow=False)]
        if len(same) > 1:
            preferred = [c for c in same if any(c.is_relative_to(o) for o in origins)]
            same = preferred or same
        if len(same) != 1:
            raise ValueError(f"{len(same)} identical matches in generated-src for build file {path}")
        return same[0].relative_to(self.src)


def kind_of(rel):
    if "test" in rel.parts or rel.stem.endswith("_test"):
        return None
    top = rel.parts[0]
    ext = rel.suffix
    if top == "ssl" and ext in C_EXTS:
        return "ssl_cc"
    if top in ("crypto", "generated-src", "third_party"):
        if ext in ASM_EXTS:
            return "crypto_asm"
        if ext == ".c":
            return "jitter_c" if "jitterentropy" in rel.parts else "crypto_c"
    raise ValueError(f"cannot classify {rel}")


def collect(out, src, origins, resolver):
    entries = json.loads((out / "compile_commands.json").read_text())
    for origin in origins:
        say(f"      asm from {origin.relative_to(src)}")
    raw_asm = sum(1 for e in entries if e["file"].endswith(ASM_EXTS))
    say(f"      {len(entries)} compile commands, {raw_asm} asm")
    found = {k: set() for k in KEYS}
    skipped = []
    for e in entries:
        path = (Path(e["directory"]) / e["file"]).resolve()
        rel = resolver.resolve(path, origins)
        kind = kind_of(rel)
        if kind is None:
            skipped.append(rel.as_posix())
        else:
            found[kind].add(rel.as_posix())
    for rel in sorted(skipped):
        say(f"      skipped test file: {rel}")
    if not found["crypto_c"]:
        raise ValueError("no crypto sources found")
    return {k: sorted(v) for k, v in found.items()}


def zon_field(name, items):
    if not items:
        return f"    .{name} = .{{}},\n"
    lines = "".join(f"        {json.dumps(i)},\n" for i in items)
    return f"    .{name} = .{{\n{lines}    }},\n"


def write_zon(path, data):
    body = "".join(zon_field(k, data[k]) for k in KEYS)
    path.write_text(f".{{\n{body}}}\n")


def vendor_awslc(args):
    for tool in ("cmake", "ninja"):
        if not shutil.which(tool):
            warn(f"{tool} not found in PATH")
            return 1

    src = Path(args.src).resolve()
    gen = Path(args.out) / "generated"
    gen.mkdir(parents=True, exist_ok=True)

    say(f"vendoring aws-lc ({short(src)})")
    say(f"writing to {short(gen)}")

    resolver = Resolver(src)
    failed = []
    t0 = time.monotonic()

    with tempfile.TemporaryDirectory() as tmp:
        for i, (key, (triple, system, cpu)) in enumerate(TARGETS.items(), 1):
            say(f"[{i}/{len(TARGETS)}] {key}")
            dest = gen / f"{key}.zon"
            t = time.monotonic()
            try:
                work = Path(tmp) / key
                work.mkdir()
                cc = zig_wrapper(work, args.zig, triple, "cc")
                cxx = zig_wrapper(work, args.zig, triple, "c++")
                say("      configuring")
                origins = cmake_configure(src, work / "out", system, cpu, cc, cxx)
                data = collect(work / "out", src, origins, resolver)
                write_zon(dest, data)
                counts = ", ".join(f"{len(data[k])} {k}" for k in KEYS)
                say(f"      ok: {counts} ({time.monotonic() - t:.1f}s)")
            except (subprocess.CalledProcessError, ValueError, OSError, KeyError) as e:
                warn(f"      failed: {describe(e)} ({time.monotonic() - t:.1f}s)")
                dest.unlink(missing_ok=True)
                failed.append(key)

    say(f"done: {len(TARGETS) - len(failed)}/{len(TARGETS)} ok in {time.monotonic() - t0:.1f}s")
    if failed:
        warn("failed: " + ", ".join(failed))
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="dep", required=True)
    awslc = sub.add_parser("awslc")
    awslc.add_argument("--zig", default="zig")
    awslc.add_argument("--src", required=True)
    awslc.add_argument("--out", required=True)
    awslc.set_defaults(fn=vendor_awslc)
    args = parser.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()