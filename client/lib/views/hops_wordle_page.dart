// lib/views/hops_wordle_page.dart
//
// Hops Wordle — one word a day, six guesses, no server. The word of the day
// is derived deterministically from the "Wordle day" (see _wordleDay — a
// calendar day that rolls over at 07:00 SAST rather than local midnight,
// since a hackathon crowd staying up past midnight expects the old word to
// still be live) AND the signed-in username (see wordleWordOfTheDay below),
// so every device for the SAME user lands on the same word, but two
// different users get two different words on the same day — deliberate, so
// one Hopper can't just tell a friend the answer and hand them an easy
// carrot reward. No server call is needed for any of this — consistent
// with the rest of this app's "no server data plane beyond identity"
// design (CLAUDE.md).
// Progress for today is persisted locally so leaving and reopening the app
// mid-puzzle resumes it rather than resetting; a streak (consecutive days
// WON, same convention the original Wordle uses) is tracked the same way.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/data/wordle_words.dart';
import 'package:client/data/wordle_valid_guesses.dart';
import 'package:client/services/carrot_wallet.dart';
import 'package:client/services/cosmetic_prefs.dart';
import 'package:client/theme/wordle_palettes.dart';
import 'package:client/views/hops_shop_page.dart';
import 'package:client/widgets/hops_background_pattern.dart';

const int _kMaxGuesses = 6;
const int _kWordLength = 5;

/// The fixed point every device's day-count is measured from — arbitrary,
/// just has to never change once this ships, or every device's word of the
/// day shifts out of sync with itself (today's word becomes yesterday's).
final DateTime _kWordleEpoch = DateTime(2024, 1, 1);

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// South Africa Standard Time is a fixed UTC+2 with no daylight-saving
/// shift, so it can be computed with plain arithmetic — no timezone
/// package/database needed.
const Duration _kSastOffset = Duration(hours: 2);

/// The "Wordle day" a given instant falls into, rolling over at 07:00 SAST
/// rather than local midnight. Computed off UTC (not DateTime.now()'s local
/// clock) so it's correct regardless of what timezone the device itself is
/// set to. Every place that used to compare/derive a plain calendar date
/// (word-of-the-day, today's storage key, streak continuity) goes through
/// this instead, so they all roll over at the same instant.
DateTime _wordleDay(DateTime at) {
  final sast = at.toUtc().add(_kSastOffset);
  final shifted = sast.subtract(const Duration(hours: 7)); // 07:00 → new "day"
  return DateTime(shifted.year, shifted.month, shifted.day);
}

