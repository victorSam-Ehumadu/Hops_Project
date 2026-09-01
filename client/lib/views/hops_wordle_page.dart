// lib/views/hops_wordle_page.dart
//
// Hops Wordle — five letters, six guesses, no server. Two modes, chosen
// from the segmented control at the top of the page:
//
//   Daily     — one word per "Wordle day" (see _wordleDay: a calendar day
//               that rolls over at 07:00 SAST rather than local midnight,
//               since a hackathon crowd staying up past midnight expects
//               the old word to still be live), salted per user so two
//               Hoppers get different words on the same day. Progress is
//               persisted, a win/loss streak is tracked, and a win pays
//               out carrots. This is the mode that existed before.
//   Unlimited — a fresh random word whenever you want one. Deliberately
//               pays NO carrots (see _finishRound): the wallet backs real
//               purchases in the Hops Shop, and an endlessly repeatable
//               puzzle would let anyone mint an unbounded balance in an
//               afternoon. It also can't touch the daily streak, for the
//               same reason. Lifetime played/won counts are kept so the
//               mode still has something to show for itself.
//
// The word of the day is derived deterministically from the Wordle day AND
// the signed-in username (see wordleWordOfTheDay), so every device for the
// SAME user lands on the same word, but two different users get two
// different words on the same day — deliberate, so one Hopper can't just
// tell a friend the answer and hand them an easy carrot reward. No server
// call is needed for any of this — consistent with the rest of this app's
// "no server data plane beyond identity" design (CLAUDE.md).
import 'dart:convert';
import 'dart:math';
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

/// Which of the two puzzles the page is currently showing. Both exist at
/// once in memory (see _HopsWordlePageState._rounds) so flipping between
/// them mid-puzzle doesn't throw either one's guesses away.
enum WordleMode { daily, unlimited }

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

/// One in-progress (or finished) puzzle. Pulled out of the State's own
/// fields so Daily and Unlimited can each hold a complete, independent
/// board — switching modes is then just swapping which one is rendered,
/// with no save/restore dance and nothing to lose track of.
class _WordleRound {
  String answer;
  final List<String> guesses = [];
  String current = '';
  bool over = false;
  bool won = false;
  int reward = 0;

  _WordleRound(this.answer);

  /// Per-letter keyboard colouring. correct beats present beats absent — a
  /// letter that was ever green anywhere should never downgrade back to
  /// yellow/grey.
  Map<String, TileState> get keyStates {
    final states = <String, TileState>{};
    for (final guess in guesses) {
      final scored = scoreGuess(guess, answer);
      for (var i = 0; i < guess.length; i++) {
        final ch = guess[i];
        final existing = states[ch];
        if (existing == TileState.correct) continue;
        if (existing == TileState.present && scored[i] != TileState.correct) {
          continue;
        }
        states[ch] = scored[i];
      }
    }
    return states;
  }
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
  // Lifetime Unlimited tallies. Separate keys (not folded into the streak
  // ones) so an Unlimited session can never disturb the daily streak — see
  // this file's header comment.
  static const _unlimitedPlayedKey = '${_prefsPrefix}unlimited_played_v1';
  static const _unlimitedWonKey = '${_prefsPrefix}unlimited_won_v1';

  final _random = Random();

  WordleMode _mode = WordleMode.daily;
  final Map<WordleMode, _WordleRound> _rounds = {};

  String _todayKey = '';
  int _streak = 0;
  int _bestStreak = 0;
  int _unlimitedPlayed = 0;
  int _unlimitedWon = 0;
  bool _loaded = false;

  _WordleRound get _round => _rounds[_mode]!;
  bool get _isDaily => _mode == WordleMode.daily;

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
    final daily = _WordleRound(wordleWordOfTheDay(username, now));
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
    _unlimitedPlayed = prefs.getInt(_unlimitedPlayedKey) ?? 0;
    _unlimitedWon = prefs.getInt(_unlimitedWonKey) ?? 0;

    final raw = prefs.getString(_todayKey);
    if (raw != null) {
      try {
        final data = json.decode(raw) as Map<String, dynamic>;
        daily.guesses.addAll((data['guesses'] as List).cast<String>());
        daily.over = data['over'] as bool? ?? false;
        daily.won = data['won'] as bool? ?? false;
      } catch (_) {
        // Corrupt/old-shape entry — treat today as unplayed rather than crash.
      }
    }

