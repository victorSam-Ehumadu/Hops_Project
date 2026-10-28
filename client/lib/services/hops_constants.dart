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

// ── Shared manufacturer-data channel ────────────────────────────────────
//
// 0xFFFF is the Bluetooth SIG's reserved "for testing" company ID —
// appropriate here since Hops isn't a SIG-registered manufacturer.
//
// Community Chat used to ride this channel too (the v2 wire format,
// removed — see the v3 block below for why). What still uses it: Emergency
// Flare / Official Alert signature chunks, Watch Me seed exchange, and
// the discoverable-name tag. Those are all
// *supplementary* — every one of them enriches something whose primary
// signal already rides the advertisement name, so if this channel silently
// drops on a given handset the feature degrades (an alert shows as
// unverified) instead of disappearing. That's exactly why Community Chat,
// which had no such fallback, was the one feature that broke outright.
const int kCommunityManufacturerId = 0xFFFF;

// Legacy BLE scan-response packets are spec-capped at 31 bytes total, and
// a Manufacturer Specific Data structure costs 4 of those for its own
// header (1 length + 1 AD-type + 2 company-ID). Budgeted well under the
// resulting ~27-byte ceiling since several Android chipsets append their
// own AD structures (e.g. TX Power Level) to a scan response regardless of
// what the app asked for, and an overflowing packet is dropped whole.
const int kCommunityChunkBudgetBytes = 20;

// ── Community Chat wire format v3: advertisement LOCAL NAME, chunked ────
//
// Replaces a v2 encoding that put chunks in scan-response manufacturer
// data (since removed). Why the change, concretely:
//
// Every feature in this app that is *confirmed working on real hardware*
// rides the BLE advertisement local name — "HPS:" presence beacons
// (Radar), "EMG:"/"EMG_OFF:" (Emergency Flare), "FR:"/"FA:" (friend
// requests), "HOP:"/"ACK:" (pairing codes), "VBT:" (Vibe Check). Every
// feature that rides manufacturer data in the *scan response* is either
// unconfirmed or outright broken, and Community Chat — the one feature
// that depends on that channel entirely, with no name-based fallback —
// was the one that never delivered a single message across two rounds of
// tuning the byte budget. Scan-response manufacturer data is a known
// weak spot across Android OEMs (whether it's emitted at all, and whether
// a filtered scan even performs the active-scan request needed to receive
// it, both vary), and this app has no way to make it more reliable.
//
// So: same chunk-and-reassemble idea, moved onto the channel that
// demonstrably works. The tradeoff is a much tighter per-chunk budget
// (the name shares one 31-byte advertisement packet with flags and the
// 128-bit Hops service UUID), so messages take more chunks and arrive
// over more seconds — acceptable for a broadcast chat, and vastly
// preferable to not arriving.
//
// Budget: 24 characters, and the history of this number matters because
// getting it wrong fails silently.
//
// It was 27, derived by assuming "EMG:<8-char sender>:<14-char reason>"
// transmits — an upper bound nobody had actually observed at full length.
// Messages whose first chunk landed on exactly 27 never arrived, while
// shorter ones did: a 21-character message chunks to 27 + 20, and only the
// 20 got out, so reassembly could never complete and the message vanished
// with no error anywhere.
//
// The arithmetic behind the real ceiling: a legacy BLE packet is 31 bytes.
// The name can't share the advertisement with the 128-bit Hops service
// UUID (3 flags + 18 UUID = 21, leaving 10 — less than this format's own
// 13-byte overhead), so it rides the scan response instead. That gives
// 31 - 2 (the name's AD header) = 29, minus the 3-byte TX Power structure
// many Android stacks append whether asked to or not = 26.
//
// 24, not 26, deliberately: two characters of margin for a handset that
// adds one more AD structure of its own. This is a broadcast chat in a
// safety app — a message that arrives beats a longer one that doesn't, and
// the cost is only that long messages take one more chunk.
const int kCommunityNameBudget = 24;

