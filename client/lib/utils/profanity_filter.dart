// lib/utils/profanity_filter.dart
//
// A lightweight, fully offline profanity filter — consistent with this
// app's "no server data plane beyond identity" design (CLAUDE.md), there's
// no moderation API to call out to, so this runs identically on every
// device against a fixed, bundled word list. Applied at the point free
// text is about to be shown to OTHER people: profile fields (nickname/
// bio/thinking status — edit_identity_screen.dart), chat messages
// (chat_terminal.dart), and the freeform text in Lost & Found/Study Bunny
// Finder/Vibe Check.
//
// Scope, honestly: this is a word-list matcher, not real content
// moderation. A word list can never be complete and nothing here is
// context-aware, so the Report button remains the real backstop — the same
// honest limitation this app already states for Community Alerts and Lost
// & Found moderation generally (see report_content.dart).
//
// It DOES now catch leetspeak and deliberate spacing, which the first
// version of this file explicitly did not. containsProfanity folds the
// text the way password_policy.dart folds a password — lowercase, then
// 0/1/3/4/5/7/@/$/! mapped back to letters — so "sh1t", "f@ck" and
// "a s s h o l e" all reduce to a listed term. censorProfanity is
// deliberately left on the plain whole-word pattern; see its own note.
//
// WHOLE WORDS, NOT SUBSTRINGS. password_policy's blocklist matches by
// substring because over-blocking a password costs one retry. Over-blocking
// a MESSAGE costs somebody the ability to say something true, and naive
// substring matching is how filters come to reject "class", "assassin",
// "grape" and "Scunthorpe". In a campus safety app, a student who cannot
// report an incident at Scunthorpe Hall is a real failure. So the folded
// check below compares whole tokens, with one short exception list for
// terms no innocent English word contains.
const List<String> kProfanityWordList = [
  // Common English profanity — kept to a standard, widely-recognized set
  // rather than an exhaustive list, to stay maintainable.
  'fuck', 'fucker', 'fucking', 'motherfucker',
  'shit', 'bullshit', 'shitty', 'shithead',
  'bitch', 'bitches',
  'asshole', 'ass',
  'bastard',
  'damn', 'goddamn',
  'crap',
  'dick', 'dickhead',
  'piss', 'pissed',
  'cunt',
  'whore', 'slut',
  'cock',
  'twat',
  'wanker',
  'douche', 'douchebag',
  'prick',
  'retard', 'retarded',
  // Common slurs — censored on sight rather than listed euphemistically;
  // a campus safety app's own Terms already prohibit harassment (section
  // 3), and slurs are exactly the kind of "bad word" that matters most to
  // actually catch.
  'nigger', 'nigga',
  'faggot', 'fag',
  'spic', 'chink', 'gook', 'kike', 'tranny',
];

final RegExp _profanityPattern = RegExp(
  r'\b(' + kProfanityWordList.map(RegExp.escape).join('|') + r')\b',
  caseSensitive: false,
);

/// Replaces every whole-word match from [kProfanityWordList] in [text]
/// with asterisks of the same length (so "shit" → "****", not a fixed-
/// width mask) — preserves the sentence's shape/length rather than
/// collapsing it, which reads more naturally and doesn't leak the word's
/// length as a puzzle either way (asterisks-per-letter is the standard,
/// expected convention for this, same as most chat filters).
String censorProfanity(String text) {
  if (text.isEmpty) return text;
  return text.replaceAllMapped(_profanityPattern, (match) => '*' * match.group(0)!.length);
}

/// Folds one token to the form the list is compared against.
///
/// Same substitution scheme as password_policy.dart's _foldForBlocklist,
/// because the evasion being defended against is identical.
String _fold(String word) => word
    .toLowerCase()
    .replaceAll('@', 'a')
    .replaceAll(r'$', 's')
    .replaceAll('!', 'i')
    .replaceAll('0', 'o')
    .replaceAll('1', 'i')
    .replaceAll('3', 'e')
    .replaceAll('4', 'a')
    .replaceAll('5', 's')
    .replaceAll('7', 't')
    .replaceAll(RegExp(r'[^a-z]'), '');

final Set<String> _foldedWords =
    kProfanityWordList.map(_fold).where((w) => w.isNotEmpty).toSet();

