import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';
import 'package:libspiffy/libspiffy.dart' show BlockHeaderChain;

/// libcloak's header source, over libspiffy's validated header chain.
///
/// Three questions and nothing else: where the accepted chain ends, the height
/// of a block hash on it, and the 80 bytes at a height. Each is answered from
/// headers the chain accepted and validated itself, anchored to the
/// configured network's genesis; none is answered by fetching the block it is
/// about, because a request naming a block a payer handed this wallet would
/// tell whoever answered it which payment was being checked.
///
/// The surface is the port's surface, on purpose. There is no method here
/// taking an address, an outpoint or a transaction id, so this cannot be
/// asked about one, and widening it to make some command easier is the one
/// change this adapter will not take.
class SpiffyHeaderSource implements HeaderSource {
  final BlockHeaderChain _chain;

  SpiffyHeaderSource(this._chain);

  @override
  Future<ChainTip> tip() async {
    final header = _chain.chainTip;
    if (header == null) {
      throw const HeaderSourceFailure('tip', 'the header chain holds no header yet; it has not started syncing');
    }
    return ChainTip(_chain.bestHeight, hex.decode(header.blockHash().toString()));
  }

  @override
  Future<int?> heightOfBlock(List<int> blockHash) async {
    if (blockHash.length != 32) return null;
    // display order, as the chain keys its headers
    return _chain.getHeightByHash(hex.encode(blockHash));
  }

  @override
  Future<List<int>?> headerAtHeight(int height) async {
    if (height < 0) return null;
    final header = await _chain.getHeaderByHeight(height);
    return header?.serialize();
  }
}
