import 'dart:ffi';
import 'dart:io';

import 'package:libcloak/libcloak.dart';
import 'package:path/path.dart' as p;
// StarkKernels is not exported: tstokenlib treats the kernels as its own
// business. The one thing needed from it is the interface version this build
// was compiled against, which only that class knows, and the lock pins the
// version this path is read from.
// ignore: implementation_imports
import 'package:tstokenlib/src/crypto/stark_kernels.dart' show StarkKernels;

import '../build_facts.dart';

/// The two native libraries `cloak` cannot run without, and where they come
/// from.
///
/// tstokenlib's kernels (ML-KEM, which every key derivation uses) and Isar's
/// core (the header store) are both Rust, loaded at run time. Left to
/// themselves, both libraries look in places a person did not choose:
/// tstokenlib searches down to the working directory, and Isar opens a bare
/// file name (which macOS resolves against the working directory too) and
/// otherwise downloads its library from GitHub and writes it beside the
/// program. A library in the working directory is code a stranger may have
/// put there, and a download is a request nobody asked for.
///
/// So a released build (see [BuildFacts]) takes both
/// from the bundle it was installed from, `lib/` beside the program's `bin/`,
/// found from the program's real path so a link on the person's path still
/// leads back to it. A development build (`dart run`, the suite) keeps each
/// library's own lookup, which is what a checkout side by side needs.
class NativeLibraries {
  /// Whether this program was built by the release build.
  static const releaseBuild = BuildFacts.release;

  /// The variable tstokenlib reads first. A person may point it at another
  /// kernels library; nothing else overrides the bundle.
  static const kernelsVariable = StarkKernels.envVar;

  /// The step every refusal here is made at.
  static const step = 'native library';

  /// Whether this is a released build, which decides whether the bundle is
  /// looked for at all.
  final bool release;

  /// The bundle's directory, in a released build: the directory above the
  /// real `bin/cloak`. Null in a development build.
  final String? bundle;

  final Map<String, String> env;

  NativeLibraries._(this.release, this.bundle, this.env);

  /// The libraries for a program at [executable], which is followed through
  /// any links first: `install.sh` and Homebrew both put a link on the path,
  /// and the bundle is where the link points, not where it is.
  factory NativeLibraries({required String executable, required bool release, required Map<String, String> env}) {
    if (!release) return NativeLibraries._(false, null, env);
    var real = executable;
    try {
      real = File(executable).resolveSymbolicLinksSync();
    } on FileSystemException {
      // a program that cannot find itself still names where it was asked to
      // be, so the refusal below says where it looked
    }
    return NativeLibraries._(true, p.dirname(p.dirname(real)), env);
  }

  /// This process's own libraries.
  factory NativeLibraries.ofProcess(Map<String, String> env) =>
      NativeLibraries(executable: Platform.resolvedExecutable, release: releaseBuild, env: env);

  /// The kernels library's file name on this platform.
  static String get kernelsName => StarkKernels.fileName;

  /// Isar's core library's file name on this platform.
  static String get isarName => Platform.isMacOS ? 'libisar.dylib' : 'libisar.so';

  /// The bundle's `lib/`, in a released build.
  String? get libDirectory => bundle == null ? null : p.join(bundle!, 'lib');

  /// The kernels file tstokenlib takes first: the one the variable names when
  /// it is set, otherwise, in a released build, the bundle's. Null in a
  /// development build with the variable unset, where tstokenlib's own search
  /// is left to find the crate's build beside a checkout.
  String? get kernelsPath {
    final named = env[kernelsVariable];
    if (named != null) return named;
    final lib = libDirectory;
    return lib == null ? null : p.join(lib, kernelsName);
  }

  /// Isar's core library, in a released build; null in a development build,
  /// where Isar finds or downloads its own.
  String? get isarPath {
    final lib = libDirectory;
    return lib == null ? null : p.join(lib, isarName);
  }

  /// Refuses unless the kernels file tstokenlib will take first is there,
  /// loads, and is the interface version this build was compiled against.
  ///
  /// Checked before any command that opens the wallet's keys, so the first
  /// candidate in tstokenlib's search is always one already checked, and the
  /// search never goes on to the working directory. The file is opened here
  /// and opened again by tstokenlib; the loader hands back the same library.
  void checkKernels() {
    final path = kernelsPath;
    if (path == null) return;
    final from = env.containsKey(kernelsVariable) ? '$kernelsVariable names' : 'the installation holds';
    if (path.isEmpty) {
      throw Refusal(step, '$kernelsVariable is set but empty; unset it to use the kernels library that came with cloak');
    }
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      throw Refusal(step, _missing('the kernels library', path, from));
    }
    final int found;
    try {
      final lib = DynamicLibrary.open(path);
      found = lib.lookupFunction<Uint32 Function(), int Function()>('sk_version')();
    } on ArgumentError catch (e) {
      throw Refusal(step, '${_unusable('the kernels library', path, from)} (${_firstLine(e.message)})');
    }
    if (found != StarkKernels.abiVersion) {
      throw Refusal(step,
          'the kernels library $path is interface version $found, and this build of cloak expects version '
          '${StarkKernels.abiVersion}; ${_advice(from)}');
    }
  }

  /// Refuses unless Isar's library is in the bundle, before Isar is touched,
  /// so a missing file is never answered by a download.
  void checkIsar() {
    final path = isarPath;
    if (path == null) return;
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      throw Refusal(step, _missing('the header store\'s library', path, 'the installation holds'));
    }
  }

  /// Isar's library that is there but could not be loaded, as the refusal a
  /// person reads.
  Refusal isarUnusable(Object error) =>
      Refusal(step, '${_unusable('the header store\'s library', isarPath!, 'the installation holds')} ($error)');

  /// What `cloak status` says about each library: where it would be loaded
  /// from and whether a file is there. Nothing is loaded to find out.
  List<Map<String, Object?>> describe() => [
        _describe('kernels', kernelsPath, kernelsName,
            'found by tstokenlib\'s own search (a development build)'),
        _describe('isar', isarPath, isarName, 'found or downloaded by Isar itself (a development build)'),
      ];

  Map<String, Object?> _describe(String name, String? path, String file, String otherwise) => {
        'name': name,
        'file': file,
        'path': path,
        'present': path == null ? null : FileSystemEntity.typeSync(path) == FileSystemEntityType.file,
        if (path == null) 'found': otherwise,
      };

  static String _missing(String what, String path, String from) => from.startsWith(kernelsVariable)
      ? '$kernelsVariable names $path for $what, and there is no file there; ${_advice(from)}'
      : '$what is missing: there is no ${p.basename(path)} in ${p.dirname(path)}; ${_advice(from)}';

  static String _unusable(String what, String path, String from) =>
      '$what $path is there but could not be loaded; ${_advice(from)}';

  static String _advice(String from) => from.startsWith(kernelsVariable)
      ? 'point $kernelsVariable at a kernels library of the right version, or unset it'
      : 'this installation is incomplete; reinstall cloak';

  static String _firstLine(String? s) => (s ?? '').split('\n').first;
}
