import 'dart:io';

import 'package:libspiffy/libspiffy.dart' show CdnSyncPhase;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../wallet/config.dart';
import '../wallet/wallet_dir.dart';

/// Seeding the header store from a CDN, said out loud.
///
/// libspiffy downloads the CDN's chunks and checks every header in them
/// (anchored to genesis, linked, proof of work) before it writes one, and on
/// any failure it falls back to peers and carries on. That fallback is
/// correct, and silent: the reason goes to a log nobody sees without `-v`,
/// and a peer sync from an empty store looks exactly like a hang. So the
/// progress is printed chunk by chunk, and a fallback is printed with its
/// reason whatever the verbosity.
///
/// Once a seed has succeeded the store is marked, and the CDN is not asked
/// again: a chain start would otherwise make a request to a third party on
/// every command, and wait out its timeout whenever the CDN is down. Peers
/// carry a seeded store from there. A store whose seed failed is not marked,
/// so the next start tries again.
class CdnSeed {
  /// The file in the header store saying it was seeded, and from where.
  static const markFile = 'cdn';

  /// The logger libspiffy's CDN sync warns on, with the reason it failed.
  static const _logger = 'CdnHeaderSyncService';
  static const _failed = 'CDN header sync failed: ';

  final String url;
  final StringSink? progress;
  bool _fellBack = false;
  bool _asked = false;
  String? _reason;

  CdnSeed(this.url, this.progress);

  /// The CDN a start should seed from, or null when [config] names none or
  /// the store in [dir] was seeded already.
  static String? urlFor(WalletDir dir, CloakConfig config) {
    final url = config.cdnUrl;
    if (url == null || File(p.join(dir.chain, markFile)).existsSync()) return null;
    return url;
  }

  /// libspiffy's progress callback.
  void onProgress(int current, int total, CdnSyncPhase phase) {
    switch (phase) {
      case CdnSyncPhase.fetchingManifest:
        _asked = true;
        progress?.writeln('cloak: chain: asking $url for headers');
      // said as each chunk goes in, and once all are in
      case CdnSyncPhase.importingHeaders || CdnSyncPhase.complete:
        progress?.writeln('cloak: chain: headers from $url: ${_count(current)} of ${_count(total)}');
      case CdnSyncPhase.fallbackToP2P:
        _fellBack = true;
      case CdnSyncPhase.downloadingChunks || CdnSyncPhase.validatingChunks:
        break;
    }
  }

  /// Takes the reason for a failure from libspiffy's warning, the only place
  /// it is given.
  void onLog(LogRecord r) {
    if (r.loggerName != _logger || r.level < Level.WARNING || !r.message.startsWith(_failed)) return;
    _reason = r.message.substring(_failed.length).replaceFirst(RegExp(r'^Exception: '), '');
  }

  /// Says a fallback, if there was one. Called however the start ended,
  /// since a start that then fails for its peers is exactly when a person
  /// needs to know the CDN failed first.
  void sayFallback() {
    if (!_fellBack) return;
    progress?.writeln('cloak: chain: the header CDN at $url could not be used'
        '${_reason == null ? '' : ' ($_reason)'}; headers come from peers instead, which from an empty store '
        'takes a long time. The next command tries the CDN again; chain.cdn: ${CloakConfig.noCdn} in '
        'config.yaml stops it');
  }

  /// Once the chain has started, marks [dir]'s store seeded at [height], if
  /// the CDN was asked and did not fail.
  Future<void> finish(WalletDir dir, int height) async {
    // a start that never reached the manifest did not seed anything
    if (_fellBack || !_asked) return;
    await File(p.join(dir.chain, markFile)).writeAsString('$url\n$height\n');
  }

  static String _count(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');
}
