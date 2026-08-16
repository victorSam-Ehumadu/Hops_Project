// lib/utils/mesh_crypto.dart
//
// The two low-level identity primitives every sign-up/sign-in flow needs —
// pulled out of root_gatekeeper.dart so the Admin app's own sign-in screen
// (which never signs up, only signs in to an already-provisioned account)
// can share them instead of re-implementing password hashing by hand.
// hashPassword in particular MUST stay byte-identical between both apps:
// the server only ever sees/compares the hash (see
// supabase/migrations/0001_lockdown_profiles.sql), so any drift here would
// make an otherwise-correct password fail to sign in from one app but not
// the other.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:crypton/crypton.dart';

Map<String, String> generateLocalMeshKeys() {
  final keypair = RSAKeypair.fromRandom();
  return {
    'public': keypair.publicKey.toString(),
    'private': keypair.privateKey.toString(),
  };
}

String hashPassword(String password) {
  final bytes = utf8.encode(password);
  final digest = sha256.convert(bytes);
  return digest.toString();
}

// ── BLE direct-message encryption ───────────────────────────────────────
//
// Used only by the BLE fallback transport for 1:1 chat (see
// ble_direct_message_service.dart). RFCOMM, the primary transport, is a
// point-to-point socket and needs none of this; the BLE fallback rides
// ordinary advertisement names, which are a *public broadcast* readable by
// anyone with a generic BLE scanner, so a private message can't go out
// over it in the clear.
//
// HONEST LIMITS — this is deliberately modest, not a secure-messenger
// guarantee, and the code shouldn't imply otherwise:
//
//   * No authentication. There's no MAC/tag, so a message can be
//     tampered with (it'll decode to garbage) or spoofed by anyone who
//     can derive the key. Adding one would cost ~8-16 of the ~96 usable
//     bytes per message, which is a real tradeoff at this budget. The
//     rest of this app's BLE surface is unauthenticated too (only
//     Emergency Flare / Official Alert carry signatures), so this is
//     consistent rather than a new gap.
//   * A mutual contact can decrypt. The key is derived from the two
//     devices' rotating-ID seeds, and each device shares its seed with
//     every contact it chats with — so someone who is a contact of BOTH
//     participants holds both seeds and can derive their key. It stops a
//     stranger with a scanner, which is the actual threat here; it does
//     not stop a mutual friend.
//   * Forward secrecy: none. Seeds are long-lived, so a leaked seed pair
//     retroactively exposes past messages.
//
// The construction itself is HMAC-SHA256 in counter mode used as a
// keystream (the same shape as NIST SP 800-108's KDF-in-counter-mode),
// XORed against the plaintext — not an invented cipher, and built only
// from the already-vetted `crypto` package rather than pulling in an AES
// dependency for a ~96-byte payload. Its one hard requirement is that a
// (key, nonce) pair is NEVER reused: XOR keystream reuse across two
// messages leaks both. newDirectMessageNonce below is the only intended
// way to produce one.

const int kDirectMessageNonceBytes = 6;

/// Derives the symmetric key shared by exactly two devices, from their two
/// rotating-ID seeds. Order-independent by construction (the seeds are
/// sorted before mixing) so both ends derive the identical key without
/// having to agree on who is "first".
List<int> deriveSharedMeshKey(List<int> seedA, List<int> seedB) {
  final a = base64Encode(seedA);
  final b = base64Encode(seedB);
  final first = a.compareTo(b) <= 0 ? seedA : seedB;
  final second = a.compareTo(b) <= 0 ? seedB : seedA;
  // The domain-separation string keeps this key distinct from anything
  // else that might ever be derived from the same seeds.
  return Hmac(sha256, first)
      .convert([...second, ...utf8.encode('hops-dm-v1')])
      .bytes;
}

/// Fresh random nonce. Uses Random.secure() specifically — a predictable
/// nonce here would defeat the whole construction (see the reuse warning
/// above), and the default Random() is not seeded for that.
Uint8List newDirectMessageNonce() {
  final rng = Random.secure();
  return Uint8List.fromList(
      List<int>.generate(kDirectMessageNonceBytes, (_) => rng.nextInt(256)));
}

List<int> _keystream(List<int> key, List<int> nonce, int length) {
  final out = <int>[];
  var counter = 0;
  while (out.length < length) {
    out.addAll(Hmac(sha256, key)
        .convert([...nonce, counter & 0xFF, (counter >> 8) & 0xFF])
        .bytes);
    counter++;
  }
  return out.sublist(0, length);
}

/// Returns nonce || ciphertext — the nonce has to travel with the message
/// for the far end to reconstruct the same keystream, and it isn't secret.
Uint8List sealDirectMessage({
  required List<int> key,
  required String plaintext,
}) {
  final nonce = newDirectMessageNonce();
  final bytes = utf8.encode(plaintext);
  final ks = _keystream(key, nonce, bytes.length);
  return Uint8List.fromList([
    ...nonce,
    for (var i = 0; i < bytes.length; i++) bytes[i] ^ ks[i],
  ]);
}

/// Inverse of sealDirectMessage. Returns null on anything malformed —
/// including a payload encrypted for a different pair of devices, which
/// (with no auth tag, see the limits above) usually surfaces as invalid
/// UTF-8 rather than a clean "wrong key" signal.
String? openDirectMessage({
  required List<int> key,
  required List<int> sealed,
}) {
  if (sealed.length <= kDirectMessageNonceBytes) return null;
  final nonce = sealed.sublist(0, kDirectMessageNonceBytes);
  final ciphertext = sealed.sublist(kDirectMessageNonceBytes);
  final ks = _keystream(key, nonce, ciphertext.length);
  final plain = [
    for (var i = 0; i < ciphertext.length; i++) ciphertext[i] ^ ks[i],
  ];
  try {
    return utf8.decode(plain);
  } catch (_) {
    return null; // wrong key, or corrupted in flight
  }
}