/// Small stable string hash (FNV-1a, 32-bit) used to salt the word-of-the-day
/// index by username. Deliberately NOT Dart's built-in String.hashCode —
/// that's only guaranteed stable within a single run, not across app
/// versions/restarts, and this value gets baked into which word a user sees
/// today, so it has to reproduce identically every time.
int _stableStringHash(String s) {
  var hash = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// Deterministic word of the day for [username] on [at] (defaults to now).
/// Salting the day-index by a hash of the username means two different
/// users get two different words on the same calendar day — so telling a
/// friend "today's word is X" doesn't hand them a free win. Dart's `%`
/// always returns a non-negative result for a positive divisor, and
/// _stableStringHash is always non-negative, so this is safe for any date
/// relative to _kWordleEpoch.
String wordleWordOfTheDay(String username, [DateTime? at]) {
  final dayOnly = _wordleDay(at ?? DateTime.now());
  final days = dayOnly.difference(_kWordleEpoch).inDays;
  final salt = _stableStringHash(username.trim().toLowerCase());
  return kWordleWords[(days + salt) % kWordleWords.length];
}

enum TileState { empty, absent, present, correct }

/// Scores [guess] against [answer] using the standard two-pass algorithm —
/// exact matches first, then leftover-letter-frequency for present/absent,
/// so a repeated letter in the guess doesn't over-count against a target
/// that only has it once (the classic naive-Wordle-scorer bug).
List<TileState> scoreGuess(String guess, String answer) {
  final result = List<TileState>.filled(guess.length, TileState.absent);
  final remaining = <String, int>{};

  for (var i = 0; i < answer.length; i++) {
    final ch = answer[i];
    if (i < guess.length && guess[i] == ch) {
      result[i] = TileState.correct;
    } else {
      remaining[ch] = (remaining[ch] ?? 0) + 1;
    }
  }
  for (var i = 0; i < guess.length; i++) {
    if (result[i] == TileState.correct) continue;
    final ch = guess[i];
    final left = remaining[ch] ?? 0;
    if (left > 0) {
      result[i] = TileState.present;
      remaining[ch] = left - 1;
    }
  }
  return result;
}

class HopsWordlePage extends StatefulWidget {
  const HopsWordlePage({super.key});

  @override
  State<HopsWordlePage> createState() => _HopsWordlePageState();
}

class _HopsWordlePageState extends State<HopsWordlePage> {
  static const _prefsPrefix = 'hops_wordle_';
  static const _streakKey = '${_prefsPrefix}streak_v1';
  static const _bestStreakKey = '${_prefsPrefix}best_streak_v1';
  static const _lastWinDateKey = '${_prefsPrefix}last_win_date_v1';

  String _answer = '';
  String _todayKey = '';

  final List<String> _guesses = [];
  String _current = '';
  bool _over = false;
  bool _won = false;
  int _lastReward = 0;
  int _streak = 0;
  int _bestStreak = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    CarrotWallet.instance.load();
    CosmeticPrefs.instance.load();
    _loadState();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    // Self-fetched rather than passed in via the constructor — same
    // convention as the rest of this app's self-contained pages (see e.g.
    // chat_terminal.dart), and it's what makes per-user word salting
    // possible without threading a username through the whole feature
    // catalog's pageBuilder wiring.
    final username = prefs.getString('my_username') ?? 'Unknown_User';
    final now = DateTime.now();
    _answer = wordleWordOfTheDay(username, now);
    // Keyed by username too (not just date) — a shared device that's had
    // more than one Hops account signed into it should not show one
    // account's in-progress guesses/answer under a different account.
    // Keyed by _wordleDay (07:00 SAST rollover), not the raw calendar date —
    // otherwise the stored puzzle would still show "today" for hours after
    // wordleWordOfTheDay had already moved on to a new word.
    _todayKey =
        '$_prefsPrefix${_dateKey(_wordleDay(now))}_${_stableStringHash(username.trim().toLowerCase())}_v2';

    _streak = prefs.getInt(_streakKey) ?? 0;
    _bestStreak = prefs.getInt(_bestStreakKey) ?? 0;

    final raw = prefs.getString(_todayKey);
    if (raw != null) {
      try {
        final data = json.decode(raw) as Map<String, dynamic>;
        _guesses.addAll((data['guesses'] as List).cast<String>());
        _over = data['over'] as bool? ?? false;
        _won = data['won'] as bool? ?? false;
      } catch (_) {
        // Corrupt/old-shape entry — treat today as unplayed rather than crash.
      }
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _persistToday() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_todayKey, json.encode({
      'guesses': _guesses,
      'over': _over,
      'won': _won,
    }));
  }

  Map<String, TileState> get _keyStates {
    final states = <String, TileState>{};
    for (final guess in _guesses) {
      final scored = scoreGuess(guess, _answer);
      for (var i = 0; i < guess.length; i++) {
        final ch = guess[i];
        final existing = states[ch];
        // correct beats present beats absent — a letter that was ever
        // green anywhere should never downgrade back to yellow/grey.
        if (existing == TileState.correct) continue;
        if (existing == TileState.present && scored[i] != TileState.correct) continue;
        states[ch] = scored[i];
      }
    }
    return states;
  }

  void _onKeyTap(String key) {
    if (_over) return;
    if (key == '⌫') {
      if (_current.isNotEmpty) {
        setState(() => _current = _current.substring(0, _current.length - 1));
      }
      return;
    }
    if (key == 'ENTER') {
      _submitGuess();
      return;
    }
    if (_current.length < _kWordLength) {
      setState(() => _current += key.toLowerCase());
    }
  }

  void _submitGuess() {
    if (_current.length != _kWordLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not enough letters'), duration: Duration(seconds: 2)),
      );
      return;
    }
    // Checked against the full ~14.8k-word guess dictionary, NOT the small
    // curated answer list — those are deliberately different sizes (see
    // wordle_valid_guesses.dart's doc comment). Guessing against the small
    // list was the bug: common real words like "silly" aren't in the
    // hand-picked answer pool, so they got rejected even though they're
    // perfectly valid guesses.
    if (!kWordleValidGuesses.contains(_current)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not in word list'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final guess = _current;
    setState(() {
      _guesses.add(guess);
      _current = '';
    });

    if (guess == _answer) {
      setState(() {
        _over = true;
        _won = true;
      });
      _finishWin();
    } else if (_guesses.length >= _kMaxGuesses) {
      setState(() => _over = true);
      _finishLoss();
    } else {
      _persistToday();
    }
  }

  Future<void> _finishWin() async {
    // Fewer guesses = more carrots — 1 guess is worth 6, 6 guesses worth 1.
    // A generous top end on purpose: a first-guess win is rare enough (odds
    // are 1 in the list's size) that rewarding it richly costs nothing in
    // practice.
    _lastReward = (7 - _guesses.length).clamp(1, 6);

    final prefs = await SharedPreferences.getInstance();
    // Streak continuity is measured in _wordleDay units (07:00 SAST
    // rollover), same as the word/puzzle-key itself — comparing against a
    // raw calendar "yesterday" would falsely break a streak (or falsely
    // continue one) for anyone playing between midnight and 7am.
    final today = _wordleDay(DateTime.now());
    final yesterday = today.subtract(const Duration(days: 1));
    final lastWin = prefs.getString(_lastWinDateKey);
    // Streak continues only if yesterday was also a win — any gap (missed
    // day, or yesterday was a loss) starts a fresh streak at 1 rather than
    // carrying a broken chain forward.
    _streak = (lastWin == _dateKey(yesterday)) ? _streak + 1 : 1;
    _bestStreak = _streak > _bestStreak ? _streak : _bestStreak;

    await prefs.setInt(_streakKey, _streak);
    await prefs.setInt(_bestStreakKey, _bestStreak);
    await prefs.setString(_lastWinDateKey, _dateKey(today));
    await _persistToday();
    await CarrotWallet.instance.earn(_lastReward);
    if (mounted) setState(() {});
  }

  Future<void> _finishLoss() async {
    // A loss breaks the streak immediately, regardless of yesterday.
    _streak = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_streakKey, 0);
    await _persistToday();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hops Wordle'),
        actions: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: 'Tile palette',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HopsShopPage()),
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: CarrotWallet.instance.balance,
            builder: (context, balance, _) => Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Row(
                children: [
                  const Text('🥕', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 4),
                  Text(
                    CarrotWallet.debugUnlimitedCarrots ? '∞' : '$balance',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: HopsBackgroundPattern(
        child: SafeArea(
          child: ValueListenableBuilder<String>(
            valueListenable: CosmeticPrefs.instance.wordlePalette,
            builder: (context, paletteId, _) {
              final palette = WordlePalettes.byId(paletteId);
              return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.local_fire_department,
                            size: 18,
                            color: _streak > 0 ? Colors.orange : colors.onSurface.withValues(alpha: 0.3)),
                        const SizedBox(width: 4),
                        Text('Streak: $_streak', style: theme.textTheme.titleSmall),
                      ],
                    ),
                    Text('Best: $_bestStreak',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(color: colors.onSurface.withValues(alpha: 0.55))),
                  ],
                ),
              ),
              if (_over)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: _WordleResultBanner(colors: colors, won: _won, answer: _answer, reward: _lastReward),
                ),
              Expanded(child: Center(child: _buildGrid(colors, palette))),
              _buildKeyboard(colors, palette),
              const SizedBox(height: 8),
            ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(ColorScheme colors, WordlePalette palette) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_kMaxGuesses, (row) {
        String? letters;
        List<TileState>? states;
        if (row < _guesses.length) {
          letters = _guesses[row];
          states = scoreGuess(letters, _answer);
        } else if (row == _guesses.length && !_over) {
          letters = _current;
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_kWordLength, (col) {
              final ch = (letters != null && col < letters.length) ? letters[col] : '';
              final state = states != null ? states[col] : TileState.empty;
              return _buildTile(ch, state, colors, palette);
            }),
          ),
        );
      }),
    );
  }

  Widget _buildTile(String ch, TileState state, ColorScheme colors, WordlePalette palette) {
    Color bg;
    Color border;
    Color fg;
    switch (state) {
      case TileState.correct:
        bg = palette.correct;
        border = bg;
        fg = Colors.white;
        break;
      case TileState.present:
        bg = palette.present;
        border = bg;
        fg = Colors.white;
        break;
      case TileState.absent:
        bg = colors.onSurface.withValues(alpha: 0.25);
        border = bg;
        fg = Colors.white;
        break;
      case TileState.empty:
        bg = Colors.transparent;
        border = colors.onSurface.withValues(alpha: 0.25);
        fg = colors.onSurface;
        break;
    }
    return Container(
      width: 46,
      height: 46,
      margin: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        ch.toUpperCase(),
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: fg),
      ),
    );
  }

  Widget _buildKeyboard(ColorScheme colors, WordlePalette palette) {
    const rows = [
      ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
      ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
      ['ENTER', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '⌫'],
    ];
    final keyStates = _keyStates;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: rows.map((row) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: row.map((key) {
                final isWide = key == 'ENTER' || key == '⌫';
                final state = keyStates[key.toLowerCase()];
                Color bg;
                switch (state) {
                  case TileState.correct:
                    bg = palette.correct;
                    break;
                  case TileState.present:
                    bg = palette.present;
                    break;
                  case TileState.absent:
                    bg = colors.onSurface.withValues(alpha: 0.2);
                    break;
                  default:
                    bg = colors.surfaceContainerHighest;
                }
                final fg = state == null ? colors.onSurface : Colors.white;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Material(
                    color: bg,
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: _over ? null : () => _onKeyTap(key),
                      child: Container(
                        width: isWide ? 46 : 30,
                        height: 44,
                        alignment: Alignment.center,
                        child: Text(
                          key,
                          style: TextStyle(
                            fontSize: key.length > 1 ? 11 : 14,
                            fontWeight: FontWeight.bold,
                            color: fg,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// The win/loss summary shown above the grid once today's puzzle is over.
/// Deliberately NOT named HopsCard — that name is already the shared
/// design-system widget in lib/widgets/hops_card.dart, and this is a much
/// more specific, page-local banner, not a general-purpose surface.
class _WordleResultBanner extends StatelessWidget {
  final ColorScheme colors;
  final bool won;
  final String answer;
  final int reward;
  const _WordleResultBanner({
    required this.colors,
    required this.won,
    required this.answer,
    required this.reward,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (won ? Colors.green : Colors.redAccent).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(won ? Icons.emoji_events : Icons.sentiment_dissatisfied,
              color: won ? Colors.green.shade700 : Colors.redAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              won
                  ? "Solved! 🥕 +$reward carrots — come back tomorrow for a new word."
                  : "Out of guesses — today's word was ${answer.toUpperCase()}. Come back tomorrow.",
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
