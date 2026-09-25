import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:isar/isar.dart';

/// Starts Isar for a test that opens a header store itself.
///
/// From the library ISAR_CORE_LIB names when it is set, which is how the
/// release build runs the suite on the library it has just built from
/// source; otherwise Isar downloads its own, as a development build does.
/// Isar publishes no library for Linux on arm64, so there the variable is
/// the only way.
Future<void> startIsar() {
  final built = Platform.environment['ISAR_CORE_LIB'];
  return built == null
      ? Isar.initializeIsarCore(download: true)
      : Isar.initializeIsarCore(libraries: {Abi.current(): built});
}
