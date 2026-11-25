#!/usr/bin/env python3
"""Puts Birch's icon into birch.exe (CEF's prebuilt bootstrap executable,
renamed) on Windows, using Windows' own resource API through ctypes: every
existing icon group and icon is removed, then birch.ico's images are added as
icon group 1. Run after the copy, before anything is signed.

  python -I set_exe_icon.py <birch.exe> <birch.ico>
"""
import ctypes
import struct
import sys
from ctypes import wintypes

RT_ICON, RT_GROUP_ICON = 3, 14
LOAD_LIBRARY_AS_DATAFILE = 0x2

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.BeginUpdateResourceW.restype = wintypes.HANDLE
k32.BeginUpdateResourceW.argtypes = [wintypes.LPCWSTR, wintypes.BOOL]
k32.UpdateResourceW.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                                wintypes.WORD, ctypes.c_void_p, wintypes.DWORD]
k32.EndUpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.BOOL]
k32.LoadLibraryExW.restype = wintypes.HMODULE
k32.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD]
k32.FreeLibrary.argtypes = [wintypes.HMODULE]

ENUM_NAMES = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE, ctypes.c_void_p,
                                ctypes.c_void_p, ctypes.c_void_p)
ENUM_LANGS = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE, ctypes.c_void_p,
                                ctypes.c_void_p, wintypes.WORD, ctypes.c_void_p)
k32.EnumResourceNamesW.argtypes = [wintypes.HMODULE, ctypes.c_void_p, ENUM_NAMES,
                                   ctypes.c_void_p]
k32.EnumResourceLanguagesW.argtypes = [wintypes.HMODULE, ctypes.c_void_p,
                                       ctypes.c_void_p, ENUM_LANGS, ctypes.c_void_p]


def existing(exe):
    """(type, name, language) of every icon and icon group in |exe|."""
    found = []
    mod = k32.LoadLibraryExW(exe, None, LOAD_LIBRARY_AS_DATAFILE)
    if not mod:
        sys.exit(f"set_exe_icon: cannot open {exe} ({ctypes.get_last_error()})")
    for rtype in (RT_GROUP_ICON, RT_ICON):
        names = []

        def on_name(_m, _t, name, _p):
            # Integer ids are pointers below 0x10000; names are strings.
            names.append(name if name < 0x10000 else ctypes.wstring_at(name))
            return True

        k32.EnumResourceNamesW(mod, rtype, ENUM_NAMES(on_name), None)
        for name in names:
            langs = []

            def on_lang(_m, _t, _n, lang, _p):
                langs.append(lang)
                return True

            key = name if isinstance(name, int) else ctypes.c_wchar_p(name)
            k32.EnumResourceLanguagesW(mod, rtype, key, ENUM_LANGS(on_lang), None)
            found += [(rtype, name, lang) for lang in langs]
    k32.FreeLibrary(mod)
    return found


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    exe, ico = sys.argv[1], sys.argv[2]
    data = open(ico, "rb").read()
    _, kind, count = struct.unpack("<HHH", data[:6])
    if kind != 1 or count == 0:
        sys.exit("set_exe_icon: not an .ico file")
    images = []
    for i in range(count):
        w, h, colors, _, planes, bits, size, offset = struct.unpack(
            "<BBBBHHII", data[6 + 16 * i:22 + 16 * i])
        images.append((w, h, colors, planes, bits, data[offset:offset + size]))
    old = existing(exe)
    handle = k32.BeginUpdateResourceW(exe, False)
    if not handle:
        sys.exit(f"set_exe_icon: BeginUpdateResource failed ({ctypes.get_last_error()})")
    for rtype, name, lang in old:
        key = name if isinstance(name, int) else ctypes.c_wchar_p(name)
        k32.UpdateResourceW(handle, rtype, key, lang, None, 0)  # delete
    lang = 0x0409  # en-US
    group = struct.pack("<HHH", 0, 1, len(images))
    for n, (w, h, colors, planes, bits, blob) in enumerate(images, start=1):
        buf = ctypes.create_string_buffer(blob, len(blob))
        if not k32.UpdateResourceW(handle, RT_ICON, n, lang, buf, len(blob)):
            sys.exit(f"set_exe_icon: adding icon {n} failed ({ctypes.get_last_error()})")
        group += struct.pack("<BBBBHHIH", w, h, colors, 0, planes, bits, len(blob), n)
    gbuf = ctypes.create_string_buffer(group, len(group))
    if not k32.UpdateResourceW(handle, RT_GROUP_ICON, 1, lang, gbuf, len(group)):
        sys.exit(f"set_exe_icon: adding the icon group failed ({ctypes.get_last_error()})")
    if not k32.EndUpdateResourceW(handle, False):
        sys.exit(f"set_exe_icon: EndUpdateResource failed ({ctypes.get_last_error()})")
    print(f"set_exe_icon: removed {len(old)} old resources, added {len(images)} icons")


if __name__ == "__main__":
    main()
