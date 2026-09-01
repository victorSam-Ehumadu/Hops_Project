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
// Scope, honestly: this is a blunt word-list matcher, not real content
// moderation. It catches plain, undisguised bad words on whole-word
// boundaries and nothing cleverer — it won't catch leetspeak, deliberate
// spacing, or anything context-dependent, and a word list can never be
// complete. It's a basic decency filter for accidental/casual profanity,
// not a guarantee against a determined user, the same honest limitation
// this app already states for Community Chat/Lost & Found moderation
// generally (see report_content.dart) — the Report button is still the
// real backstop for anything worse.
const List<String> kProfanityWordList = [
  // Common English profanity — kept to a standard, widely-recognized set
  // rather than an exhaustive list, to stay maintainable.
  'fuck', 'fucker', 'fucking', 'motherfucker',
  'shit', 'bullshit', 'shitty',
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

/// True if [text] contains anything the filter would censor — useful where
/// a caller wants to warn/block rather than silently rewrite (not used by
/// every call site; most just censor silently, same as a game chat filter).
bool containsProfanity(String text) => _profanityPattern.hasMatch(text);
