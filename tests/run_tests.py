#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 FPsamuraiG
"""Run the wpmstats scenario tests against a mocked KOReader.

KOReader runs on LuaJIT (Lua 5.1 semantics), so the tests only run on
LuaJIT or Lua 5.1, never a newer Lua that would accept 5.3+ syntax the
device can't. Needs one of: `luajit` on PATH, the `lupa` Python package
(pip install lupa, which bundles LuaJIT), or `lua5.1` on PATH.
Run from anywhere: python tests/run_tests.py
"""
import importlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PLUGIN = os.path.join(ROOT, "wpmstats.koplugin", "main.lua")
META = os.path.join(ROOT, "wpmstats.koplugin", "_meta.lua")
HARNESS = os.path.join(HERE, "harness.lua")

# lupa runtimes matching the device, best first.
LUPA_MODULES = ("lupa.luajit21", "lupa.luajit20", "lupa.lua51")


def report(runtime: str, output: str) -> int:
    print(f"Running on {runtime}")
    print(output)
    return 1 if "FAIL" in output else 0


def run_with_lua(exe: str) -> int:
    code = (
        f"arg_plugin_path = {PLUGIN!r}\n"
        f"assert(loadfile({META!r}))\n"
        f"print(dofile({HARNESS!r}))\n"
    )
    result = subprocess.run([exe, "-e", code], capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        return 1
    return report(exe, result.stdout)


def find_lupa_runtime():
    for name in LUPA_MODULES:
        try:
            return importlib.import_module(name).LuaRuntime
        except ImportError:
            continue
    return None


def run_with_lupa(runtime_class) -> int:
    lua = runtime_class()
    for path in (META, PLUGIN):
        with open(path, encoding="utf-8") as f:
            lua.compile(f.read())
    lua.globals().arg_plugin_path = PLUGIN
    with open(HARNESS, encoding="utf-8") as f:
        return report(lua.lua_implementation, lua.execute(f.read()))


def main() -> int:
    if shutil.which("luajit"):
        return run_with_lua("luajit")
    runtime_class = find_lupa_runtime()
    if runtime_class:
        return run_with_lupa(runtime_class)
    if shutil.which("lua5.1"):
        return run_with_lua("lua5.1")
    print("Needs LuaJIT or Lua 5.1 (KOReader's runtime). "
          "Install luajit, or: pip install lupa", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
