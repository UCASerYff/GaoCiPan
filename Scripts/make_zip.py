#!/usr/bin/env python3
"""Standard UTF-8 ZIP of ordinary bundle files, preserving POSIX modes.

Code signatures are embedded in the executable and _CodeSignature resources.
Host-specific extended attributes / AppleDouble are intentionally not exported.
"""
from pathlib import Path
import os
import stat
import sys
import zipfile
from verify_bundle import inventory

source, output = map(Path, sys.argv[1:])
expected = inventory(source)
if output.exists(): raise RuntimeError('Archive destination exists')
with zipfile.ZipFile(output, 'x', zipfile.ZIP_DEFLATED, compresslevel=9, allowZip64=True) as archive:
    for key in sorted(expected):
        path = source / key
        archive.write(path, source.name + '/' + key)
# zipfile emits the language encoding flag for every non-ASCII filename.
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert all(item.flag_bits & 0x800 for item in archive.infolist())
if inventory(source) != expected: raise RuntimeError('Source bundle changed during packing')
print('UTF-8 ZIP 已生成并通过 CRC 核验')