/// Terms matched anywhere in the collapsed text, not just as whole words.
///
/// This catches padded evasion ("xxfuckxx") and spacing ("f u c k"), which
/// whole-token matching misses once separators are gone.
///
/// EVERY ENTRY HERE MUST NOT APPEAR INSIDE AN INNOCENT WORD, and that is
/// not a theoretical caution — 'cunt' was in this list and it rejected
/// "Scunthorpe", the canonical example of this exact bug, caught by the
/// test that exists for it. A campus safety app that refuses a report from
/// Scunthorpe Hall has failed at its actual job. 'cunt' is therefore
/// whole-word only, via kProfanityWordList above.
///
/// Before adding anything here, check it against a dictionary. If an
/// ordinary word contains it, it belongs in kProfanityWordList instead.
const List<String> _alwaysSubstring = [
  'fuck', 'nigger', 'nigga', 'faggot', 'motherfucker', 'asshole',
];

final List<String> _foldedSubstrings =
    _alwaysSubstring.map(_fold).where((w) => w.isNotEmpty).toList(growable: false);

/// True if [text] contains anything the filter considers profane.
///
/// Stricter than [censorProfanity], on purpose. This is the gate for text
/// that is REFUSED — a username, a post that will not be sent — where
/// catching "sh1t" matters. Censoring rewrites text that is going out
/// either way and keeps the plain pattern, so an asterisk run always lines
/// up with the characters it replaced.
bool containsProfanity(String text) {
  if (text.trim().isEmpty) return false;
  if (_profanityPattern.hasMatch(text)) return true;

  final tokens = text
      .split(RegExp(r'[^A-Za-z0-9@$!]+'))
      .map(_fold)
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  for (final token in tokens) {
    if (_foldedWords.contains(token)) return true;
  }

  final joined = tokens.join();
  for (final term in _foldedSubstrings) {
    if (joined.contains(term)) return true;
  }

  // Vowel-dropped forms: "f@ck" folds to "fck", "sh!t" to "shit" (fine)
  // but "b!tch" to "bitch" (fine) while "fck"/"cnt" match nothing above.
  // Dropping vowels from BOTH sides makes the comparison fair, and this
  // runs only over _alwaysSubstring — whose entries are safe inside longer
  // words — so it cannot resurrect the Scunthorpe problem.
  final devowelled = joined.replaceAll(RegExp(r'[aeiou]'), '');
  for (final term in _foldedSubstrings) {
    final bare = term.replaceAll(RegExp(r'[aeiou]'), '');
    // Guard against a term that is all vowels or too short to be
    // distinctive once stripped — "ass" becomes "ss", which would match
    // "classic". Three consonants is the floor.
    if (bare.length >= 3 && devowelled.contains(bare)) return true;
  }
  return false;
}

/// Mail-provider and domain fragments that give away a username built from
/// an email address with its punctuation removed.
///
/// validateUsername already rejects every character an address needs —
/// '@' and '.' are both outside [A-Za-z0-9_] — so a literal address cannot
/// be registered. What it cannot see is "victor_gmail_com", the same
/// address wearing underscores, which then rides the BLE advertisement
/// name to everyone in range.
const List<String> _mailProviders = [
  'gmail', 'yahoo', 'hotmail', 'outlook', 'icloud', 'protonmail', 'proton',
  'aol', 'zoho', 'gmx', 'yandex', 'mail',
];

const List<String> _mailTlds = ['com', 'net', 'org', 'co', 'za', 'edu', 'ac'];

/// True if [username] reads as an email address with its punctuation
/// swapped out.
///
/// Requires a provider token AND a TLD immediately after it, so "gmailuser"
/// and "mailroom" are both fine while "victor_gmail_com" is not. Without
/// that adjacency any name containing "co" and "mail" anywhere would trip.
bool looksLikeEmailAddress(String username) {
  final folded = username.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (folded.isEmpty) return false;
  for (final provider in _mailProviders) {
    final at = folded.indexOf(provider);
    if (at < 0) continue;
    final rest = folded.substring(at + provider.length);
    for (final tld in _mailTlds) {
      if (rest.startsWith(tld)) return true;
    }
  }
  return false;
}
