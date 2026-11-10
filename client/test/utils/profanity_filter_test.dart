// The profanity filter, and specifically the two ways it can be wrong.
//
// A filter has two failure modes and they pull in opposite directions.
// Letting abuse through is the obvious one. The other is refusing honest
// text, and in a campus SAFETY app that is the more damaging of the two: a
// student who cannot file a report because of where they are standing has
// been failed by the thing meant to protect them.
//
// Both halves are pinned here. The over-blocking group is not padding —
// 'cunt' really was in the substring list and really did reject
// "Scunthorpe", which is the textbook example of this bug, and this file
// is what caught it.
import 'package:flutter_test/flutter_test.dart';
import 'package:client/utils/profanity_filter.dart';

void main() {
  group('catches the plain cases', () {
    for (final s in ['shit', 'FUCK', 'bitch', 'asshole', 'nigger']) {
      test('"$s"', () => expect(containsProfanity(s), isTrue));
    }
  });

  group('catches evasion the first version missed', () {
    // The original filter was a bare \b word-boundary regex and its own
    // header admitted it caught none of these.
    const cases = {
      'sh1t': 'digit for letter',
      'f@ck': 'symbol for letter, leaving no vowel',
      'a55hole': 'digits mid-word',
      'f u c k': 'spaced out',
      'xxfuckxx': 'padded either side',
      'n1gger': 'digit for letter in a slur',
      'b!tch': 'symbol for letter',
    };
    cases.forEach((input, why) {
      test('"$input" ($why)', () => expect(containsProfanity(input), isTrue));
    });
  });

  group('does NOT refuse honest text', () {
    // Each of these contains a listed term as a substring. Every one of
    // them is something a student could plausibly type into Lost & Found,
    // a report or a chat message.
    const cases = [
      'class',
      'classic',
      'classroom',
      'assassin',
      'assignment',
      'assessment',
      'grape',
      'Scunthorpe',
      'Meet at Scunthorpe Hall',
      'analysis',
      'passage',
      'bass',
      'cockpit',
      'Essex',
      'Dickinson',
      'shiitake',
      'I lost my glasses in the classroom',
      'Submitting my assignment at the help desk',
    ];
    for (final s in cases) {
      test('"$s"', () => expect(containsProfanity(s), isFalse,
          reason: 'Over-blocking honest text is the worse failure here.'));
    }
  });

  group('empty and whitespace are not profane', () {
    for (final s in ['', '   ', '\n']) {
      test('${s.isEmpty ? '(empty)' : '(blank)'}',
          () => expect(containsProfanity(s), isFalse));
    }
  });

  group('censorProfanity keeps the text usable', () {
    test('masks a word with one asterisk per character', () {
      expect(censorProfanity('that is shit'), 'that is ****');
    });

    test('leaves honest text alone', () {
      expect(censorProfanity('the classroom'), 'the classroom');
    });

    test('is deliberately laxer than containsProfanity', () {
      // Censoring rewrites text that is going out either way, so it stays
      // on the plain pattern — an asterisk run always lines up with the
      // characters it replaced. The strict check is for text that gets
      // REFUSED, where catching "sh1t" is what matters.
      expect(containsProfanity('sh1t'), isTrue);
      expect(censorProfanity('sh1t'), 'sh1t');
    });
  });

  group('usernames built from an email address', () {
    // validateUsername already rejects '@' and '.', so a literal address
    // cannot be registered. This catches the same address wearing
    // underscores, which otherwise rides the BLE advertisement name to
    // everyone in range.
    for (final s in ['victor_gmail_com', 'victorgmailcom', 'me_yahoo_co_za',
                     'someone_outlook_com']) {
      test('"$s" is refused', () => expect(looksLikeEmailAddress(s), isTrue));
    }

    // A provider token alone is not an address — the TLD has to follow it.
    for (final s in ['victor', 'gmailuser', 'mailroom', 'Macon', 'coder',
                     'proton_fan', 'mail']) {
      test('"$s" is allowed', () => expect(looksLikeEmailAddress(s), isFalse));
    }
  });
}
