#!/usr/bin/env python3
"""Gate for the built library. The build fails unless all of this holds:

1. There is an arm64e slice tagged with the VERSIONED ptrauth ABI (cpusubtype 0x80000002).
   dyld silently refuses the old "preview" arm64e ABI in platform processes such as SpringBoard:
   no crash, no log line, the tweak just never loads.
2. There is a plain arm64 slice as well: App Store apps are arm64 processes.
3. Every slice links only libraries that ship with iOS (under /usr/lib or /System/Library).
   A hooking library (ElleKit / CydiaSubstrate), libroothide or anything else from the jailbreak
   would be loaded into every app that this library is loaded into.
4. The file contains no "/var/jb" path, so nothing in it ever needs RootHide's patch loader.

Usage: verify_dylib.py <path-to-dylib>
"""
import struct
import sys

CPU_TYPE_ARM64 = 0x0100000C
PTRAUTH_ABI = 0x80000000
LC_REQ_DYLD = 0x80000000
DYLIB_COMMANDS = {0xC: "LOAD_DYLIB", 0x18 | LC_REQ_DYLD: "LOAD_WEAK_DYLIB", 0x1F | LC_REQ_DYLD: "REEXPORT_DYLIB",
                  0x20: "LAZY_LOAD_DYLIB", 0x23 | LC_REQ_DYLD: "LOAD_UPWARD_DYLIB"}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")


def slices(data):
    """Yield (cputype, cpusubtype, bytes) for each slice of a fat or thin Mach-O."""
    be = struct.unpack(">I", data[:4])[0]
    le = struct.unpack("<I", data[:4])[0]
    if be in (0xCAFEBABE, 0xCAFEBABF):
        is64 = be == 0xCAFEBABF
        count = struct.unpack(">I", data[4:8])[0]
        off = 8
        for _ in range(count):
            if is64:
                cput, csub, offset, size = struct.unpack(">IIQQ", data[off:off + 24])
                off += 32
            else:
                cput, csub, offset, size = struct.unpack(">IIII", data[off:off + 16])
                off += 20
            yield cput, csub, data[offset:offset + size]
    elif le == 0xFEEDFACF:
        cput, csub = struct.unpack("<II", data[4:12])
        yield cput, csub, data
    else:
        raise SystemExit("not a Mach-O: magic BE=0x%08x LE=0x%08x" % (be, le))


def linked_libraries(blob):
    """(command name, library path) for each dylib load command of one 64-bit slice."""
    ncmds = struct.unpack("<I", blob[16:20])[0]
    off = 32
    out = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", blob[off:off + 8])
        if cmd in DYLIB_COMMANDS:
            name_off = struct.unpack("<I", blob[off + 8:off + 12])[0]
            name = blob[off + name_off:off + cmdsize].split(b"\0")[0].decode("utf-8", "replace")
            out.append((DYLIB_COMMANDS[cmd], name))
        off += cmdsize
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: verify_dylib.py <dylib>", file=sys.stderr)
        return 2
    data = open(sys.argv[1], "rb").read()
    problems = []
    have_arm64 = have_arm64e = False
    print("slices in %s:" % sys.argv[1])
    for cput, csub, blob in slices(data):
        base = csub & 0x00FFFFFF
        versioned = bool(csub & PTRAUTH_ABI)
        kind = {0: "arm64", 2: "arm64e"}.get(base, "sub=0x%x" % base)
        if cput != CPU_TYPE_ARM64:
            kind = "cputype 0x%08x" % cput
        print("  cputype=0x%08x cpusubtype=0x%08x  [%s%s]  %d bytes" % (
            cput, csub, kind, ", versioned ptrauth" if versioned else "", len(blob)))
        if cput == CPU_TYPE_ARM64 and base == 0:
            have_arm64 = True
        if cput == CPU_TYPE_ARM64 and base == 2:
            if versioned:
                have_arm64e = True
            else:
                problems.append("the arm64e slice has the unversioned (preview) ABI: it would never load into SpringBoard")
        for command, name in linked_libraries(blob):
            ok = name.startswith(SYSTEM_PREFIXES)
            print("      %-16s %s%s" % (command, name, "" if ok else "   <-- not part of iOS"))
            if not ok:
                problems.append("%s slice links %s, which would be loaded into every app" % (kind, name))
    if not have_arm64e:
        problems.append("no versioned arm64e slice (cpusubtype 0x80000002)")
    if not have_arm64:
        problems.append("no arm64 slice: App Store apps could not load the library")
    if b"/var/jb" in data:
        problems.append('the file contains a "/var/jb" path')
    if problems:
        for p in problems:
            print("FAIL: " + p, file=sys.stderr)
        return 1
    print("OK: arm64 + versioned arm64e, only system libraries linked, no /var/jb path.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
