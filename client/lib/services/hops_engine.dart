// lib/services/hops_engine.dart
//
// Hops the bunny — the app's offline assistant, and the scorer behind
// "which neighbour should I relay through?".
//
// Everything here works with the radio off and no Supabase reachable, which
// is the whole point: the one moment a campus safety app most needs to
// answer "what do I do about a burn" is the moment the network is gone.
//
// Two independent subsystems, deliberately kept in one place because they
// share a lifecycle (load once, live for the process) and nothing else:
//
//   1. askBunny()          — keyword lookup over assets/data/hops_knowledge.json
//   2. getSmartRouteScore() — optional TFLite model, heuristic when absent
//
// Both degrade to something useful rather than throwing. A missing model
// file is an expected state, not an error.
//
// NOT here: any large-language-model path. An earlier draft loaded
// `gemma-2b-it.bin` through `Interpreter.fromAsset` — that cannot work.
// tflite_flutter reads .tflite FlatBuffers (a Gemma .bin is MediaPipe/GGUF),
// Interpreter.run() takes numeric tensors rather than prompt strings, and a
// ~2GB model in assets/ lands inside the APK against a 200MB base-module
// limit. On-device Gemma needs flutter_gemma/MediaPipe with a runtime
// download. Left out entirely rather than stubbed, so nothing in this file
// pretends to be an LLM.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Reserved username for the built-in assistant. Every user has this as a
/// contact from first launch (see hops_app.dart's _refreshContactsTrayList),
/// so it must never collide with a real account — sign-up rejects it, and
/// nothing on the BLE mesh ever advertises under this name.
const String kHopsBotUsername = 'Hops';

/// Names nobody may sign up under, because a real account holding one would
/// be indistinguishable from the built-in assistant: bot history is stored
/// in the same local `messages` table keyed by peer username, so their
/// messages would interleave with Hops' own, under the same name.
///
/// Must stay in sync with is_reserved_username() in
/// supabase/migrations/0014_reserve_bot_usernames.sql. That one is the
/// enforcement; this one exists so the error appears instantly as the user
/// types instead of after a round trip they may not have signal for.
const List<String> kReservedUsernames = [
  'hops',
  'hopsbot',
  'hops bot',
  'hops_bot',
  'hops-bot',
];

bool isReservedUsername(String username) =>
    kReservedUsernames.contains(username.trim().toLowerCase());

/// One row of hops_knowledge.json, parsed once at load instead of being
/// re-read out of a `List<dynamic>` on every keystroke.
class _KnowledgeEntry {
  final List<String> keywords;
  final String response;

  const _KnowledgeEntry(this.keywords, this.response);
}

class HopsEngine {
  HopsEngine._();

  /// Singleton — the knowledge base is a file read and the interpreter is a
  /// native handle. Both are process-lifetime resources, and the previous
  /// shape (a plain class) re-parsed the JSON every time a screen built one.
  static final HopsEngine instance = HopsEngine._();

  static const String _knowledgeAsset = 'assets/data/hops_knowledge.json';
  static const String _routingModelAsset = 'assets/models/routing_model.tflite';

  final FlutterTts _tts = FlutterTts();
  final Random _random = Random();

  List<_KnowledgeEntry> _knowledge = const [];
  Interpreter? _routingInterpreter;
  Future<void>? _initFuture;

  /// True once init() has finished, whether or not every optional piece
  /// loaded. Check the two below to find out what actually came up.
  bool get isReady => _initFuture != null && _knowledgeLoadAttempted;
  bool _knowledgeLoadAttempted = false;

  /// Number of entries actually parsed. Zero means the asset is missing or
  /// malformed and every answer will be a generic fallback — worth
  /// surfacing rather than silently reporting "ready", which is what the
  /// earlier version did by setting its ready flag inside the catch block.
  int get knowledgeEntryCount => _knowledge.length;

  /// False when routing scores are coming from the hand-written heuristic
  /// because assets/models/routing_model.tflite isn't bundled.
  bool get usingRoutingModel => _routingInterpreter != null;

