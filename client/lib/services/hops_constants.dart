import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

// The single source of truth for the BLE service UUID Hops advertises and
// scans for. This used to be duplicated as a private constant in both
// hops_app.dart and hops_share_page.dart with a DIFFERENT (unused, dead)
// value defined here — meaning editing this constant used to change
// nothing at runtime. Every file that advertises or filters BLE scans for
// Hops devices must import and use this constant instead of hardcoding it.
const String HOPS_SERVICE_UUID = "0000FA57-0000-1000-8000-00805F9B34FB";

// How much extra bottom padding any tab embedded directly in HopsApp's
// tabs[] (Home, Contacts, Community, Features, My Features) must reserve
// so its own bottom-anchored content — a text field, a button row — isn't
// covered by the floating pill bottom nav bar. HopsApp's outer Scaffold
// uses extendBody: true so that pill can float over the body with a see-
// through margin around it, but that also means the body no longer gets
// the nav bar's height reserved automatically — every affected tab has to
// add this itself (on top of MediaQuery's own bottom inset for gesture-nav
// devices, which this does NOT include). Sized generously above the pill's
// actual rendered height (~64px content + 12px margin) so it clears icon+
// label at larger text-scale settings too.
const double kFloatingNavClearance = 92;

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

// Sender tag length — exactly matches computeRotatingToken's fixed output
// length (6 HMAC bytes -> 8 base64url chars, no padding). Community Chat
// messages are tagged with the sender's *rotating token*, not their
// username — this used to be a truncated-but-still-readable fragment of
// the real username (barely obscured, and static forever), which defeated
// the point once presence beacons stopped doing the same thing. Recipients
// resolve the sender the same way Radar does: a known contact's name if
// their seed matches this window's token, an anonymous entry otherwise.
const int kCommunitySenderTagBytes = 8;

// Chunk index/count are packed into a single nibble each (see
// encodeCommunityChatChunk), so 16 is the hard ceiling.
const int kCommunityMaxChunks = 16;

// Fixed now that the tag is always exactly kCommunitySenderTagBytes long
// (a rotating token, not a variable-length truncated username).
const int kCommunityChunkTextBudget = kCommunityChunkBudgetBytes - 4 - kCommunitySenderTagBytes;

/// Builds one chunk of a (possibly multi-chunk) Community Chat message.
/// [senderToken] must be the caller's current rotating presence token
/// (see computeRotatingToken) — callers compute it once per outgoing
/// message and reuse it across every chunk, so all chunks of one message
/// stay attributable to the same sender even if a window rollover happens
/// mid-broadcast.
Uint8List encodeCommunityChatChunk({
  required String senderToken,
  required int msgId,
  required int chunkIndex,
  required int totalChunks,
  required String chunkText,
}) {
  var tagBytes = utf8.encode(senderToken);
  if (tagBytes.length > kCommunitySenderTagBytes) {
    tagBytes = tagBytes.sublist(0, kCommunitySenderTagBytes);
  }
  final textBytes = utf8.encode(chunkText);
  final packedChunkInfo = ((chunkIndex & 0x0F) << 4) | (((totalChunks - 1) & 0x0F));
  return Uint8List.fromList([
    kCommunityProtocolMarker,
    msgId & 0xFF,
    packedChunkInfo,
    tagBytes.length,
    ...tagBytes,
    ...textBytes,
  ]);
}