/// Hard ceiling for ANY advertisement local name, in UTF-8 bytes.
///
/// Same arithmetic as kCommunityNameBudget above, stopping at the computed
/// ceiling rather than taking its extra two bytes of margin: the name
/// rides the scan response, giving 31 - 2 (AD header) = 29, minus the
/// 3-byte TX Power structure many Android stacks append whether asked to
/// or not = 26.
///
/// Guards that used 29 were wrong, and wrong in the worst direction: a
/// 27-28 byte name passed the check, overflowed the packet, and failed the
/// whole advertisement with ADVERTISE_FAILED_DATA_TOO_LARGE. Since that
/// verdict only arrives asynchronously on a callback (see
/// hops_app.dart's _handleAdvertisingStatusUpdate) the send looked
/// successful and simply never left the radio.
const int kAdvertisementNameMaxBytes = 26;

/// Whether [name] fits in a single advertisement.
///
/// Measured in UTF-8 BYTES, not characters — the budget is a byte budget,
/// so an accented or emoji character costs more than one. `.length` on a
/// Dart String counts UTF-16 code units and silently under-counts both.
bool advertisementNameFits(String name) =>
    utf8.encode(name).length <= kAdvertisementNameMaxBytes;

/// How many bytes of room are left for free text in an advertisement whose
/// fixed framing (prefix, separators, any id) costs [overheadBytes].
/// Lets a UI constrain its input field instead of failing at send time.
int advertisementTextBudget(int overheadBytes) {
  final left = kAdvertisementNameMaxBytes - overheadBytes;
  return left < 0 ? 0 : left;
}

const String kCommunityChatPrefix = 'CM:';
// Admin-originated — same layout, different prefix, so one decode path
// handles both; only the styling and the role check on resolution differ.
const String kAdminCommunityChatPrefix = 'CA:';

// prefix(3) + senderTag(8) + msgId(1) + chunkInfo(1)
//
// The sender tag is the first 8 characters of the sender's real USERNAME,
// not their rotating presence token. This is a deliberate, scoped
// departure from the rotating-ID anonymity the "HPS:" presence beacon
// uses, for two reasons:
//
//   1. Moderation requires attribution. A reported Community Chat message
//      has to name an actual account for an admin to warn or ban — a
//      rotating token resolves to a name only on the devices that already
//      hold that sender's seed (i.e. people they've chatted with), so
//      reports from anyone else arrived carrying a useless "Anonymous
//      #xxxx" as the target, and the admin app's warn/ban then failed
//      against an account that doesn't exist.
//   2. Nobody else could read names either. Non-contacts saw every
//      message as "Anonymous #xxxx", which is poor for a feature whose
//      whole purpose is talking to people nearby.
//
// What this does NOT change: the presence beacon keeps its rotating
// token, so passive BLE scanners still can't follow a device around
// campus over time — that's the threat the rotating-ID scheme actually
// exists to defeat. This only attaches a name to a message someone chose
// to broadcast publicly, in a feature already labelled as broadcasting to
// everyone nearby.
//
// 8 characters matches the sender-tag width EMG:/ADM: already use, so
// KeyDirectory.candidatesForTruncatedUsername resolves these for free.
const int kCommunityNameSenderTagChars = 8;
const int kCommunityNameOverhead = 13;
const int kCommunityNameTextBudget = kCommunityNameBudget - kCommunityNameOverhead; // 11

// chunkIndex and (totalChunks-1) are packed into 3 bits each inside one
// character, so 8 is the hard ceiling — 8 × 18 = 144 bytes per message.
const int kCommunityNameMaxChunks = 8;

// Single-character encoding alphabet for msgId/chunkInfo. Deliberately
// excludes ':' so it can never be confused with the prefix separator, and
// is exactly 64 characters so one char carries a clean 6 bits.
const String _kNameFieldAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

