@Tags(['perf'])
library;

import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:test/test.dart';

import 'support/fake_pool.dart';
import 'support/harness.dart';

/// What starting costs, measured on the compiled binary a person runs: help,
/// and a balance read from a wallet, neither of which starts the chain or
/// opens the transport.
void main() {
  late Directory out;
  late String binary;
  setUpAll(() async {
    out = Directory.systemTemp.createTempSync('cloak-bin');
    binary = '${out.path}/cloak';
    final r = await Process.run(Platform.resolvedExecutable, ['compile', 'exe', 'bin/cloak.dart', '-o', binary]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  });
  tearDownAll(() => out.deleteSync(recursive: true));

  Future<List<int>> timed(List<String> args, {Map<String, String>? env, int n = 7}) async {
    final times = <int>[];
    for (int i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      final r = await Process.run(binary, args, environment: env);
      times.add(sw.elapsedMilliseconds);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    }
    return times;
  }

  test('cloak --help, inside its bound', () async {
    final times = await timed(['--help']);
    // the bound is on the first run of a fresh binary, the one a person
    // waits for; the others are the operating system's caches
    final first = times.first;
    final sorted = [...times]..sort();
    print('  cloak --help: first $first ms, best ${sorted.first} ms, worst ${sorted.last} ms');
    expect(first, lessThan(500));
  });

  test('cloak balance cold, inside its bound and with no network', () async {
    final fp = await FakePool.build();
    final h = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: DateTime.utc(2023, 11, 1));
    addTearDown(h.dispose);
    await h.initWithPool();
    h.ports.transportPort = fp.transport(rounds: 1, head: 1);
    expect((await h.run(['sync', '--from-genesis'])).code, Exit.done);
    await h.run(['invoice', 'new', '--amount', '500', '--expires', '60d', '--out', '${h.root.path}/i']);
    File('${h.root.path}/p').writeAsBytesSync(fp.standingProof(1).encode());
    expect((await h.run(['check', '${h.root.path}/p'])).code, Exit.done);
    // the pool's server is named as an address nothing listens on: a balance
    // that tried to reach it would fail or hang, and this one does neither
    final times = await timed(['--wallet', h.wallet, 'balance', '--json'], env: {'HOME': h.root.path}, n: 5);
    final first = times.first;
    print('  cloak balance: first $first ms, best ${([...times]..sort()).first} ms');
    expect(first, lessThan(3000));
    expect(Directory(h.dir.chain).existsSync(), isFalse, reason: 'the chain was never started');
  });
}
