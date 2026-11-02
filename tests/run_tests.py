#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 FPsamuraiG
"""Run the wpmstats scenario tests against a mocked KOReader.

Needs either `luajit` / `lua5.1` on PATH, or the `lupa` Python package
(pip install lupa). Run from anywhere: python3 tests/run_tests.py
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PLUGIN = os.path.join(ROOT, "wpmstats.koplugin", "main.lua")
META = os.path.join(ROOT, "wpmstats.koplugin", "_meta.lua")
HARNESS = os.path.join(HERE, "harness.lua")


def report(output: str) -> int:
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
    return report(result.stdout)


def run_with_lupa() -> int:
    import lupa  # noqa: WPS433

    lua = lupa.LuaRuntime()
    for path in (META, PLUGIN):
        with open(path, encoding="utf-8") as f:
            lua.compile(f.read())
    lua.globals().arg_plugin_path = PLUGIN
    with open(HARNESS, encoding="utf-8") as f:
        return report(lua.execute(f.read()))


def main() -> int:
    for exe in ("luajit", "lua5.1", "lua"):
        if shutil.which(exe):
            return run_with_lua(exe)
    try:
        return run_with_lupa()
    except ImportError:
        print("Install luajit/lua5.1, or: pip install lupa", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