/// Builds one chunk of a Community Chat message as a BLE advertisement
/// local name. [senderTag] is the sender's username — truncated/padded to
/// kCommunityNameSenderTagChars below, and resolved back to the full
/// account via KeyDirectory on receipt.
String encodeCommunityNameChunk({
  required String senderTag,
  required int msgId,
  required int chunkIndex,
  required int totalChunks,
  required String chunkText,
  bool isAdmin = false,
}) {
  final prefix = isAdmin ? kAdminCommunityChatPrefix : kCommunityChatPrefix;
  // Padded as well as truncated — a short tag would otherwise shift every
  // fixed offset the decoder relies on.
  final tag = senderTag.length >= kCommunityNameSenderTagChars
      ? senderTag.substring(0, kCommunityNameSenderTagChars)
      : senderTag.padRight(kCommunityNameSenderTagChars, '_');
  final id = _kNameFieldAlphabet[msgId & 0x3F];
  final info = _kNameFieldAlphabet[
      ((chunkIndex & 0x07) << 3) | ((totalChunks - 1) & 0x07)];
  return '$prefix$tag$id$info$chunkText';
}

class DecodedCommunityNameChunk {
  final String senderTag;
  final int msgId;
  final int chunkIndex;
  final int totalChunks;
  final String text;
  final bool isAdmin;
  const DecodedCommunityNameChunk({
    required this.senderTag,
    required this.msgId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.text,
    required this.isAdmin,
  });
}

// Field offsets, DERIVED from the tag width rather than written as
// literals. They were hardcoded (7, 8, substring(3, 7)) for an earlier
// 4-character tag; widening the tag to 8 updated the overhead constant but
// not those literals, so the decoder went on reading msgId and the chunk
// index/count out of the middle of the sender's username. Every chunk
// decoded to a nonsense chunkIndex/totalChunks, reassembly never completed,
// and Community Chat stopped delivering anything at all. Deriving them
// means the layout can only ever be changed in one place.
// ── Admin message deletion (CX:) ────────────────────────────────────────
//
// An admin removing a Community Chat message from everyone's device.
//
// There is no server to delete from — Community Chat is a broadcast that
// only ever exists as a local copy on each phone that heard it. So a
// deletion is itself a broadcast: every device that receives one replaces
// its own copy with a tombstone carrying the reason.
//
// Layout, well inside the 27-char name budget:
//   prefix(3) + senderTag(8) + msgId(1) + reason(1) = 13 chars
//
// senderTag + msgId is exactly the pair the receiver already keys messages
// by (see community_alerts.dart's msgKey), so a deletion identifies its
// target with no new identifier on the wire.
//
// Honest limits, since this is moderation and the gap matters: a device
// that is out of range when the deletion goes out keeps its copy, and a
// device that never heard the original ignores the deletion. This removes
// a message from the devices that are around to hear it, which is the most
// a serverless broadcast can promise.
const String kCommunityDeletePrefix = 'CX:';

/// Why a message was removed. Ordinal is what travels on the wire, so
/// entries may be appended but never reordered or removed — an older build
/// would render a shifted index as the wrong reason.
enum CommunityDeleteReason { spam, harassment, inappropriate, misinformation, other, removedBySender }

const Map<CommunityDeleteReason, String> kCommunityDeleteReasonLabels = {
  CommunityDeleteReason.spam: 'spam',
  CommunityDeleteReason.harassment: 'harassment',
  CommunityDeleteReason.inappropriate: 'inappropriate content',
  CommunityDeleteReason.misinformation: 'misinformation',
  CommunityDeleteReason.other: 'breaking the rules',
  // Not a moderation reason — the sender simply removed their own message.
  // Used for the streamlined self-delete path in community_alerts.dart,
  // which skips the "why is it being removed" picker entirely (a
  // moderation-flavored reason picker makes no sense when you're deleting
  // your own content, not someone else's).
  CommunityDeleteReason.removedBySender: 'removed by sender',
};

String encodeCommunityDeletion({
  required String senderTag,
  required int msgId,
  required CommunityDeleteReason reason,
}) {
  final tag = senderTag.length > kCommunityNameSenderTagChars
      ? senderTag.substring(0, kCommunityNameSenderTagChars)
      : senderTag.padRight(kCommunityNameSenderTagChars, '_');
  return '$kCommunityDeletePrefix$tag'
      '${_kNameFieldAlphabet[msgId & 0x3F]}'
      '${_kNameFieldAlphabet[reason.index & 0x3F]}';
}

