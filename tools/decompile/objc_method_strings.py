#!/usr/bin/env python3
"""Objective-C mini class-dump for a Mach-O: recover method implementations and
the ObjC string literals each one builds.

Used here to answer a concrete question: which paths does
-[CacheManager setupCachePaths] actually put into systemCachePaths /
tempFilePaths / photoCachePaths / applicationsPath?

Approach (no IDA, no Ghidra, all offline):
  1. walk __objc_classlist -> objc_class -> class_ro_t -> method_list_t
  2. read method_t entries (both the relative and the classic layout)
  3. disassemble each method body with capstone, resolve adrp/add (and adr)
     pairs to concrete VM addresses
  4. any address landing inside __cfstring is an ObjC string literal the method
     references - print it in the order the method builds it

Requires: macholib, capstone (see tools/requirements-decompile.txt).
"""

import struct
import sys
import zipfile
import tempfile
import os

from macholib.MachO import MachO

try:
    import capstone
except ImportError:
    sys.exit("capstone not installed: pip install -r tools/requirements-decompile.txt")

RELATIVE_METHOD_LIST = 0x80000000
FAST_DATA_MASK = 0x00007FFFFFFFFFF8
# iOS 15+ binaries store pointers in __DATA* as dyld chained fixups: the low
# 36 bits are the target runtime offset (which, with a 0x100000000 load
# address, is the VM address itself) and the high bits carry next/diversity.
POINTER_BITS = (1 << 36) - 1


def fix(v):
    return v & POINTER_BITS


class Section:
    def __init__(self, name, addr, size, offset, data):
        self.name = name
        self.addr = addr
        self.size = size
        self.offset = offset
        self.data = data


class Image:
    def __init__(self, raw, path):
        self.raw = raw
        m = MachO(path)
        header = None
        for h in m.headers:
            # arm64e = cpusubtype 2 (plus capability bits). Its __objc_classlist
            # holds PAC-signed pointers (0x8000...), which are useless offline.
            # Prefer a plain arm64 slice.
            is_pauth = (int(h.header.cpusubtype) & 0xFF) == 2
            if header is None or (not is_pauth and
                                  (int(header.header.cpusubtype) & 0xFF) == 2):
                header = h
        self.base = header.offset
        self.sections = {}
        for lc, seg, sections in header.commands:
            if not type(seg).__name__.startswith("segment"):
                continue
            for s in sections:
                name = s.sectname.rstrip(b"\x00").decode()
                off = self.base + s.offset
                self.sections[name] = Section(name, s.addr, s.size, off,
                                              raw[off:off + s.size])
        self.text = self.sections.get("__text")
        self._cf_cache = {}

    def section_for_addr(self, addr):
        for s in self.sections.values():
            if s.addr <= addr < s.addr + s.size:
                return s
        return None

    def read_addr(self, addr):
        s = self.section_for_addr(addr)
        if not s:
            return None
        return struct.unpack_from("<Q", s.data, addr - s.addr)[0]

    def cstring_at(self, addr):
        s = self.section_for_addr(addr)
        if not s:
            return None
        start = addr - s.addr
        end = s.data.find(b"\x00", start)
        if end < 0:
            end = start + 200
        try:
            return s.data[start:end].decode("utf-8")
        except UnicodeDecodeError:
            return None

    def cfstring_at(self, addr):
        """__cfstring entry: isa(8) flags(8) data-ptr(8) length(8)."""
        if addr in self._cf_cache:
            return self._cf_cache[addr]
        s = self.section_for_addr(addr)
        value = None
        if s and s.name in ("__cfstring", "__data", "__const"):
            off = addr - s.addr
            if off + 32 <= len(s.data):
                _isa, _flags, data_ptr, length = struct.unpack_from("<QQQQ", s.data, off)
                if 0 < length < 4096:
                    target = fix(data_ptr)
                    holder = self.section_for_addr(target)
                    if holder and holder.name == "__ustring":
                        # CFString holding non-ASCII text is UTF-16 here
                        off = target - holder.addr
                        try:
                            value = holder.data[off:off + length * 2].decode("utf-16-le")
                        except UnicodeDecodeError:
                            value = None
                    else:
                        value = self.cstring_at(target)
        self._cf_cache[addr] = value
        return value


