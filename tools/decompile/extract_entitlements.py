#!/usr/bin/env python3
"""Dump entitlements from Mach-O binaries inside an IPA/TIPA.

Pure stdlib. Handles:
  - fat (0xCAFEBABE / 0xBEBAFECA) and thin (0xFEEDFACE / 0xFEEDFACF) binaries
  - __TEXT,__entitlements sections (sectcreate-style embedding)
  - LC_CODE_SIGNATURE superblob slots: XML entitlements (0xFADE7171) and DER
    entitlements (0xFADE7172)

Usage:
    python3 extract_entitlements.py <ipa-or-tipa> [mach-o-path-inside-archive]
"""

import io
import plistlib
import struct
import sys
import zipfile

FAT_MAGIC_BE = 0xCAFEBABE
FAT_MAGIC_LE = 0xBEBAFECA
MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC_32 = 0xFEEDFACE

LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D

CSMAGIC_REQUIREMENT = 0xFADE0C00
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_DETACHED_SIGNATURE = 0xFADE0CC1
CSMAGIC_ENTITLEMENTS = 0xFADE7171
CSMAGIC_DER_ENTITLEMENTS = 0xFADE7172
CSMAGIC_BLOBWRAPPER = 0xFADE0B01

MAGIC_NAMES = {
    CSMAGIC_REQUIREMENT: "Requirement",
    CSMAGIC_CODEDIRECTORY: "CodeDirectory",
    CSMAGIC_EMBEDDED_SIGNATURE: "EmbeddedSignature",
    CSMAGIC_DETACHED_SIGNATURE: "DetachedSignature",
    CSMAGIC_ENTITLEMENTS: "Entitlements(XML)",
    CSMAGIC_DER_ENTITLEMENTS: "Entitlements(DER)",
    CSMAGIC_BLOBWRAPPER: "BlobWrapper",
}

ENTITLEMENT_SLOTS = {5: "CSSLOT_ENTITLEMENTS", 7: "CSSLOT_DER_ENTITLEMENTS"}


def read_be(data, fmt, off):
    size = struct.calcsize(fmt)
    return struct.unpack_from(fmt, data, off) + (size,)


def iter_slices(data):
    """Yield (arch_description, offset, size, is64) for every Mach-O slice."""
    (magic,) = struct.unpack_from(">I", data, 0)
    if magic in (FAT_MAGIC_BE, FAT_MAGIC_LE):
        swapped = magic == FAT_MAGIC_LE
        end = ">" if not swapped else "<"
        (nfat,) = struct.unpack_from(end + "I", data, 4)
        off = struct.calcsize(end + "II")
        for i in range(nfat):
            cputype, cpusubtype, soff, ssize, align = struct.unpack_from(
                end + "iiIII", data, off + i * struct.calcsize(end + "iiIII")
            )
            slice_le = struct.unpack_from("<I", data, soff)[0]
            yield describe_cpu(cputype, cpusubtype), soff, ssize, slice_le == MH_MAGIC_64
        return

    (le,) = struct.unpack_from("<I", data, 0)
    swapped = le in (MH_MAGIC_64, MH_MAGIC_32)
    thin = le if swapped else magic
    if thin not in (MH_MAGIC_64, MH_MAGIC_32):
        return
    yield ("thin-64" if thin == MH_MAGIC_64 else "thin-32", 0, len(data), thin == MH_MAGIC_64)


def describe_cpu(cputype, cpusubtype):
    known = {
        0x0100000C: "arm64",
        0x0200000C: "arm64e",
        0x0000000C: "arm",
        0x01000007: "x86_64",
    }
    base = known.get(cputype, "cpu%08x" % (cputype & 0xFFFFFFFF))
    return "%s.%08x" % (base, cpusubtype & 0xFFFFFFFF)


def parse_load_commands(data, base, size, swapped, is64):
    end = "<" if swapped else ">"
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags = struct.unpack_from(
        end + "IiiIIII", data, base
    )
    hdrsize = 32 if is64 else 28
    cmds = []
    off = base + hdrsize
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(end + "II", data, off)
        cmds.append((cmd, cmdsize, off))
        off += cmdsize
        if off >= base + size:
            break
    return end, cmds


