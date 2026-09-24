import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';

import 'support/fake_pool.dart';
import 'support/harness.dart';

/// No command prints a secret, at any verbosity.
void main() {
  test('Verbose output holds no key material', () async {
    final fp = await FakePool.build();
    final early = DateTime.utc(2023, 11, 1);
    final payee = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
    final payer = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
    addTearDown(payee.dispose);
    addTearDown(payer.dispose);

    final streams = StringBuffer();
    Future<Ran> v(Harness h, List<String> args) async {
      final ran = await h.run(['-v', ...args]);
      streams
        ..write(ran.out)
        ..write(ran.err);
      return ran;
    }

    // init prints the seed on standard output, once, by design; its standard
    // error is searched like everything else
    final seeds = <String>[];
    for (final h in [payee, payer]) {
      final ran = await h.run(['-v', 'init', '--network', 'regtest', '--server', '/ip4/127.0.0.1/udp/1/udx/p2p/x', '--pool', 'c']);
      seeds.add(ran.out.trim());
      streams.write(ran.err);
    }
    for (final h in [payee, payer]) {
      final c = File(h.dir.config);
      c.writeAsStringSync(c.readAsStringSync().replaceFirst('timeout_seconds: 30', 'timeout_seconds: 1'));
      h.ports.transportPort = fp.transport(rounds: 1, head: 1);
      await v(h, ['sync', '--from-genesis']);
    }
    final p = '${payer.root.path}/p';
    File(p).writeAsBytesSync(fp.standingProof(1).encode());
    File('${payee.root.path}/p').writeAsBytesSync(fp.standingProof(1).encode());
    await v(payer, ['invoice', 'new', '--amount', '500', '--expires', '60d', '--out', '${payer.root.path}/own']);
    await v(payer, ['check', p]);
    await v(payee, ['invoice', 'new', '--amount', '200', '--expires', '60d', '--out', '${payee.root.path}/inv']);
    await v(payer, ['invoice', 'show', '${payee.root.path}/inv']);
    payer.ports.transportPort = fp.transport();
    await v(payer, ['pay', '${payee.root.path}/inv']);
    await v(payee, ['check', '${payee.root.path}/p']);
    await v(payee, ['ack', '${payee.root.path}/p', '--out', '${payee.root.path}/ack']);
    final id = hex.encode(Invoice.decode(File('${payee.root.path}/inv').readAsBytesSync()).id);
    await v(payer, ['ack', '--check', '${payee.root.path}/ack', '--invoice', id]);
    await v(payer, ['proof', '--invoice', id, '--out', '${payer.root.path}/proof']);
    for (final h in [payee, payer]) {
      for (final c in [
        ['unlock'],
        ['address'],
        ['address', '--transparent'],
        ['status'],
        ['balance'],
        ['notes'],
        ['journal'],
        ['receive', p],
        ['deposit', '--amount', '100', '--yes'],
        ['refund', '--deposit', '00'],
        ['withdraw', '--amount', '100', '--to', 'mzBc4XEFSdzCDcTxAgf6EZXgsZWpztRhef', '--yes'],
      ]) {
        await v(h, c);
        await v(h, [...c, '--json']);
      }
    }

    final all = '$streams';
    final secrets = <String, List<int>>{};
    for (int i = 0; i < 2; i++) {
      final seed = WalletSeed.fromHex(seeds[i]);
      final keys = WalletKeys(seed: seed, birthday: 0);
      secrets['seed $i'] = seed.bytes;
      secrets['spending key $i'] = _lanes(keys.sk);
      secrets['nullifier key $i'] = _lanes(keys.nk);
    }
    secrets['the suite\'s spending key'] = _lanes(fp.keys.sk);
    secrets['passphrase'] = utf8.encode(Harness.passphrase);
    for (final h in [payee, payer]) {
      secrets['transport identity of ${h.wallet}'] = File(h.dir.identity).readAsBytesSync();
    }
    expect(all.length, greaterThan(10000), reason: 'the commands said plenty');
    for (final s in secrets.entries) {
      expect(all.contains(hex.encode(s.value)), isFalse, reason: '${s.key} appears in hex');
      expect(all.toLowerCase().contains(hex.encode(s.value)), isFalse);
      expect(all.contains(latin1.decode(s.value, allowInvalid: true)), isFalse, reason: '${s.key} appears raw');
      expect(all.contains(base64.encode(s.value)), isFalse, reason: '${s.key} appears in base64');
    }
    print('  searched ${all.length} characters of output for ${secrets.length} secrets');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

List<int> _lanes(List<int> lanes) {
  final out = BytesBuilder();
  for (final l in lanes) {
    out.add(Uint8List(4)..buffer.asByteData().setUint32(0, l, Endian.little));
  }
  return out.toBytes();
}