class DecodedCommunityDeletion {
  final String senderTag;
  final int msgId;
  final CommunityDeleteReason reason;
  const DecodedCommunityDeletion({
    required this.senderTag,
    required this.msgId,
    required this.reason,
  });
}

DecodedCommunityDeletion? decodeCommunityDeletion(String advName) {
  if (!advName.startsWith(kCommunityDeletePrefix)) return null;
  // 3 + 8 + 1 + 1
  if (advName.length < 13) return null;
  final tag = advName.substring(3, 3 + kCommunityNameSenderTagChars);
  final msgId = _kNameFieldAlphabet.indexOf(advName[11]);
  final reasonIndex = _kNameFieldAlphabet.indexOf(advName[12]);
  if (msgId < 0 || reasonIndex < 0) return null;
  // A newer build could send a reason this one doesn't know. Falling back
  // to `other` still removes the message, which is the part that matters —
  // dropping the whole deletion over an unknown label would leave the
  // message on screen.
  final reason = reasonIndex < CommunityDeleteReason.values.length
      ? CommunityDeleteReason.values[reasonIndex]
      : CommunityDeleteReason.other;
  return DecodedCommunityDeletion(senderTag: tag, msgId: msgId, reason: reason);
}

const int _kCommunityTagStart = 3; // after "CM:"/"CA:"
const int _kCommunityTagEnd = _kCommunityTagStart + kCommunityNameSenderTagChars;
const int _kCommunityMsgIdIndex = _kCommunityTagEnd;
const int _kCommunityChunkInfoIndex = _kCommunityMsgIdIndex + 1;

DecodedCommunityNameChunk? decodeCommunityNameChunk(String advName) {
  final isAdmin = advName.startsWith(kAdminCommunityChatPrefix);
  if (!isAdmin && !advName.startsWith(kCommunityChatPrefix)) return null;
  if (advName.length < kCommunityNameOverhead) return null;

  final msgId = _kNameFieldAlphabet.indexOf(advName[_kCommunityMsgIdIndex]);
  final info = _kNameFieldAlphabet.indexOf(advName[_kCommunityChunkInfoIndex]);
  // Not our encoding (or a corrupted/truncated name) — reject rather than
  // reassemble a message out of garbage offsets.
  if (msgId < 0 || info < 0) return null;

  return DecodedCommunityNameChunk(
    senderTag: advName.substring(_kCommunityTagStart, _kCommunityTagEnd),
    msgId: msgId,
    chunkIndex: (info >> 3) & 0x07,
    totalChunks: (info & 0x07) + 1,
    text: advName.substring(kCommunityNameOverhead),
    isAdmin: isAdmin,
  );
}

/// Short, stable, non-reversible label for a sender whose real name isn't
/// being shown — the "#abcd" in "Anonymous #abcd".
///
/// Needed because the Community Chat sender tag is now the sender's actual
/// username (moderation needs an account an admin can act on), so the
/// anonymous label can't just be built from the tag the way it was when
/// the tag was an opaque rotating token — doing that rendered
/// "Anonymous #Kwame123", which is the opposite of anonymous. Hashing it
/// keeps the useful property (the same person reads as the same label, so
/// a conversation is followable) without printing their name.
///
/// Scope, honestly: this is display-level obfuscation, not a privacy
/// guarantee. The username itself travels in the advertisement in the
/// clear, so anything actually reading the air sees it regardless — and
/// because the mapping is deterministic and usernames are guessable, this
/// label is reversible by anyone who cares to try. What it does is keep
/// the app from casually broadcasting everyone's name to everyone else's
/// screen, which is the property this feature is meant to have.
String anonymousLabelFor(String senderTag) {
  final trimmed = senderTag.replaceAll(RegExp(r'_+$'), '');
  final digest = sha256.convert(utf8.encode('hops-anon:$trimmed'));
  // 3 bytes -> exactly 4 base64url characters, no padding.
  return base64Url.encode(digest.bytes.sublist(0, 3)).replaceAll('=', '');
}