def printable_name(raw):
    name = raw.split(b"\0")[0]
    if not name:
        return None
    try:
        text = name.decode("ascii")
    except UnicodeDecodeError:
        return None
    return text if all(c.isprintable() for c in text) else None


def segment_sections(data, end, off, is_seg64):
    """Locate a segment's section table.

    Apple's ld emits LC_SEGMENT_64 with an extra 8-byte field between `fileoff`
    and `maxprot` (macholib models it as `filesize`), so the classic +56/+64
    offsets mis-parse every section by 8 bytes. Try both layouts and keep the
    one whose section names actually decode. Verified against macholib:
    __TEXT,__entitlements of our own build sits at file offset 35786.
    """
    candidates = [(72, 64, 80)] if is_seg64 else [(60, 56, 68), (52, 48, 68)]
    if is_seg64:
        candidates.append((64, 56, 80))
    for sect_start, nsects_at, sect_size in candidates:
        (nsects,) = struct.unpack_from(end + "I", data, off + nsects_at)
        if nsects == 0 or off + sect_start + nsects * sect_size > len(data):
            continue
        names = []
        ok = True
        for i in range(nsects):
            s = off + sect_start + i * sect_size
            text = printable_name(data[s : s + 16])
            if text is None:
                ok = False
                break
            names.append(text)
        if ok:
            return off + sect_start, nsects, sect_size
    return None, 0, 0


def find_entitlements_section(data, base, size, swapped, is64):
    """Return the bytes of __TEXT,__entitlements if the linker embedded one."""
    end, cmds = parse_load_commands(data, base, size, swapped, is64)
    for cmd, cmdsize, off in cmds:
        if cmd not in (LC_SEGMENT, LC_SEGMENT_64):
            continue
        segname = printable_name(data[off + 8 : off + 16]) or ""
        soff, nsects, sect_size = segment_sections(data, end, off, cmd == LC_SEGMENT_64)
        if not nsects:
            continue
        for i in range(nsects):
            s = soff + i * sect_size
            sname = printable_name(data[s : s + 16])
            if segname != "__TEXT" or sname != "__entitlements":
                continue
            if cmd == LC_SEGMENT_64:
                fields = struct.unpack_from(end + "16s16sQQ" + "I" * 8, data, s)
            else:
                fields = struct.unpack_from(end + "16s16sII" + "I" * 8, data, s)
            # fields: sectname, segname, addr, size, offset, align, reloff,
            #         nreloc, flags, reserved1, reserved2, reserved3
            s_offset = fields[4]
            s_size = fields[3]
            return data[base + s_offset : base + s_offset + s_size]
    return None


def find_code_signature(data, base, size, swapped, is64):
    end, cmds = parse_load_commands(data, base, size, swapped, is64)
    for cmd, cmdsize, off in cmds:
        if cmd != LC_CODE_SIGNATURE:
            continue
        cs_off, cs_size = struct.unpack_from(end + "II", data, off + 8)
        return base + cs_off, cs_size
    return None, 0


def parse_superblob(data, cs_start, cs_size, swapped):
    """Parse the embedded signature superblob.

    NOTE: everything inside LC_CODE_SIGNATURE is *always* big-endian, regardless
    of the Mach-O's own byte order. Offsets in the index are relative to the
    start of the superblob.
    """
    end = ">"
    magic, length, count = struct.unpack_from(end + "III", data, cs_start)
    if magic not in (CSMAGIC_EMBEDDED_SIGNATURE, CSMAGIC_DETACHED_SIGNATURE):
        return []
    out = []
    idx = cs_start + struct.calcsize(end + "III")
    for i in range(count):
        slot, off = struct.unpack_from(end + "II", data, idx + i * struct.calcsize(end + "II"))
        blob_at = cs_start + off
        if blob_at + 8 > cs_start + cs_size:
            continue
        bmagic, blen = struct.unpack_from(end + "II", data, blob_at)
        out.append((slot, bmagic, blob_at, min(blen, cs_start + cs_size - blob_at)))
    return out


