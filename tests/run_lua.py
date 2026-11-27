"""Run the Lua 5.1 test cases through a local 64-bit LuaJIT DLL."""
import argparse
import ctypes
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run(dll):
    lib = ctypes.CDLL(str(dll.resolve(strict=True)))
    state_type = ctypes.c_void_p
    lib.luaL_newstate.restype = state_type
    lib.luaL_openlibs.argtypes = (state_type,)
    lib.luaL_loadstring.argtypes = (state_type, ctypes.c_char_p)
    lib.lua_pcall.argtypes = (state_type, ctypes.c_int, ctypes.c_int, ctypes.c_int)
    lib.lua_tolstring.argtypes = (state_type, ctypes.c_int, ctypes.c_void_p)
    lib.lua_tolstring.restype = ctypes.c_char_p
    lib.lua_close.argtypes = (state_type,)
    os.chdir(ROOT)
    for path in sorted((ROOT / "tests").glob("test_*.lua")):
        state = lib.luaL_newstate()
        try:
            lib.luaL_openlibs(state)
            result = lib.luaL_loadstring(state, path.read_bytes())
            if result == 0:
                result = lib.lua_pcall(state, 0, 0, 0)
            if result:
                message = lib.lua_tolstring(state, -1, None)
                raise SystemExit(f"{path.name}: {message.decode(errors='replace')}")
            print(f"{path.name}: passed", flush=True)
        finally:
            lib.lua_close(state)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("luajit", type=Path)
    run(parser.parse_args().luajit)