/// Splits [message] into at most kCommunityNameMaxChunks pieces that each
/// fit kCommunityNameTextBudget *bytes* — the advertisement budget is a
/// byte budget, so a multi-byte character counts for more than one.
///
/// Accumulates whole characters rather than slicing the raw byte array:
/// a byte-index split can land in the middle of a multi-byte character,
/// which corrupts it on both sides of the seam (each half decodes to a
/// replacement character and the original is unrecoverable). Emoji and
/// accented characters in a chat message are entirely ordinary, so that
/// would be a real, visible bug rather than a theoretical one.
List<String> splitCommunityMessage(String message) {
  final chunks = <String>[];
  final buffer = StringBuffer();
  var bufferBytes = 0;

  for (final rune in message.runes) {
    final ch = String.fromCharCode(rune);
    final chBytes = utf8.encode(ch).length;
    if (bufferBytes + chBytes > kCommunityNameTextBudget) {
      chunks.add(buffer.toString());
      if (chunks.length >= kCommunityNameMaxChunks) return chunks;
      buffer.clear();
      bufferBytes = 0;
    }
    buffer.write(ch);
    bufferBytes += chBytes;
  }

  if (buffer.isNotEmpty && chunks.length < kCommunityNameMaxChunks) {
    chunks.add(buffer.toString());
  }
  if (chunks.isEmpty) chunks.add('');
  return chunks;
}

// ── Alert composition: splitting a long alert into reliable parts ───────
//
// One Community Alerts message tops out at kCommunityNameMaxChunks ×
// kCommunityNameTextBudget = 88 bytes — the advertisement-name budget times
// the most chunks the wire format can address (chunkIndex and totalChunks-1
// are each packed into 3 bits in encodeCommunityNameChunk, so 8 is a hard
// ceiling, not a tuning knob). Reassembly needs every chunk of a message to
// arrive, so a message needing more chunks has strictly more independent
// chances for one to be missed — admin_ble_hub.dart's broadcastAdminChatMessage
// now gives a long message more repeat cycles to narrow that gap, but it
// can't close it, especially against real-world BLE flakiness on older
// Android hardware.
//
// Rather than push the per-message ceiling any higher (which would mean
// widening chunkIndex/totalChunks past 3 bits, eating further into the
// already-tiny 11-byte text-per-chunk budget — a losing trade), a long
// alert is split into several independent messages instead, each kept
// small enough to land in the reliable few-chunk band on its own. A
// dropped chunk then only costs one part of the alert, not the whole
// thing, and every part already qualifies for the "<=3 chunks" 3-cycle
// treatment short messages get.
//
// 3 chunks' worth of bytes per part — comfortably inside the reliable band
// broadcastAdminChatMessage already special-cases, while still keeping the
// part count for an ordinary long sentence low (most alerts split into 2-3
// parts, not six).
const int kAlertPartMaxBytes = kCommunityNameTextBudget * 3; // 33

// Hard cap on how many separate broadcasts one composed alert turns into —
// bounds both total airtime (each part takes roughly a chunk-cycle's worth
// of seconds) and how many consecutive bubbles a single alert floods the
// feed with. An admin who needs more than this is better served by two
// separate alerts than a single wall of text anyway.
const int kAlertMaxParts = 6;

/// [parts] is what actually gets sent, in order. [truncated] is true if the
/// composed alert didn't fit within kAlertMaxParts and had to be cut short —
/// surfaced rather than silently dropped, the same lesson the original
/// 27-byte chunk-budget bug (see kCommunityNameBudget above) already cost
/// this app once: a length limit that fails silently just moves the bug
/// from "visible in testing" to "reported by a confused admin."
class AlertSplitResult {
  final List<String> parts;
  final bool truncated;
  const AlertSplitResult(this.parts, this.truncated);
}