  /// Safe to call repeatedly and from anywhere — the work happens once and
  /// every later caller awaits the same future. askBunny() and
  /// getSmartRouteScore() both call it themselves, so there's no
  /// initialise-me-first ordering requirement at app start.
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    await _loadKnowledgeBase();
    await _configureVoice();
    await _loadRoutingModel();
  }

  // ── Knowledge base ─────────────────────────────────────────────────────

  Future<void> _loadKnowledgeBase() async {
    try {
      final raw = await rootBundle.loadString(_knowledgeAsset);
      final decoded = json.decode(raw) as List<dynamic>;
      _knowledge = decoded
          .map((e) {
            final map = e as Map<String, dynamic>;
            final keywords = (map['keywords'] as List<dynamic>)
                .map((k) => k.toString().toLowerCase().trim())
                .where((k) => k.isNotEmpty)
                .toList(growable: false);
            return _KnowledgeEntry(keywords, map['response'].toString());
          })
          .where((entry) => entry.keywords.isNotEmpty)
          .toList(growable: false);
      debugPrint('HopsEngine: knowledge base loaded (${_knowledge.length} entries)');
    } catch (e) {
      // Left empty on purpose. askBunny() still answers, just always with a
      // fallback line, and knowledgeEntryCount == 0 says why.
      _knowledge = const [];
      debugPrint('HopsEngine: knowledge base failed to load — $e');
    } finally {
      _knowledgeLoadAttempted = true;
    }
  }

  // ── Chat ───────────────────────────────────────────────────────────────

  Future<String> askBunny(String query) async {
    await init();
    return _searchKnowledgeBase(query);
  }

  /// Word-boundary keyword scoring.
  ///
  /// The obvious implementation — `query.toLowerCase().contains(keyword)` —
  /// is substring matching, which misfires badly on this data set:
  /// "you're cute" contains "cut" and returns bleeding-wound first aid;
  /// "why is it so slow" contains "low" and returns the battery tip; "hi"
  /// matches *this*, *which*, *machine*. Worse, those all resolved by
  /// array order (first entry with the top score won), so JSON ordering
  /// silently decided which answer a user got.
  ///
  /// Instead the query is tokenised and keywords must match a whole token,
  /// with a short suffix tolerance so "burns"/"burned" still find "burn".
  /// Multi-word keywords ("save energy") are matched against the normalised
  /// query as a phrase.
  String _searchKnowledgeBase(String query) {
    final normalised = _normalise(query);
    if (normalised.isEmpty) return _randomFallback();

    final tokens = normalised.split(' ').toSet();
    // Padded so a phrase can be found on word boundaries at either end.
    final phraseHaystack = ' $normalised ';

    _KnowledgeEntry? best;
    int bestScore = 0;

    for (final entry in _knowledge) {
      int score = 0;
      for (final keyword in entry.keywords) {
        final matched = keyword.contains(' ')
            ? phraseHaystack.contains(' $keyword ')
            : tokens.any((t) => _tokenMatches(t, keyword));
        if (!matched) continue;
        // Specificity beats count: a hit on "save energy" (2 words, 11
        // chars) outranks a hit on the generic "low", so the entry that
        // actually understood the question wins ties it used to lose.
        score += keyword.split(' ').length * 10 + keyword.length;
      }
      if (score > bestScore) {
        bestScore = score;
        best = entry;
      }
    }

    if (best == null) return _randomFallback();
    return best.response;
  }

  /// Lowercase, strip punctuation, collapse whitespace. Apostrophes are
  /// dropped rather than spaced so "you're" tokenises as "youre" instead of
  /// splitting into a stray "re".
  String _normalise(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r"['’]"), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();

  /// Exact token match, plus up to three trailing characters for simple
  /// inflections: burn→burns/burned/burning, bleed→bleeding,
  /// connect→connected.
  ///
  /// Three, not two, because "-ing" is the form people actually type in the
  /// case that matters most — "someone is bleeding" has to reach the
  /// bleeding-wound entry, and at a tolerance of two it silently fell
  /// through to a generic fallback instead.
  ///
  /// The `keyword.length >= 4` guard is what keeps the suffix tolerance
  /// from re-introducing the bug it sits next to: without it, "cut" would
  /// once again swallow "cute" and "hop" would swallow "hoping".
  bool _tokenMatches(String token, String keyword) {
    if (token == keyword) return true;
    if (keyword.length < 4) return false;
    final extra = token.length - keyword.length;
    return extra > 0 && extra <= 3 && token.startsWith(keyword);
  }

  /// Shown when nothing matched. Several of these point at the capability
  /// list, because "I didn't understand" is exactly the moment someone
  /// needs to know what the assistant *does* cover — that nudge used to
  /// live in a catch-all knowledge entry keyed on "how do i" / "can i",
  /// which meant it outscored the specific answers to most real questions
  /// and swallowed them.
  static const List<String> _fallbacks = [
    "Oh my whiskers! That's a tricky one 🐰 Say \"yes\" and I'll show you the list of things I do know about.",
    "Hmm... I don't have a carrot for that one yet 🥕 Try different words, or say \"yes\" for the list of what I cover.",
    "Well, well, well — that's a new one! 🐇 I'm a simple bunny; say \"yes\" and I'll show you my whole repertoire.",
    "Oh! Not sure about that one, but I'm always hoppy to chat. Ask me about the app, a feature, or first aid 🐰",
    "You know what? I'll have to do some hopping research 🐰 Meanwhile, say \"yes\" for what I can actually help with.",
    "Carrots! I don't know that one, but I'll give you a fluffy hug instead 🥕 Try rephrasing?",
    "That went right over my ears — and mine are enormous 🐰 Say \"yes\" for the list of things I'm good at.",
  ];

  /// Actually random. The previous `millisecondsSinceEpoch % length` looked
  /// random but returned the same line for every call inside the same
  /// millisecond and walked the list in step with the clock.
  String _randomFallback() => _fallbacks[_random.nextInt(_fallbacks.length)];

  /// Opening line for a brand-new conversation with the bot.
  ///
  /// Ends by offering the capability list rather than listing everything
  /// up front: a wall of bullet points is the fastest way to make someone
  /// close a chat. The "yes" is a real keyword — the capabilities entry in
  /// hops_knowledge.json matches on yes/yeah/sure/what can you do, so the
  /// offer isn't decorative.
  String get greeting =>
      "Oh, hello there! I'm Hops 🐰\n\n"
      "I live right here on your phone, so I work with no signal at all. "
      "I can explain how Hops works, walk you through any feature, help out "
      "in an emergency, or just chat nonsense about carrots.\n\n"
      "Want a list of what I can help with? Just say yes.";

  // ── Voice ──────────────────────────────────────────────────────────────

  Future<void> _configureVoice() async {
    try {
      await _tts.setPitch(1.1);
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(0.8);

      // Prefer a local en-ZA/en-GB voice. "network" voices sound better but
      // need a connection — exactly what this app can't assume — so they're
      // taken only as a last resort before the plain language fallback.
      final voices = await _tts.getVoices as List<dynamic>?;
      Map<String, String>? offline;
      Map<String, String>? online;

      for (final voice in voices ?? const []) {
        if (voice is! Map) continue;
        final name = voice['name']?.toString();
        final locale = voice['locale']?.toString();
        if (name == null || locale == null) continue;
        final lower = '$name $locale'.toLowerCase();
        if (!lower.contains('en-za') && !lower.contains('en-gb')) continue;
        final candidate = {'name': name, 'locale': locale};
        if (lower.contains('network')) {
          online ??= candidate;
        } else {
          offline ??= candidate;
        }
      }

      final chosen = offline ?? online;
      if (chosen != null) {
        await _tts.setVoice(chosen);
        debugPrint('HopsEngine: voice set to ${chosen['name']}');
      } else {
        await _tts.setLanguage('en-ZA');
      }
    } catch (e) {
      debugPrint('HopsEngine: voice setup failed, using device default — $e');
    }
  }

  Future<void> bunnyTalk(String text) async {
    await init();
    try {
      await _tts.stop(); // don't stack utterances if tapped repeatedly
      await _tts.speak(text);
    } catch (e) {
      debugPrint('HopsEngine: speak failed — $e');
    }
  }

  Future<void> stopTalking() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing was speaking, or the engine is gone. Either way, done.
    }
  }

  // ── Smart routing ──────────────────────────────────────────────────────

  Future<void> _loadRoutingModel() async {
    try {
      _routingInterpreter = await Interpreter.fromAsset(_routingModelAsset);
      debugPrint('HopsEngine: routing model loaded');
    } catch (e) {
      // Expected until someone trains and drops in the model — the
      // heuristic below is a complete implementation, not a placeholder.
      _routingInterpreter = null;
      debugPrint('HopsEngine: no routing model, using heuristic — $e');
    }
  }

  /// Relay desirability for a neighbour, roughly 0..1 — higher is a better
  /// hop. Falls back to the heuristic whenever the model is absent or
  /// throws, so callers never need to care which one answered.
  double getSmartRouteScore(int rssi, int battery) {
    final interpreter = _routingInterpreter;
    if (interpreter == null) return _reliabilityHeuristic(rssi, battery);

    try {
      final input = [
        [(rssi + 100) / 70.0, battery / 100.0]
      ];
      final output = List.filled(1, 0.0).reshape([1, 1]);
      interpreter.run(input, output);
      return (output[0][0] as num).toDouble();
    } catch (e) {
      debugPrint('HopsEngine: routing inference failed, using heuristic — $e');
      return _reliabilityHeuristic(rssi, battery);
    }
  }

  /// Signal matters more than charge: a strong link on a half-flat phone
  /// still delivers, a weak link on a full one drops packets. Clamped
  /// because RSSI regularly falls outside the -100..-30 range this maps.
  double _reliabilityHeuristic(int rssi, int battery) {
    final signal = ((rssi + 100) / 70).clamp(0.0, 1.0);
    final charge = (battery / 100).clamp(0.0, 1.0);
    return (signal * 0.6) + (charge * 0.4);
  }

  /// Releases the native interpreter. Only meaningful on desktop/test
  /// teardown — on mobile the process dying reclaims it anyway.
  Future<void> dispose() async {
    await stopTalking();
    _routingInterpreter?.close();
    _routingInterpreter = null;
  }
}