    _rounds[WordleMode.daily] = daily;
    // Unlimited is built up-front rather than lazily on first switch, so
    // the mode toggle never has a frame where there's no board to render.
    // Nothing about it is persisted: it's practice, and restoring a
    // half-finished random word across app launches would just be a puzzle
    // you no longer remember starting.
    _rounds[WordleMode.unlimited] = _WordleRound(_randomWord());

    if (mounted) setState(() => _loaded = true);
  }

  String _randomWord() => kWordleWords[_random.nextInt(kWordleWords.length)];

  /// Only the daily puzzle is written to disk — see _rounds' comment above.
  Future<void> _persistToday() async {
    final daily = _rounds[WordleMode.daily];
    if (daily == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _todayKey,
        json.encode({
          'guesses': daily.guesses,
          'over': daily.over,
          'won': daily.won,
        }));
  }

  void _onKeyTap(String key) {
    final round = _round;
    if (round.over) return;
    if (key == '⌫') {
      if (round.current.isNotEmpty) {
        setState(() => round.current =
            round.current.substring(0, round.current.length - 1));
      }
      return;
    }
    if (key == 'ENTER') {
      _submitGuess();
      return;
    }
    if (round.current.length < _kWordLength) {
      setState(() => round.current += key.toLowerCase());
    }
  }

  void _submitGuess() {
    final round = _round;
    if (round.current.length != _kWordLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Not enough letters'),
            duration: Duration(seconds: 2)),
      );
      return;
    }
    // Checked against the full ~14.8k-word guess dictionary, NOT the small
    // curated answer list — those are deliberately different sizes (see
    // wordle_valid_guesses.dart's doc comment). Guessing against the small
    // list was the bug: common real words like "silly" aren't in the
    // hand-picked answer pool, so they got rejected even though they're
    // perfectly valid guesses.
    if (!kWordleValidGuesses.contains(round.current)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Not in word list'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final guess = round.current;
    setState(() {
      round.guesses.add(guess);
      round.current = '';
    });

    if (guess == round.answer) {
      setState(() {
        round.over = true;
        round.won = true;
      });
      _finishRound(won: true);
    } else if (round.guesses.length >= _kMaxGuesses) {
      setState(() => round.over = true);
      _finishRound(won: false);
    } else if (_isDaily) {
      _persistToday();
    }
  }

  /// End-of-puzzle bookkeeping. Everything with a lasting consequence —
  /// carrots, the streak, the saved board — is daily-only; Unlimited just
  /// bumps its own play/win tallies. See this file's header comment for why
  /// the payout isn't shared.
  Future<void> _finishRound({required bool won}) async {
    final prefs = await SharedPreferences.getInstance();

    if (!_isDaily) {
      _unlimitedPlayed++;
      if (won) _unlimitedWon++;
      await prefs.setInt(_unlimitedPlayedKey, _unlimitedPlayed);
      await prefs.setInt(_unlimitedWonKey, _unlimitedWon);
      if (mounted) setState(() {});
      return;
    }

    if (!won) {
      // A loss breaks the streak immediately, regardless of yesterday.
      _streak = 0;
      await prefs.setInt(_streakKey, 0);
      await _persistToday();
      if (mounted) setState(() {});
      return;
    }

    // Fewer guesses = more carrots — 1 guess is worth 6, 6 guesses worth 1.
    // A generous top end on purpose: a first-guess win is rare enough (odds
    // are 1 in the list's size) that rewarding it richly costs nothing in
    // practice.
    final round = _round;
    round.reward = (7 - round.guesses.length).clamp(1, 6);

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
    await CarrotWallet.instance.earn(round.reward);
    if (mounted) setState(() {});
  }

  /// Unlimited only — deals a fresh word into a brand new board. Daily has
  /// no equivalent by design; that's the entire distinction between the two
  /// modes.
  void _newUnlimitedRound() {
    setState(() => _rounds[WordleMode.unlimited] = _WordleRound(_randomWord()));
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
              final round = _round;
              return Column(
                children: [
                  _buildModeSelector(colors),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                    child: _isDaily
                        ? _buildStatRow(
                            theme,
                            colors,
                            leadingIcon: Icons.local_fire_department,
                            leadingIconColor: _streak > 0
                                ? Colors.orange
                                : colors.onSurface.withValues(alpha: 0.3),
                            leadingLabel: 'Streak: $_streak',
                            trailingLabel: 'Best: $_bestStreak',
                          )
                        : _buildStatRow(
                            theme,
                            colors,
                            leadingIcon: Icons.all_inclusive,
                            leadingIconColor: colors.primary,
                            leadingLabel: 'Solved: $_unlimitedWon',
                            trailingLabel: 'Played: $_unlimitedPlayed',
                          ),
                  ),
                  if (round.over)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 4),
                      child: _WordleResultBanner(
                        colors: colors,
                        won: round.won,
                        answer: round.answer,
                        reward: round.reward,
                        isDaily: _isDaily,
                        onPlayAgain: _isDaily ? null : _newUnlimitedRound,
                      ),
                    ),
                  Expanded(
                      child: Center(child: _buildGrid(round, colors, palette))),
                  _buildKeyboard(round, colors, palette),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The one-line stats strip above the board. Same shape in both modes —
  /// only the numbers behind it differ — so the grid never shifts vertically
  /// when you switch.
  Widget _buildStatRow(
    ThemeData theme,
    ColorScheme colors, {
    required IconData leadingIcon,
    required Color leadingIconColor,
    required String leadingLabel,
    required String trailingLabel,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(leadingIcon, size: 18, color: leadingIconColor),
            const SizedBox(width: 4),
            Text(leadingLabel, style: theme.textTheme.titleSmall),
          ],
        ),
        Text(
          trailingLabel,
          style: theme.textTheme.titleSmall
              ?.copyWith(color: colors.onSurface.withValues(alpha: 0.55)),
        ),
      ],
    );
  }

  /// Two-up segmented control. Switching is instant and lossless — both
  /// boards live in _rounds, so a half-finished daily puzzle is exactly
  /// where you left it when you switch back.
  Widget _buildModeSelector(ColorScheme colors) {
    Widget tab(WordleMode mode, IconData icon, String label) {
      final selected = _mode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: selected ? null : () => setState(() => _mode = mode),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: selected ? colors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 15,
                    color: selected
                        ? colors.onPrimary
                        : colors.onSurface.withValues(alpha: 0.6)),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: selected
                        ? colors.onPrimary
                        : colors.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Row(
          children: [
            tab(WordleMode.daily, Icons.today_outlined, 'Daily'),
            tab(WordleMode.unlimited, Icons.all_inclusive, 'Unlimited'),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(
      _WordleRound round, ColorScheme colors, WordlePalette palette) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_kMaxGuesses, (row) {
        String? letters;
        List<TileState>? states;
        if (row < round.guesses.length) {
          letters = round.guesses[row];
          states = scoreGuess(letters, round.answer);
        } else if (row == round.guesses.length && !round.over) {
          letters = round.current;
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_kWordLength, (col) {
              final ch =
                  (letters != null && col < letters.length) ? letters[col] : '';
              final state = states != null ? states[col] : TileState.empty;
              return _buildTile(ch, state, colors, palette);
            }),
          ),
        );
      }),
    );
  }

  Widget _buildTile(
      String ch, TileState state, ColorScheme colors, WordlePalette palette) {
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

  Widget _buildKeyboard(
      _WordleRound round, ColorScheme colors, WordlePalette palette) {
    const rows = [
      ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
      ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
      ['ENTER', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '⌫'],
    ];
    final keyStates = round.keyStates;
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
                      onTap: round.over ? null : () => _onKeyTap(key),
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

/// The win/loss summary shown above the grid once a puzzle is over.
/// Deliberately NOT named HopsCard — that name is already the shared
/// design-system widget in lib/widgets/hops_card.dart, and this is a much
/// more specific, page-local banner, not a general-purpose surface.
///
/// [onPlayAgain] is non-null only in Unlimited; Daily has nothing to offer
/// but the wait until tomorrow, so it gets no button at all rather than a
/// disabled one.
class _WordleResultBanner extends StatelessWidget {
  final ColorScheme colors;
  final bool won;
  final String answer;
  final int reward;
  final bool isDaily;
  final VoidCallback? onPlayAgain;
  const _WordleResultBanner({
    required this.colors,
    required this.won,
    required this.answer,
    required this.reward,
    required this.isDaily,
    this.onPlayAgain,
  });

  String get _message {
    if (isDaily) {
      return won
          ? "Solved! 🥕 +$reward carrots — come back tomorrow for a new word."
          : "Out of guesses — today's word was ${answer.toUpperCase()}. Come back tomorrow.";
    }
    // No carrots here on purpose — said plainly rather than left as a silent
    // omission the player has to notice and then wonder about.
    return won
        ? "Solved in practice mode — no carrots, but no streak lost either."
        : "Out of guesses — the word was ${answer.toUpperCase()}.";
  }

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
              _message,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          if (onPlayAgain != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: onPlayAgain,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('New word'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