def method_lists(image, class_addr):
    """Yield (selector_name, imp_addr) for one class."""
    data_ptr = image.read_addr(class_addr + 32)
    if not data_ptr:
        return []
    ro = fix(data_ptr) & FAST_DATA_MASK
    sect = image.section_for_addr(ro)
    if not sect:
        return []
    ro_off = ro - sect.addr
    if ro_off + 48 > len(sect.data):
        return []
    # class_ro_t: four uint32, then ivarLayout/name/baseMethods are pointers
    _flags, _start, _size, _resv = struct.unpack_from("<IIII", sect.data, ro_off)
    _layout, _name_ptr, methods_ptr = struct.unpack_from("<QQQ", sect.data, ro_off + 16)

    out = []
    if methods_ptr:
        methods_ptr = fix(methods_ptr)
        ms = image.section_for_addr(methods_ptr)
        if ms:
            mo = methods_ptr - ms.addr
            entsize_flags, count = struct.unpack_from("<II", ms.data, mo)
            entsize = entsize_flags & 0xFFFF
            relative = bool(entsize_flags & RELATIVE_METHOD_LIST)
            entry_off = mo + 8
            for i in range(count):
                e_addr = methods_ptr + 8 + i * entsize
                e_off = entry_off + i * entsize
                if e_off + entsize > len(ms.data):
                    break
                if relative:
                    n_off, _t_off, i_off = struct.unpack_from("<iii", ms.data, e_off)
                    name_addr = e_addr + n_off
                    # imp offset is relative to the imp field itself (entry + 8)
                    imp_addr = e_addr + 8 + i_off
                else:
                    n_ptr, _t_ptr, i_ptr = struct.unpack_from("<QQQ", ms.data, e_off)
                    name_addr = fix(n_ptr)
                    imp_addr = fix(i_ptr)
                # with relative lists the name may point into __objc_selrefs,
                # which holds one more pointer to the actual selector string
                holder = image.section_for_addr(name_addr)
                if holder and holder.name == "__objc_selrefs":
                    name_addr = fix(image.read_addr(name_addr) or 0)
                out.append((image.cstring_at(name_addr) or "?", imp_addr))
    return out


def literal_strings_in(image, imp_addr, max_bytes=4000):
    """Disassemble from imp_addr and collect ObjC string literals it loads."""
    if not image.text:
        return []
    start_off = imp_addr - image.text.addr
    if start_off < 0 or start_off >= len(image.text.data):
        return []
    code = image.text.data[start_off:start_off + max_bytes]

    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
    md.detail = False

    found = []
    pending = {}
    for insn in md.disasm(code, imp_addr):
        if insn.mnemonic == "ret" and found:
            break
        ops = [o.strip() for o in insn.op_str.split(",")]
        if insn.mnemonic in ("adrp", "adr") and len(ops) >= 2:
            reg = ops[0]
            try:
                target = int(ops[1].lstrip("#"), 0)
            except ValueError:
                continue
            pending[reg] = target & ~0xFFF if insn.mnemonic == "adrp" else target
        elif insn.mnemonic == "add" and len(ops) == 3:
            dst, src, imm = ops
            if src in pending and imm.startswith("#"):
                try:
                    value = pending[src] + int(imm.lstrip("#"), 0)
                except ValueError:
                    continue
                pending.pop(src, None)
                text = expand_literal(image, value)
                if text:
                    found.append(text)
    return dedupe_keep_order(found)


def array_elements(image, addr):
    """An @[...] literal object: isa(8) count(8) pointer-to-__objc_arraydata(8)."""
    s = image.section_for_addr(addr)
    if not s or s.name != "__objc_arrayobj":
        return None
    off = addr - s.addr
    _isa, count, data_ptr = struct.unpack_from("<QQQ", s.data, off)
    data_ptr = fix(data_ptr)
    holder = image.section_for_addr(data_ptr)
    if not holder or count > 64:
        return None
    out = []
    o = data_ptr - holder.addr
    for k in range(count):
        (p,) = struct.unpack_from("<Q", holder.data, o + 8 * k)
        out.append(image.cfstring_at(fix(p)))
    return out

def expand_literal(image, addr):
    direct = image.cfstring_at(addr)
    if direct:
        return direct
    elements = array_elements(image, addr)
    if elements:
        return "@[" + ", ".join(e if e is not None else "?" for e in elements) + "]"
    return None



def dedupe_keep_order(items):
    seen = set()
    out = []
    for i in items:
        if i not in seen:
            seen.add(i)
            out.append(i)
    return out


def load_binary(path):
    raw = None
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                if info.is_dir():
                    continue
                head = z.open(info).read(4)
                if head in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                    raw = z.open(info).read()
                    print("# using %s from %s" % (info.filename, path))
                    break
    if raw is None:
        raw = open(path, "rb").read()
    tmp = os.path.join(tempfile.gettempdir(), "dump_target.bin")
    open(tmp, "wb").write(raw)
    return Image(raw, tmp)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    only = sys.argv[2:] if len(sys.argv) > 2 else None

    image = load_binary(path)
    classlist = image.sections.get("__objc_classlist")
    if not classlist:
        sys.exit("no __objc_classlist")

    n = len(classlist.data) // 8
    for i in range(n):
        (vm,) = struct.unpack_from("<Q", classlist.data, i * 8)
        for sel, imp in method_lists(image, fix(vm)):
            if only and not any(o in (sel or "") for o in only):
                continue
            strings = literal_strings_in(image, imp)
            print("\n-[%s] imp=0x%x" % (sel, imp))
            for s in strings:
                print(("  *  " if s.startswith("/") else "     ") + s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