def dump_macho(name, data, out):
    found_any = False
    for arch, base, size, is64 in iter_slices(data):
        if base + min(size, 4096) > len(data):
            continue
        swapped = struct.unpack_from("<I", data, base)[0] in (MH_MAGIC_64, MH_MAGIC_32)
        out.write("\n=== %s :: %s ===\n" % (name, arch))

        sec = find_entitlements_section(data, base, size, swapped, is64)
        if sec:
            found_any = True
            out.write("--- __TEXT,__entitlements section ---\n")
            emit_plist(sec, out)

        cs_start, cs_size = find_code_signature(data, base, size, swapped, is64)
        if not cs_start:
            out.write("(no LC_CODE_SIGNATURE)\n")
            continue
        for slot, bmagic, blob_at, blen in parse_superblob(data, cs_start, cs_size, swapped):
            if bmagic not in (CSMAGIC_ENTITLEMENTS, CSMAGIC_DER_ENTITLEMENTS):
                continue
            found_any = True
            label = ENTITLEMENT_SLOTS.get(slot, "slot%d" % slot)
            payload = data[blob_at + 8 : blob_at + blen]
            out.write("--- %s (%s, %d bytes) ---\n" % (label, MAGIC_NAMES.get(bmagic, hex(bmagic)), blen))
            if bmagic == CSMAGIC_ENTITLEMENTS:
                emit_plist(payload, out)
            else:
                out.write(payload.hex()[:4000] + "\n")
                out.write("(DER decoded length~%d, see docs/ for tooling)\n" % len(payload))
    return found_any


def emit_plist(payload, out):
    try:
        obj = plistlib.loads(payload)
    except Exception as exc:
        out.write("! plist parse failed: %s\n" % exc)
        out.write(payload[:4000].decode("utf-8", "replace") + "\n")
        return
    for key in sorted(obj.keys()):
        out.write("%-70s %s\n" % (key, repr_brief(obj[key])))
    out.write("\n--- raw plist ---\n")
    out.write(plistlib.dumps(obj).decode("utf-8", "replace"))


def repr_brief(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return v if len(v) < 120 else v[:117] + "..."
    if isinstance(v, (list, tuple)):
        return "[%d items] %s" % (len(v), ", ".join(repr_brief(x) for x in v)[:300])
    if isinstance(v, dict):
        return "{%d keys}" % len(v)
    return str(v)


def looks_macho(head):
    if len(head) < 8:
        return False
    (be,) = struct.unpack_from(">I", head, 0)
    if be in (FAT_MAGIC_BE, FAT_MAGIC_LE):
        return True
    (le,) = struct.unpack_from("<I", head, 0)
    return le in (MH_MAGIC_64, MH_MAGIC_32)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    archive = sys.argv[1]
    only = sys.argv[2] if len(sys.argv) > 2 else None
    out = io.StringIO()

    if zipfile.is_zipfile(archive):
        members = []
        with zipfile.ZipFile(archive) as zf:
            members = [i for i in zf.infolist() if not i.is_dir()]
        out.write("Archive: %s (%d entries)\n" % (archive, len(members)))
        for i in members:
            out.write("  %10d  %s\n" % (i.file_size, i.filename))

        targets = []
        with zipfile.ZipFile(archive) as zf:
            for info in members:
                if only and info.filename != only:
                    continue
                head = zf.open(info).read(8) if info.file_size >= 8 else b""
                if looks_macho(head):
                    targets.append((info.filename, zf.open(info).read()))
        if only and not targets:
            out.write("\n!! %s is not a Mach-O\n" % only)

        for name, data in targets:
            dump_macho(name, data, out)
    else:
        with open(archive, "rb") as fh:
            data = fh.read()
        if not looks_macho(data[:8]):
            out.write("!! %s is neither a zip nor a Mach-O\n" % archive)
        else:
            dump_macho(archive, data, out)

    text = out.getvalue()
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
