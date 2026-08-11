import 'dart:convert';
import 'dart:typed_data';

// The single source of truth for the BLE service UUID Hops advertises and
// scans for. This used to be duplicated as a private constant in both
// hops_app.dart and hops_share_page.dart with a DIFFERENT (unused, dead)
// value defined here — meaning editing this constant used to change
// nothing at runtime. Every file that advertises or filters BLE scans for
// Hops devices must import and use this constant instead of hardcoding it.
const String HOPS_SERVICE_UUID = "0000FA57-0000-1000-8000-00805F9B34FB";

// ── Community Chat wire format (v2: manufacturer-data, chunked) ────────────
// Replaces the old "CM:<4charUser>:<21charMsg>" local-name encoding, which
// was capped by the ~29-byte BLE local-name budget and forced username
// collisions at 4 characters. The payload now rides in the scan-response
// packet's Manufacturer Specific Data AD structure instead — that packet
// starts every broadcast completely empty (nothing else in this app uses
// it), giving a dedicated byte budget rather than fighting the primary
// packet's flags + service-UUID + "HPS:username" beacon for space. Long
// messages are split across multiple chunks and reassembled on arrival, so
// there's no hard length wall — just diminishing propagation speed.
//
// 0xFFFF is the Bluetooth SIG's reserved "for testing" company ID —
// appropriate here since Hops isn't a SIG-registered manufacturer.
const int kCommunityManufacturerId = 0xFFFF;

// Distinguishes our chunks from any unrelated manufacturer data another
// app might broadcast on the same (very commonly reused) test ID.
const int kCommunityProtocolMarker = 0x43; // ascii 'C'

// The legacy BLE scan-response packet is spec-capped at 31 bytes total; a
// Manufacturer Specific Data structure costs 4 of those for its own header
// (1 length + 1 AD-type + 2 company-ID), leaving a theoretical ceiling
// around 27 bytes if the scan response carries nothing else. Budgeted a
// few bytes under that as a safety margin — the exact real-world ceiling
// hasn't been verified against physical hardware, and scan-response
// reliability is a known flaky spot across Android OEMs. Tune down here
// if on-device testing shows drops.
const int kCommunityChunkBudgetBytes = 24;

// Sender tag length. Larger than the old 4-char cap (meaningfully fewer
// collisions) without eating too much of the already-tight chunk budget.
const int kCommunityUsernameMaxBytes = 8;

// Chunk index/count are packed into a single nibble each (see
// encodeCommunityChatChunk), so 16 is the hard ceiling.
const int kCommunityMaxChunks = 16;

String communityUsernameTag(String username) {
  var tag = username.length > kCommunityUsernameMaxBytes
      ? username.substring(0, kCommunityUsernameMaxBytes)
      : username;
  // Defensive re-clip by bytes, not chars — a multi-byte UTF-8 username
  // could still overflow the reserved slot even after the char-based trim.
  var bytes = utf8.encode(tag);
  if (bytes.length > kCommunityUsernameMaxBytes) {
    bytes = bytes.sublist(0, kCommunityUsernameMaxBytes);
    tag = utf8.decode(bytes, allowMalformed: true);
  }
  return tag;
}

/// Builds one chunk of a (possibly multi-chunk) Community Chat message.
/// [username] is the full, untruncated sender name — truncation to the
/// wire-format tag happens in here, once, so callers never have to
/// duplicate that logic (which is exactly how the old protocol drifted
/// out of sync between broadcaster and receiver).
Uint8List encodeCommunityChatChunk({
  required String username,
  required int msgId,
  required int chunkIndex,
  required int totalChunks,
  required String chunkText,
}) {
  final userBytes = utf8.encode(communityUsernameTag(username));
  final textBytes = utf8.encode(chunkText);
  final packedChunkInfo = ((chunkIndex & 0x0F) << 4) | (((totalChunks - 1) & 0x0F));
  return Uint8List.fromList([
    kCommunityProtocolMarker,
    msgId & 0xFF,
    packedChunkInfo,
    userBytes.length,
    ...userBytes,
    ...textBytes,
  ]);
}

// How much chunk-text budget is left over once a given username's tag
// bytes are accounted for — used to decide how to split an outgoing
// message before any chunk is actually built.
int communityChunkTextBudget(String username) {
  final userBytesLen = utf8.encode(communityUsernameTag(username)).length;
  final budget = kCommunityChunkBudgetBytes - 4 - userBytesLen;
  return budget < 1 ? 1 : budget;
}

class DecodedCommunityChunk {
  final String username;
  final int msgId;
  final int chunkIndex;
  final int totalChunks;
  final String text;
  const DecodedCommunityChunk({
    required this.username,
    required this.msgId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.text,
  });
}

DecodedCommunityChunk? decodeCommunityChatChunk(List<int> bytes) {
  if (bytes.length < 4 || bytes[0] != kCommunityProtocolMarker) return null;
  final msgId = bytes[1];
  final packed = bytes[2];
  final chunkIndex = (packed >> 4) & 0x0F;
  final totalChunks = (packed & 0x0F) + 1;
  final userLen = bytes[3];
  if (bytes.length < 4 + userLen) return null;
  final username = utf8.decode(bytes.sublist(4, 4 + userLen), allowMalformed: true);
  final text = utf8.decode(bytes.sublist(4 + userLen), allowMalformed: true);
  return DecodedCommunityChunk(
    username: username,
    msgId: msgId,
    chunkIndex: chunkIndex,
    totalChunks: totalChunks,
    text: text,
  );
}