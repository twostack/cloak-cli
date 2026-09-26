import 'dart:convert';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:convert/convert.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';

import 'isar_core.dart';

/// Opens the header store in the directory given and prints its answers to
/// the three questions, as one JSON line: one of the processes in "two
/// processes agree".
Future<void> main(List<String> args) async {
  final [directory, name, hash, height] = args;
  await startIsar();
  final isar = await Isar.open(LibSpiffySchemas.allSchemas, directory: directory, name: name);
  final chain = BlockHeaderChain(IsarWalletStorage(isar), params: NetworkParams.forNetwork('regtest'));
  await chain.initialize();
  final source = SpiffyHeaderSource(chain);
  final tip = await source.tip();
  print(jsonEncode({
    'tip': tip.height,
    'tipHash': hex.encode(tip.hash),
    'height': await source.heightOfBlock(hex.decode(hash)),
    'header': hex.encode((await source.headerAtHeight(int.parse(height)))!),
  }));
  await isar.close();
}
