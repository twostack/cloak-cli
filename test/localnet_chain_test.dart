@Tags(['localnet', 'perf'])
library;

import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:test/test.dart';

/// libspiffy's header chain, started the way a command starts it, against
/// localnet's regtest node.
///
///   POOL_LOCALNET=1 dart test test/localnet_chain_test.dart
void main() {
  final skip = Platform.environment['POOL_LOCALNET'] == null ? 'needs ../localnet up; set POOL_LOCALNET=1' : null;

  test('A warm chain opens inside the bound', () async {
    final root = Directory.systemTemp.createTempSync('cloak-chain');
    addTearDown(() => root.deleteSync(recursive: true));
    final dir = WalletDir('${root.path}/w', DirSource.argument);
    Directory(dir.path).createSync();
    final config = CloakConfig(network: CloakNetwork.regtest, peers: const ['127.0.0.1:18333']);

    // the first start fills the store from the node
    final progress = StringBuffer();
    final cold = Stopwatch()..start();
    final first = await SpiffyChain.start(dir, config, progress: progress);
    final height = (await first.headers.tip()).height;
    cold.stop();
    await first.stop();
    print('  cold start to height $height: ${cold.elapsedMilliseconds} ms');
    expect(height, greaterThan(0), reason: 'the store holds localnet\'s chain: $progress');

    final times = <int>[];
    for (int i = 0; i < 3; i++) {
      final sw = Stopwatch()..start();
      final chain = await SpiffyChain.start(dir, config);
      final tip = await chain.headers.tip();
      times.add(sw.elapsedMilliseconds);
      expect(tip.height, greaterThanOrEqualTo(height));
      await chain.stop();
    }
    times.sort();
    print('  a warm chain answers its first question in: best ${times.first} ms, worst ${times.last} ms');
    expect(times.first, lessThan(2000));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
}
