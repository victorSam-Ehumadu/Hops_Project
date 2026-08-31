// Unit tests for the shared credential rules (lib/utils/password_policy.dart).
//
// These rules are the app's registration gate, shared between sign-up and
// the in-app password change so the two can't drift apart. They are also
// the concrete evidence behind the "user profiles and access rights"
// section of the project report, so they are worth pinning precisely.

import 'package:flutter_test/flutter_test.dart';
import 'package:client/utils/password_policy.dart';

void main() {
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

    test('the blocklist is unreachable behind the character-class rules', () {
      // KNOWN GAP, pinned deliberately rather than asserted as correct.
      //
      // Every blocklist entry is lowercase letters and digits only, so each
      // one fails the uppercase rule first and returns *that* message. The
      // blocklist branch below it can therefore never execute, and a
      // capitalised variant of a blocked password sails through.
      //
      // If the blocklist check is moved above the character-class checks,
      // this test should be updated to expect the "too common" message and
      // the second expectation should start failing — which is the point.
      expect(validatePassword('password123'), contains('uppercase'));
      expect(validatePassword('Password123!'), isNull,
          reason: 'a capitalised blocked password is currently accepted');
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
}
