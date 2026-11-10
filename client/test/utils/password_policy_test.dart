// Unit tests for the shared credential rules (lib/utils/password_policy.dart).
//
// These rules are the app's registration gate, shared between sign-up and
// the in-app password change so the two can't drift apart. They are also
// the concrete evidence behind the "user profiles and access rights"
// section of the project report, so they are worth pinning precisely.

import 'package:flutter_test/flutter_test.dart';
import 'package:client/utils/password_policy.dart';

void main() {
  group('usernames that look like an email address', () {
    // The character class already rejects '@' and '.', so the only way an
    // address gets through is with its punctuation swapped out — and the
    // username rides the BLE advertisement name to everyone in range.
    test('an address wearing underscores is refused', () {
      expect(validateUsername('victor_gmail_com'), isNotNull);
      expect(validateUsername('me_yahoo_co_za'), isNotNull);
    });

    test('a literal address was already impossible', () {
      // Belt and braces: if the character class is ever loosened, this
      // fails rather than silently admitting addresses again.
      expect(validateUsername('victor@gmail.com'), isNotNull);
    });

    test('an ordinary name containing a provider word is allowed', () {
      expect(validateUsername('gmailuser'), isNull);
      expect(validateUsername('mailroom'), isNull);
    });
  });

  group('usernames containing profanity', () {
    test('are refused, including leetspeak', () {
      expect(validateUsername('fucker'), isNotNull);
      expect(validateUsername('sh1thead'), isNotNull);
    });

    test('but an ordinary name containing a listed term is not', () {
      // Same Scunthorpe reasoning as profanity_filter_test.dart.
      expect(validateUsername('classic'), isNull);
      expect(validateUsername('Cassidy'), isNull);
    });
  });

  group('student number prefixes at signup', () {
    test('an allowed prefix on the institutional domain passes', () {
      for (final p in kAllowedStudentNumberPrefixes) {
        expect(validateAccountEmail('${p}12345$kInstitutionalEmailDomain'), isNull,
            reason: 'prefix $p should be accepted');
      }
    });

    test('a wrong prefix is refused, and the message says so', () {
      final err = validateAccountEmail('39912345$kInstitutionalEmailDomain');
      expect(err, isNotNull);
      // The complaint must be about the PREFIX, not the domain — the
      // domain is correct here, and telling them otherwise sends them
      // looking at the wrong half of their own address.
      expect(err, contains('399'));
      expect(err!.toLowerCase(), isNot(contains('ending in')));
    });

    test('the wrong domain is still reported as a domain problem', () {
      final err = validateAccountEmail('40212345@gmail.com');
      expect(err, isNotNull);
      expect(err, contains(kInstitutionalEmailDomain));
    });

    test('the test allowlist bypasses both checks', () {
      // Those addresses have no student number at all. They must keep
      // working until the list is emptied for launch.
      for (final addr in kTestEmailAllowlist) {
        expect(validateAccountEmail(addr), isNull);
      }
    });

    test('the wording lists exactly the prefixes that are enforced', () {
      // Guards the drift where a prefix is added to the list but the
      // message still names the old set.
      final err = validateAccountEmail('39912345$kInstitutionalEmailDomain')!;
      for (final p in kAllowedStudentNumberPrefixes) {
        expect(err, contains(p));
      }
    });
  });

  group('validateUsername', () {
    test('accepts an ordinary username', () {
      expect(validateUsername('Kwame123'), isNull);
      expect(validateUsername('a_b_c'), isNull);
    });

    test('rejects an empty username', () {
      expect(validateUsername(''), isNotNull);
      expect(validateUsername('   '), isNotNull);
    });

    test('enforces the minimum length', () {
      expect(validateUsername('ab'), isNotNull);
      expect(validateUsername('abc'), isNull);
    });

    test('enforces the maximum length', () {
      // The ceiling exists because the username rides BLE advertisement
      // names, where the whole payload is capped at a few dozen bytes.
      expect(validateUsername('a' * kMaxUsernameLength), isNull);
      expect(validateUsername('a' * (kMaxUsernameLength + 1)), isNotNull);
    });

    test('measures length after trimming', () {
      expect(validateUsername('  abc  '), isNull);
      expect(validateUsername('  ab  '), isNotNull);
    });

    test('rejects characters that would confuse the wire format', () {
      // ':' separates fields in every advertisement prefix, and non-ASCII
      // costs multiple bytes against a budget measured in bytes.
      expect(validateUsername('vic:tor'), isNotNull);
      expect(validateUsername('vic tor'), isNotNull);
      expect(validateUsername('café99'), isNotNull);
      expect(validateUsername('vic-tor'), isNotNull);
    });

    test('reports the first problem the user needs to fix', () {
      // Ordered so the message names the most immediate issue.
      expect(validateUsername('ab'), contains('at least'));
      expect(validateUsername('ab cd'), contains('letters, numbers'));
    });
  });

  group('validateEmail', () {
    test('accepts an ordinary address', () {
      expect(validateEmail('student@campus.ac.za'), isNull);
    });

    test('rejects an empty address', () {
      expect(validateEmail(''), isNotNull);
    });

    test('rejects addresses missing structural parts', () {
      expect(validateEmail('student'), isNotNull);
      expect(validateEmail('student@campus'), isNotNull);
      expect(validateEmail('@campus.ac.za'), isNotNull);
      expect(validateEmail('student@.za'), isNotNull);
      expect(validateEmail('student @campus.ac.za'), isNotNull);
    });

    test('trims surrounding whitespace before validating', () {
      expect(validateEmail('  student@campus.ac.za  '), isNull);
    });
  });

  group('validatePassword', () {
    test('accepts a password meeting every rule', () {
      expect(validatePassword('Str0ng!pass'), isNull);
    });

    test('enforces the minimum length', () {
      expect(validatePassword('Ab1!def'), isNotNull);
      expect(validatePassword('Ab1!defg'), isNull);
    });

    test('enforces the maximum length', () {
      // Not a strength rule — it stops an arbitrarily large blob reaching
      // the hashing and network path.
      final long = 'Ab1!${'x' * (kMaxPasswordLength - 4)}';
      expect(validatePassword(long), isNull);
      expect(validatePassword('${long}x'), isNotNull);
    });

    test('requires each character class', () {
      expect(validatePassword('str0ng!pass'), contains('uppercase'));
      expect(validatePassword('STR0NG!PASS'), contains('lowercase'));
      expect(validatePassword('Strong!pass'), contains('number'));
      expect(validatePassword('Str0ngpass'), contains('symbol'));
    });

    test('treats a password that looks like SQL as an ordinary password', () {
      // Nothing typed into this app is concatenated into a query — every
      // write goes through a Supabase RPC with named, typed parameters. A
      // password that looks like an injection is just a password.
      expect(validatePassword("'; DROP TABLE profiles; --Ab1"), isNull);
    });

    test('accepts a long passphrase with the required classes', () {
      expect(validatePassword('Correct horse battery staple 7!'), isNull);
    });
  });

  group('validatePassword — common-password blocklist', () {
    // The blocklist exists to catch the "password1" class that a pure
    // complexity rule would wave through.
    test('rejects every entry on the blocklist', () {
      for (final weak in const [
        'password', 'password1', 'password123', 'qwerty123',
        '12345678', 'iloveyou', 'passw0rd', 'trustno1',
      ]) {
        expect(validatePassword(weak), isNotNull,
            reason: '"$weak" must never be accepted');
      }
    });

    test('is reached before the character-class rules', () {
      // Regression guard. These entries are lowercase letters and digits,
      // so if the blocklist check ever moves back below the character-class
      // checks the uppercase rule fires first and this message changes —
      // which is exactly the bug this ordering fixed. Following the advice
      // in that older message ("add a capital letter") produced an accepted
      // password.
      expect(validatePassword('password123'), contains('too common'));
      expect(validatePassword('qwertyuiop'), contains('too common'));
    });

    test('is not defeated by capitalising and appending a symbol', () {
      // The two decorations people reach for first when a complexity rule
      // rejects their password. Neither produces a meaningfully different
      // password, so neither may produce a different verdict.
      expect(validatePassword('Password123!'), contains('too common'));
      expect(validatePassword('Password1!'), contains('too common'));
      expect(validatePassword('!Iloveyou1'), contains('too common'));
    });

    test('sees through common character substitutions', () {
      // 0/o, 1/i, 3/e, @/a, $/s. 'passw0rd' is itself on the list; the
      // point here is that the fold reaches it from several directions.
      expect(validatePassword('P@ssw0rd1'), contains('too common'));
      expect(validatePassword('Passw0rd!'), contains('too common'));
    });

    test('does not over-block an ordinary strong password', () {
      // The substring match is deliberately aggressive, so these guard the
      // other side of the trade — none of them contains a blocklist entry
      // once folded.
      expect(validatePassword('Str0ng!pass'), isNull);
      expect(validatePassword('Correct horse battery staple 7!'), isNull);
      expect(validatePassword('Ab1!defg'), isNull);
    });
  });

  group('scorePasswordStrength', () {
    test('scores an empty password at the floor', () {
      expect(scorePasswordStrength(''), PasswordStrength.veryWeak);
    });

    test('catches blocked passwords regardless of their composition', () {
      // Here the blocklist is checked first, so it actually fires.
      expect(scorePasswordStrength('password123'), PasswordStrength.veryWeak);
      expect(scorePasswordStrength('qwertyuiop'), PasswordStrength.veryWeak);
    });

    test('rises with length and character variety', () {
      expect(scorePasswordStrength('abc'), PasswordStrength.veryWeak);
      expect(scorePasswordStrength('Ab1!aaaa'), PasswordStrength.strong);
      expect(scorePasswordStrength('Ab1!aaaaaaaa'), PasswordStrength.veryStrong);
    });

    test('is a nudge, not the gate — it can score a failing password', () {
      // Documented divergence: this password scores "fair" while
      // validatePassword still rejects it for having no symbol.
      expect(scorePasswordStrength('Abcdefgh1'), PasswordStrength.fair);
      expect(validatePassword('Abcdefgh1'), isNotNull);
    });

    test('covers every strength band', () {
      final seen = <PasswordStrength>{
        scorePasswordStrength(''),
        scorePasswordStrength('abc'),
        scorePasswordStrength('abcdefgh'),
        scorePasswordStrength('Abcdefgh'),
        scorePasswordStrength('Ab1!aaaa'),
        scorePasswordStrength('Ab1!aaaaaaaa'),
      };
      expect(seen.length, greaterThanOrEqualTo(4));
    });
  });

  group('validateAccountEmail (institutional domain)', () {
    test('accepts a Richfield student address', () {
      expect(validateAccountEmail('40212345@my.richfield.ac.za'), isNull);
    });

    test('accepts it case-insensitively', () {
      // Signup lowercases before storing, so rejecting on case here would
      // refuse an address the server would happily accept.
      expect(validateAccountEmail('40212345@My.Richfield.AC.ZA'), isNull);
    });

    test('rejects an outside domain', () {
      final err = validateAccountEmail('victor@gmail.com');
      expect(err, isNotNull);
      expect(err, contains(kInstitutionalEmailDomain));
    });

    test('rejects a lookalike domain that merely contains it', () {
      // The check is endsWith, not contains — otherwise
      // my.richfield.ac.za.attacker.com would pass.
      expect(validateAccountEmail('x@my.richfield.ac.za.example.com'),
          isNotNull);
    });

    test('still applies the ordinary format rules first', () {
      expect(validateAccountEmail('not-an-email'), isNotNull);
      expect(validateAccountEmail(''), isNotNull);
    });

    test('honours the test allowlist', () {
      // The allowlist ships empty; this pins the mechanism so that
      // emptying it for release cannot silently disable it instead.
      for (final allowed in kTestEmailAllowlist) {
        expect(validateAccountEmail(allowed), isNull,
            reason: '$allowed is on the allowlist and must be accepted');
      }
    });

    test('the allowlist holds full addresses, never bare domains', () {
      // A bare '@gmail.com' entry would reopen signup to everyone, which
      // is the entire thing the restriction exists to prevent.
      for (final allowed in kTestEmailAllowlist) {
        expect(allowed.startsWith('@'), isFalse,
            reason: '$allowed looks like a domain, not an address');
        expect(allowed, contains('@'));
        expect(allowed, equals(allowed.toLowerCase()),
            reason: 'comparison is lowercased, so entries must be too');
      }
    });
  });

  group('validateEmail stays generic', () {
    test('accepts a non-institutional address', () {
      // Load-bearing: forgot-password uses this, and accounts created
      // before the restriction have outside addresses. Tightening this
      // would lock every legacy account out of password recovery.
      expect(validateEmail('legacy@gmail.com'), isNull);
    });
  });
}