/// Splits [message] on word boundaries into parts that each fit within
/// kAlertPartMaxBytes, so every part reassembles inside the reliable band
/// rather than needing anywhere near the full 8-chunk ceiling. Falls back
/// to splitCommunityMessage's byte-safe hard split only for a single "word"
/// that alone exceeds the budget (e.g. a long URL with no spaces) — rare,
/// but a part still has to fit on the wire regardless of where the spaces
/// fell.
AlertSplitResult splitIntoAlertParts(String message) {
  final words = message.trim().split(RegExp(r'\s+'));
  final parts = <String>[];
  var current = StringBuffer();
  var currentBytes = 0;

  void flushCurrent() {
    if (current.isEmpty) return;
    parts.add(current.toString());
    current = StringBuffer();
    currentBytes = 0;
  }

  for (final word in words) {
    if (word.isEmpty) continue;
    final wordBytes = utf8.encode(word).length;

    if (wordBytes > kAlertPartMaxBytes) {
      flushCurrent();
      for (final piece in splitCommunityMessage(word)) {
        // splitCommunityMessage caps each piece to kCommunityNameTextBudget
        // — smaller than kAlertPartMaxBytes — so an oversized word turns
        // into more parts, never a less reliable one.
        parts.add(piece);
        if (parts.length >= kAlertMaxParts) {
          return AlertSplitResult(parts, true);
        }
      }
      continue;
    }

    final joinBytes = current.isEmpty ? 0 : 1; // the joining space
    if (currentBytes + joinBytes + wordBytes > kAlertPartMaxBytes) {
      flushCurrent();
      if (parts.length >= kAlertMaxParts) {
        return AlertSplitResult(parts, true);
      }
    }
    if (current.isNotEmpty) {
      current.write(' ');
      currentBytes += 1;
    }
    current.write(word);
    currentBytes += wordBytes;
  }
  flushCurrent();

  if (parts.length > kAlertMaxParts) {
    return AlertSplitResult(parts.sublist(0, kAlertMaxParts), true);
  }
  if (parts.isEmpty) parts.add('');
  return AlertSplitResult(parts, false);
}

// ── 1:1 direct message over the advertisement name (BLE fallback) ───────
//
// Fallback transport for 1:1 chat when RFCOMM can't connect (see
// ble_direct_message_service.dart / rfcomm_chat_service.dart). Same
// chunked-advertisement-name idea as Community Chat v3 above, with two
// differences: it carries BOTH a recipient and a sender tag (Community
// Chat is a broadcast and needs only the sender), and its payload is
// base64 of an *encrypted* blob rather than plain text — these
// advertisements are readable by any BLE scanner in range, so a private
// message can't ride them in the clear. See mesh_crypto.dart's
// sealDirectMessage, including its honest limitations.
//
// Tags are 3 characters here rather than Community Chat's 4: two tags plus
// the prefix and framing already cost 11 of the 27-byte name budget, and
// every extra tag character comes straight out of message length. A
// 3-char base64url tag is 18 bits — collisions are more likely than at 4,
// but a collision only causes a wasted decryption attempt, since the
// encryption key (not the tag) is what actually determines who can read a
// message.
const String kDirectMessagePrefix = 'DM:';
const int kDirectMessageTagChars = 3;
// prefix(3) + recipientTag(3) + senderTag(3) + msgId(1) + chunkInfo(1)
const int kDirectMessageOverhead = 11;
const int kDirectMessageTextBudget = kCommunityNameBudget - kDirectMessageOverhead; // 13
const int kDirectMessageMaxChunks = 8;

/// First kDirectMessageTagChars of a rotating presence token — the
/// addressing unit for direct messages on both ends.
String directMessageTag(String rotatingToken) =>
    rotatingToken.length > kDirectMessageTagChars
        ? rotatingToken.substring(0, kDirectMessageTagChars)
        : rotatingToken.padRight(kDirectMessageTagChars, '_');

String encodeDirectMessageChunk({
  required String recipientTag,
  required String senderTag,
  required int msgId,
  required int chunkIndex,
  required int totalChunks,
  required String chunkPayload,
}) {
  final id = _kNameFieldAlphabet[msgId & 0x3F];
  final info = _kNameFieldAlphabet[
      ((chunkIndex & 0x07) << 3) | ((totalChunks - 1) & 0x07)];
  return '$kDirectMessagePrefix$recipientTag$senderTag$id$info$chunkPayload';
}

