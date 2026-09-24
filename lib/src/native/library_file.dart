import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

/// Checks that a file is a shared library this machine's loader can map,
/// before the loader is given it.
///
/// The loader trusts what it opens: on Linux, `dlopen` of a truncated library
/// maps segments past the end of the file and the process dies of a bus
/// error, and a file of random bytes behind an ELF header can do the same
/// (measured 2026-09-25, glibc on linux arm64; macOS's loader refuses the same
/// files). A damaged installation has to be a refusal a person can act on,
/// never a crash, so the file is read first: the right format, word size,
/// byte order and processor for this machine, a shared library, and every
/// segment the loader will map lying inside the file.
///
/// This is a check for damage, not for malice: a library crafted to pass it is
/// still loaded, as the one the person installed.
class LibraryFile {
  /// Why the file at [path] cannot be a shared library for this machine, or
  /// null when it can be.
  static String? problem(String path) {
    final Uint8List bytes;
    try {
      bytes = File(path).readAsBytesSync();
    } on FileSystemException catch (e) {
      return 'it could not be read (${e.osError?.message ?? e.message})';
    }
    if (Platform.isMacOS) return _machO(bytes);
    if (Platform.isLinux) return _elf(bytes);
    return 'this platform is not one cloak is built for';
  }

  // ---- Linux: ELF ----

  static const _elfMachines = {Abi.linuxX64: 62, Abi.linuxArm64: 183};

  static String? _elf(Uint8List b) {
    if (b.length < 64 || b[0] != 0x7f || b[1] != 0x45 || b[2] != 0x4c || b[3] != 0x46) {
      return 'it is not an ELF file';
    }
    if (b[4] != 2) return 'it is not a 64-bit library';
    if (b[5] != 1) return 'it is not little-endian';
    final d = ByteData.sublistView(b);
    int u16(int o) => d.getUint16(o, Endian.little);
    int u32(int o) => d.getUint32(o, Endian.little);
    int u64(int o) => d.getUint64(o, Endian.little);
    if (u16(16) != 3) return 'it is not a shared library';
    final machine = _elfMachines[Abi.current()];
    if (machine == null || u16(18) != machine) return 'it is built for another processor (machine ${u16(18)})';
    final phoff = u64(32), phentsize = u16(54), phnum = u16(56);
    if (phentsize < 56 || phnum == 0 || phoff + phentsize * phnum > b.length) {
      return 'its program headers run past the end of the file, which is ${b.length} bytes';
    }
    for (var i = 0; i < phnum; i++) {
      final h = phoff + i * phentsize;
      // PT_LOAD: a segment the loader maps from the file
      if (u32(h) != 1) continue;
      final offset = u64(h + 8), size = u64(h + 32);
      if (offset + size > b.length) {
        return 'a segment it asks to be mapped runs to byte ${offset + size}, past the end of the file at ${b.length}';
      }
    }
    final shoff = u64(40), shentsize = u16(58), shnum = u16(60);
    if (shoff != 0 && shoff + shentsize * shnum > b.length) {
      return 'its section headers run past the end of the file, which is ${b.length} bytes';
    }
    return null;
  }

  // ---- macOS: Mach-O, thin or universal ----

  static const _cpuArm64 = 0x0100000c, _cpuX64 = 0x01000007;

  static String? _machO(Uint8List b) {
    if (b.length < 32) return 'it is not a Mach-O file';
    final d = ByteData.sublistView(b);
    final want = Abi.current() == Abi.macosArm64 ? _cpuArm64 : _cpuX64;
    // a universal file, big-endian: find this machine's slice
    if (d.getUint32(0, Endian.big) == 0xcafebabe) {
      final n = d.getUint32(4, Endian.big);
      if (n == 0 || n > 16 || 8 + n * 20 > b.length) return 'its universal header is damaged';
      for (var i = 0; i < n; i++) {
        final e = 8 + i * 20;
        if (d.getUint32(e, Endian.big) != want) continue;
        final offset = d.getUint32(e + 8, Endian.big), size = d.getUint32(e + 12, Endian.big);
        if (offset + size > b.length) return 'its slice for this processor runs past the end of the file';
        return _thin(Uint8List.sublistView(b, offset, offset + size), want);
      }
      return 'it holds no slice for this processor';
    }
    return _thin(b, want);
  }

  static String? _thin(Uint8List b, int want) {
    if (b.length < 32) return 'it is not a Mach-O file';
    final d = ByteData.sublistView(b);
    int u32(int o) => d.getUint32(o, Endian.little);
    if (u32(0) != 0xfeedfacf) return 'it is not a 64-bit Mach-O file';
    if (u32(4) != want) return 'it is built for another processor (cpu type 0x${u32(4).toRadixString(16)})';
    // MH_DYLIB
    if (u32(12) != 6) return 'it is not a dynamic library';
    final ncmds = u32(16), sizeofcmds = u32(20);
    if (32 + sizeofcmds > b.length) return 'its load commands run past the end of the file';
    var at = 32;
    for (var i = 0; i < ncmds; i++) {
      if (at + 8 > 32 + sizeofcmds) return 'its load commands are damaged';
      final cmd = u32(at), size = u32(at + 4);
      if (size < 8 || at + size > 32 + sizeofcmds) return 'its load commands are damaged';
      // LC_SEGMENT_64: a segment the loader maps from the file
      if (cmd == 0x19) {
        if (size < 72) return 'its load commands are damaged';
        final fileoff = d.getUint64(at + 40, Endian.little), filesize = d.getUint64(at + 48, Endian.little);
        if (fileoff + filesize > b.length) {
          return 'a segment it asks to be mapped runs to byte ${fileoff + filesize}, past the end of the file at ${b.length}';
        }
      }
      at += size;
    }
    return null;
  }
}