class DecodedCommunityChunk {
  final String senderToken;
  final int msgId;
  final int chunkIndex;
  final int totalChunks;
  final String text;
  const DecodedCommunityChunk({
    required this.senderToken,
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
  final tagLen = bytes[3];
  if (bytes.length < 4 + tagLen) return null;
  final senderToken = utf8.decode(bytes.sublist(4, 4 + tagLen), allowMalformed: true);
  final text = utf8.decode(bytes.sublist(4 + tagLen), allowMalformed: true);
  return DecodedCommunityChunk(
    senderToken: senderToken,
    msgId: msgId,
    chunkIndex: chunkIndex,
    totalChunks: totalChunks,
    text: text,
  );
}

// ── Rotating presence identifiers ───────────────────────────────────────
//
// Replaces the raw "HPS:<username>" beacon with "HPS:<rotating token>" so a
// passive BLE scanner (anyone with a generic scanner app, not just other
// Hops users) can no longer read a stable identifier off the air and use it
// to track a device's movement across campus over time — the same threat
// model Apple/Google's Exposure Notification rolling identifiers address.
//
// Each device holds a private, never-transmitted `rotating_id_seed`
// (generated at signup/first sign-in, see root_gatekeeper.dart, kept in
// secure storage next to private_key). The token below is deterministic
// from that seed + a coarse time window, so it changes on its own schedule
// without any coordination between devices. Only someone who already holds
// the *same* seed — exchanged pairwise, once, over an already-encrypted
// chat session (HopsChatService payload type 0x03, see chat_terminal.dart)
// — can recompute it and recognize a beacon as belonging to a known
// contact. Everyone else just sees an opaque, changing string.

/// 15 minutes: the same order of magnitude Exposure Notification rotates
/// its rolling identifiers on — long enough that resolving a contact's
/// token stays cheap (recompute once per window, not continuously), short
/// enough to defeat casually logging beacons at fixed campus locations to
/// reconstruct someone's day.
const Duration kRotatingIdWindow = Duration(minutes: 15);

int _rotatingIdWindowIndex(DateTime time) =>
    time.millisecondsSinceEpoch ~/ kRotatingIdWindow.inMilliseconds;

/// Derives the rotating presence token for [seed] at [at] (defaults to
/// now). 6 raw HMAC bytes → 8 base64url characters (padding stripped) —
/// comfortably inside the 29-byte advertisement budget alongside the
/// "HPS:" prefix, with room to spare.
String computeRotatingToken(List<int> seed, {DateTime? at}) {
  final window = _rotatingIdWindowIndex(at ?? DateTime.now());
  final mac = Hmac(sha256, seed).convert(utf8.encode('$window'));
  return base64Url.encode(mac.bytes.sublist(0, 6)).replaceAll('=', '');
}

/// True if [token] is [seed]'s rotating token for the current window OR
/// the previous one — tolerates a device being checked right at (or just
/// after) a window rollover instead of requiring exact clock alignment.
bool matchesRotatingToken(List<int> seed, String token) {
  final now = DateTime.now();
  if (computeRotatingToken(seed, at: now) == token) return true;
  final previousWindow = now.subtract(kRotatingIdWindow);
  return computeRotatingToken(seed, at: previousWindow) == token;
}

// ── Emergency Flare signature chunking ──────────────────────────────────
//
// An RSA-2048 signature (~256 bytes) is far too big for one BLE packet, so
// it rides the same manufacturer-data scan-response channel Community Chat
// uses — a distinct protocol marker keeps the two from ever being
// misparsed as each other. Unlike Community Chat, no sender tag or message
// id is needed here: the flare's advertisement name (the exact
// "EMG:<sender>:<reason>" string) is broadcast in the *same* packet as
// each signature chunk, so a receiver already has the natural correlation
// key for free — see hops_app.dart's scan-result handling.
const int kFlareSigProtocolMarker = 0x45; // ascii 'E'

const int kFlareSigChunkBudgetBytes = kCommunityChunkBudgetBytes - 2;

Uint8List encodeFlareSigChunk({
  required int chunkIndex,
  required int totalChunks,
  required List<int> chunkBytes,
}) {
  final packedChunkInfo = ((chunkIndex & 0x0F) << 4) | (((totalChunks - 1) & 0x0F));
  return Uint8List.fromList([kFlareSigProtocolMarker, packedChunkInfo, ...chunkBytes]);
}

class DecodedFlareSigChunk {
  final int chunkIndex;
  final int totalChunks;
  final List<int> bytes;
  const DecodedFlareSigChunk({
    required this.chunkIndex,
    required this.totalChunks,
    required this.bytes,
  });
}

DecodedFlareSigChunk? decodeFlareSigChunk(List<int> bytes) {
  if (bytes.length < 2 || bytes[0] != kFlareSigProtocolMarker) return null;
  final packed = bytes[1];
  final chunkIndex = (packed >> 4) & 0x0F;
  final totalChunks = (packed & 0x0F) + 1;
  return DecodedFlareSigChunk(
    chunkIndex: chunkIndex,
    totalChunks: totalChunks,
    bytes: bytes.sublist(2),
  );
}

// ── Watch Me seed exchange ───────────────────────────────────────────────
//
// Watch Me needs a buddy's rotating-ID seed to recognize their presence
// beacon — same requirement Radar has for resolving a name. Until now the
// only way to learn a contact's seed was chatting with them first (see
// HopsChatService payload type 0x03), so "add a friend, then use Watch Me
// on them" silently never worked without an unrelated detour through
// Chat. This piggybacks the seed onto the exact BLE exchange a watch
// request/accept already requires being in range for, so a watch
// relationship becomes self-sufficient. Reuses the same manufacturer-data
// scan-response channel as Community Chat/flare signatures/game tags —
// see hops_app.dart's sendWatchRequest/_acceptWatchRequestBle for the
// cycling side and the WR:/WA: scan handler for reassembly.
const int kWatchSeedProtocolMarker = 0x53; // ascii 'S'
const int kWatchSeedChunkBudgetBytes = kCommunityChunkBudgetBytes - 2;

Uint8List encodeWatchSeedChunk({
  required int chunkIndex,
  required int totalChunks,
  required List<int> chunkBytes,
}) {
  final packedChunkInfo = ((chunkIndex & 0x0F) << 4) | (((totalChunks - 1) & 0x0F));
  return Uint8List.fromList([kWatchSeedProtocolMarker, packedChunkInfo, ...chunkBytes]);
}

class DecodedWatchSeedChunk {
  final int chunkIndex;
  final int totalChunks;
  final List<int> bytes;
  const DecodedWatchSeedChunk({
    required this.chunkIndex,
    required this.totalChunks,
    required this.bytes,
  });
}

DecodedWatchSeedChunk? decodeWatchSeedChunk(List<int> bytes) {
  if (bytes.length < 2 || bytes[0] != kWatchSeedProtocolMarker) return null;
  final packed = bytes[1];
  final chunkIndex = (packed >> 4) & 0x0F;
  final totalChunks = (packed & 0x0F) + 1;
  return DecodedWatchSeedChunk(
    chunkIndex: chunkIndex,
    totalChunks: totalChunks,
    bytes: bytes.sublist(2),
  );
}

// ── Discoverable presence (opt-in name reveal) ──────────────────────────
//
// Radar's dots are anonymous by default (see the rotating-ID scheme above)
// — deliberate, but it also means "spot the dot that's actually my friend
// across the room" doesn't really work: there's no way to tell which dot is
// who without them already being a resolved contact. Discoverable mode is
// an explicit, off-by-default toggle (flipped from Radar) that rides an
// extra manufacturer-data broadcast alongside the normal beacon, revealing
// a plaintext username to anyone scanning nearby *only* while it's on — the
// "HPS:<token>" beacon name itself, and its anti-tracking rotation, are
// completely untouched. Same manufacturer-data channel as Community Chat/
// flare signatures/game tags, distinguished by its own marker byte.
//
// This is a self-asserted, unverified label — anyone can claim any name
// while discoverable, the same way telling someone your name out loud is
// unverified. It only ever affects what's *displayed*; it doesn't grant
// anything and a friend request still requires the recipient's accept.
const int kDiscoverableProtocolMarker = 0x44; // ascii 'D'
const int kDiscoverableMaxUsernameBytes = 20;

Uint8List encodeDiscoverableName(String username) {
  var bytes = utf8.encode(username);
  if (bytes.length > kDiscoverableMaxUsernameBytes) {
    bytes = bytes.sublist(0, kDiscoverableMaxUsernameBytes);
  }
  return Uint8List.fromList([kDiscoverableProtocolMarker, ...bytes]);
}

String? decodeDiscoverableName(List<int> bytes) {
  if (bytes.isEmpty || bytes[0] != kDiscoverableProtocolMarker) return null;
  return utf8.decode(bytes.sublist(1), allowMalformed: true);
}

// ── Hops & Robbers runner tag ───────────────────────────────────────────
//
// Fixes a regression from the rotating-ID presence beacon: the tag
// scanner used to read a runner's username straight off "HPS:<username>",
// which stopped working the moment that beacon started carrying an opaque
// rotating token instead. Rather than trying to resolve tokens back to
// names mid-game (game lobby participants are frequently strangers with
// no exchanged rotating-ID seed at all — unlike Watch Me, which only ever
// targets existing contacts), a runner broadcasts a small, explicit,
// consensual tag alongside their normal beacon for exactly as long as
// they're actively a runner in an active game — never at any other time.
// Reuses the same manufacturer-data channel as Community Chat/flare
// signatures, distinguished by its own marker byte.
const int kGameRunnerTagProtocolMarker = 0x52; // ascii 'R'
const int kGameRunnerTagMaxUsernameBytes = 20;

Uint8List encodeGameRunnerTag(String username) {
  var bytes = utf8.encode(username);
  if (bytes.length > kGameRunnerTagMaxUsernameBytes) {
    bytes = bytes.sublist(0, kGameRunnerTagMaxUsernameBytes);
  }
  return Uint8List.fromList([kGameRunnerTagProtocolMarker, ...bytes]);
}

String? decodeGameRunnerTag(List<int> bytes) {
  if (bytes.isEmpty || bytes[0] != kGameRunnerTagProtocolMarker) return null;
  return utf8.decode(bytes.sublist(1), allowMalformed: true);
}