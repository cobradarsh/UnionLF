#!/usr/bin/env python3
"""Fail the build unless the dylib contains an arm64e slice tagged with the
VERSIONED ptrauth ABI (cpusubtype 0x80000002).

Why this gate exists: SpringBoard is an arm64e platform binary built with the
versioned ptrauth ABI. dyld silently refuses an arm64e dylib tagged with the old
"preview" ABI (cpusubtype 0x00000002) into it - no crash, no visible log, the
tweak just never loads. Every Linux-toolchain build of Wingman Plus hit exactly
that. Snapper (known-good on the same device) ships 0x80000002. So we refuse to
package anything that isn't 0x80000002, to never ship a silent dud again.

Usage: verify_arm64e.py <path-to-dylib>
"""
import sys
import struct

CPU_TYPE_ARM64 = 0x0100000C
SUB_ARM64E = 0x00000002
PTRAUTH_ABI = 0x80000000  # bit 31 set == versioned/kernel ABI


def slices(data: bytes):
    """Yield (cputype, cpusubtype) for each slice (fat or thin)."""
    be = struct.unpack(">I", data[:4])[0]
    le = struct.unpack("<I", data[:4])[0]
    if be in (0xCAFEBABE, 0xCAFEBABF):            # FAT
        is64 = be == 0xCAFEBABF
        n = struct.unpack(">I", data[4:8])[0]
        off = 8
        for _ in range(n):
            cput, csub = struct.unpack(">ii", data[off:off + 8])
            off += 32 if is64 else 20
            yield cput & 0xFFFFFFFF, csub & 0xFFFFFFFF
    elif le == 0xFEEDFACF:                          # thin 64-bit
        cput, csub = struct.unpack("<ii", data[4:12])
        yield cput & 0xFFFFFFFF, csub & 0xFFFFFFFF
    else:
        raise SystemExit("not a Mach-O: magic BE=0x%08x LE=0x%08x" % (be, le))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_arm64e.py <dylib>", file=sys.stderr)
        return 2
    data = open(sys.argv[1], "rb").read()
    versioned_arm64e = False
    print("slices in %s:" % sys.argv[1])
    for cput, csub in slices(data):
        base = csub & 0x00FFFFFF
        versioned = bool(csub & PTRAUTH_ABI)
        kind = {0: "arm64", 2: "arm64e"}.get(base, "sub=0x%x" % base)
        tag = "versioned-ptrauth" if versioned else "UNVERSIONED(preview)"
        print("  cputype=0x%08x cpusubtype=0x%08x  [%s, %s]" % (cput, csub, kind, tag))
        if (cput & 0xFFFFFF) == 0x0C and base == SUB_ARM64E and versioned:
            versioned_arm64e = True
    if versioned_arm64e:
        print("OK: versioned arm64e (0x80000002) slice present - will load into SpringBoard.")
        return 0
    print("FAIL: no versioned arm64e slice (need cpusubtype 0x80000002). "
          "This build would install but never load into SpringBoard.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