class DecodedDirectMessageChunk {
  final String recipientTag;
  final String senderTag;
  final int msgId;
  final int chunkIndex;
  final int totalChunks;
  final String payload;
  const DecodedDirectMessageChunk({
    required this.recipientTag,
    required this.senderTag,
    required this.msgId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.payload,
  });
}

// Derived, not literal — these happen to be correct for the current
// 3-character tag width, but see decodeCommunityNameChunk's comment for
// what hardcoding them cost there when a tag width changed.
const int _kDmRecipientStart = 3; // after "DM:"
const int _kDmRecipientEnd = _kDmRecipientStart + kDirectMessageTagChars;
const int _kDmSenderEnd = _kDmRecipientEnd + kDirectMessageTagChars;
const int _kDmMsgIdIndex = _kDmSenderEnd;
const int _kDmChunkInfoIndex = _kDmMsgIdIndex + 1;

DecodedDirectMessageChunk? decodeDirectMessageChunk(String advName) {
  if (!advName.startsWith(kDirectMessagePrefix)) return null;
  if (advName.length < kDirectMessageOverhead) return null;

  final msgId = _kNameFieldAlphabet.indexOf(advName[_kDmMsgIdIndex]);
  final info = _kNameFieldAlphabet.indexOf(advName[_kDmChunkInfoIndex]);
  if (msgId < 0 || info < 0) return null;

  return DecodedDirectMessageChunk(
    recipientTag: advName.substring(_kDmRecipientStart, _kDmRecipientEnd),
    senderTag: advName.substring(_kDmRecipientEnd, _kDmSenderEnd),
    msgId: msgId,
    chunkIndex: (info >> 3) & 0x07,
    totalChunks: (info & 0x07) + 1,
    payload: advName.substring(kDirectMessageOverhead),
  );
}

