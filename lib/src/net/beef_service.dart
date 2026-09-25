import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libcloak/libcloak.dart';

/// A service that answers a txid with the transaction's BEEF, for a person
/// who knows the txid of a payment to them and was not handed its BEEF.
///
/// Nothing from it is taken on trust: what comes back is checked for holding
/// the transaction asked for, and then like any BEEF a person pastes, its
/// merkle proof against this wallet's own headers. It is asked only when the
/// person asks (`cloak receive --txid`), and only about that one transaction.
class BeefService {
  /// The most an answer may be: the hex of the largest BEEF taken, and room
  /// for the JSON around it.
  final int maxAnswer;
  final String url;
  final Duration timeout;

  BeefService(this.url, {required this.timeout, required this.maxAnswer});

  static final _txid = RegExp(r'^[0-9a-fA-F]{64}$');

  /// The BEEF the service gives for [txid], as the hex it answered with.
  Future<String> fetch(String txid) async {
    if (!_txid.hasMatch(txid)) {
      throw Refusal('txid', '"$txid" is not a txid: a txid is 64 hex digits');
    }
    final uri = Uri.parse('${url.replaceFirst(RegExp(r'/+$'), '')}/${txid.toLowerCase()}');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      final body = await _bounded(response).timeout(timeout);
      final Object? json;
      try {
        json = jsonDecode(body);
      } on FormatException {
        throw Refusal('BEEF service', '$url answered $txid with HTTP ${response.statusCode} and no JSON');
      }
      final beef = json is Map ? json['beef'] : null;
      if (response.statusCode == HttpStatus.ok && beef is String) return beef;
      // the service's own words, whatever shape it gives them, quoted short
      final said = body.trim().length <= 240 ? body.trim() : '${body.trim().substring(0, 240)}...';
      throw Refusal('BEEF service', '$url has no BEEF for $txid; it answered HTTP ${response.statusCode}: $said');
    } on TimeoutException {
      throw Refusal('BEEF service', '$url did not answer within ${timeout.inSeconds} s');
    } on SocketException catch (e) {
      throw Refusal('BEEF service', 'could not reach $url: ${e.osError?.message ?? e.message}');
    } on HttpException catch (e) {
      throw Refusal('BEEF service', 'could not reach $url: ${e.message}');
    } on HandshakeException catch (e) {
      throw Refusal('BEEF service', 'could not reach $url securely: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// The answer's body, refused once it passes [maxAnswer] bytes rather than
  /// held whole: its size is the service's choice.
  Future<String> _bounded(HttpClientResponse response) async {
    final declared = response.contentLength;
    if (declared > maxAnswer) {
      throw Refusal('size', '$url declared an answer of $declared bytes and the most taken is $maxAnswer');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > maxAnswer) {
        throw Refusal('size', '$url sent more than $maxAnswer bytes');
      }
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
}