/// Longest plaintext that survives encryption + base64 + chunking. Worked
/// backwards from the wire budget: kDirectMessageMaxChunks ×
/// kDirectMessageTextBudget base64 characters carry 3/4 that many bytes,
/// of which kDirectMessageNonceBytes are spent on the nonce.
int get kDirectMessageMaxPlaintextBytes {
  const base64Chars = kDirectMessageMaxChunks * kDirectMessageTextBudget; // 104
  const rawBytes = (base64Chars ~/ 4) * 3; // 78
  return rawBytes - 6; // kDirectMessageNonceBytes — 72
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

/// Prefix variant of matchesRotatingToken, for Community Chat's 4-char
/// sender tag (the full 8-char token doesn't fit the advertisement-name
/// budget — see kCommunityNameSenderTagChars).
///
/// A 4-char base64url prefix is 24 bits, so two unrelated contacts can
/// collide roughly once in 16 million per window — and a collision is
/// harmless here anyway: the worst case is one contact's name shown on
/// another's broadcast message, in a chat that is explicitly public and
/// where unresolved senders already display as anonymous. Not worth
/// spending 4 more of the 18 precious text bytes to make exact.
bool matchesRotatingTokenPrefix(List<int> seed, String prefix) {
  final now = DateTime.now();
  if (computeRotatingToken(seed, at: now).startsWith(prefix)) return true;
  final previousWindow = now.subtract(kRotatingIdWindow);
  return computeRotatingToken(seed, at: previousWindow).startsWith(prefix);
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

// How long a personal Emergency Flare (EMG:) stays live once triggered —
// the broadcast auto-stops, the alarm on receivers' phones auto-cancels,
// and the sender's own countdown all key off this one value. Was 30
// seconds; raised to a full minute so there's more real time for someone
// nearby to notice, react, and actually reach whoever triggered it, rather
// than the window closing while they're still working out where the sound
// came from. Doesn't apply to an admin's Official Alert (ADM:) — that one
// keeps its own separate 30-second window in official_alert_service.dart,
// which this constant deliberately leaves untouched.
const Duration kEmergencyFlareDuration = Duration(seconds: 60);

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

// ── Lost & Found board post encoding (chunked) ──────────────────────────
//
// A post carries a type flag plus two free-text fields (object, location).
// At 10/7-character field limits the combined text fit in one 29-byte BLE
// advertisement name; raised to 30/30 (up to 61 characters combined)
// outgrew that, so this is chunked and reassembled the same way Community
// Alerts solves "message longer than one packet" (see kCommunityNameBudget
// above) — adapted here since a Lost & Found postId is already unique per
// post, so reassembly keys directly on it; no separate msgId field is
// needed the way Community Alerts needs one (it has many messages per
// sender to tell apart, a Lost & Found post is posted once).
//
// Layout per chunk: "LNF:" (4) + postId (4) + type (1) + chunkInfo (1) =
// 10 overhead, leaving kLostFoundChunkTextBudget of the ~29-byte total for
// text. chunkIndex/totalChunks-1 pack into chunkInfo the same 3-bits-each
// scheme encodeCommunityNameChunk uses, so up to 8 chunks — comfortably
// enough for 61 characters at ~19 per chunk (4 chunks).
const String kLostFoundPrefix = 'LNF:';
const int kLostFoundPostIdChars = 4;
const int kLostFoundOverhead = 4 + kLostFoundPostIdChars + 1 + 1; // 10
const int kLostFoundChunkTextBudget = 29 - kLostFoundOverhead; // 19
const int kLostFoundMaxChunks = 8;

String encodeLostFoundChunk({
  required String postId,
  required String typeChar,
  required int chunkIndex,
  required int totalChunks,
  required String chunkText,
}) {
  final info = _kNameFieldAlphabet[((chunkIndex & 0x07) << 3) | ((totalChunks - 1) & 0x07)];
  return '$kLostFoundPrefix$postId$typeChar$info$chunkText';
}

class DecodedLostFoundChunk {
  final String postId;
  final String typeChar;
  final int chunkIndex;
  final int totalChunks;
  final String text;
  const DecodedLostFoundChunk({
    required this.postId,
    required this.typeChar,
    required this.chunkIndex,
    required this.totalChunks,
    required this.text,
  });
}

const int _kLnfTypeIndex = 4 + kLostFoundPostIdChars; // 8
const int _kLnfChunkInfoIndex = _kLnfTypeIndex + 1; // 9

DecodedLostFoundChunk? decodeLostFoundChunk(String advName) {
  if (!advName.startsWith(kLostFoundPrefix)) return null;
  if (advName.length < kLostFoundOverhead) return null;
  final postId = advName.substring(4, 4 + kLostFoundPostIdChars);
  final typeChar = advName[_kLnfTypeIndex];
  final info = _kNameFieldAlphabet.indexOf(advName[_kLnfChunkInfoIndex]);
  if (info < 0) return null;
  return DecodedLostFoundChunk(
    postId: postId,
    typeChar: typeChar,
    chunkIndex: (info >> 3) & 0x07,
    totalChunks: (info & 0x07) + 1,
    text: advName.substring(kLostFoundOverhead),
  );
}

/// Splits [text] (the combined "object|location" string) into pieces that
/// each fit kLostFoundChunkTextBudget bytes — same byte-safe whole-
/// character accumulation as splitCommunityMessage, just against this
/// format's own (larger) per-chunk budget.
List<String> splitLostFoundText(String text) {
  final chunks = <String>[];
  final buffer = StringBuffer();
  var bufferBytes = 0;

  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    final chBytes = utf8.encode(ch).length;
    if (bufferBytes + chBytes > kLostFoundChunkTextBudget) {
      chunks.add(buffer.toString());
      if (chunks.length >= kLostFoundMaxChunks) return chunks;
      buffer.clear();
      bufferBytes = 0;
    }
    buffer.write(ch);
    bufferBytes += chBytes;
  }

  if (buffer.isNotEmpty && chunks.length < kLostFoundMaxChunks) {
    chunks.add(buffer.toString());
  }
  if (chunks.isEmpty) chunks.add('');
  return chunks;
}