// What the user is told when sign-in, sign-up or a moderation check fails.
//
// Worth testing because the failure mode is invisible: a wrong message
// still looks like a working app, and the specific bug these were written
// for — a mistyped email reporting "something went wrong on our end" —
// survived a long time precisely because nothing broke.
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:client/utils/auth_error_messages.dart';
import 'package:client/utils/password_policy.dart';

const _generic = 'Something went wrong on our end';

void main() {
  group('things the user can actually fix must not blame the server', () {
    test('a null/cast failure reads as bad credentials', () {
      // The reported bug. fetchPasswordSaltForEmail threw a TypeError when
      // the salt lookup returned null — which happens on a wrong email,
      // the most common sign-in mistake there is — and no branch matched.
      final msg = describeAuthException(
          TypeError().toString() +
              " type 'Null' is not a subtype of type 'String'");
      expect(msg, isNot(contains(_generic)));
      expect(msg.toLowerCase(), contains("don't match"));
    });

    test('a dropped connection says so', () {
      expect(describeAuthException('ClientException: Connection closed'),
          isNot(contains(_generic)));
    });

    test('no internet says so', () {
      final msg = describeAuthException('SocketException: Failed host lookup');
      expect(msg, isNot(contains(_generic)));
      expect(msg.toLowerCase(), contains('internet'));
    });

    test('rate limiting says to wait', () {
      final msg = describeAuthException('429 rate limit exceeded');
      expect(msg, isNot(contains(_generic)));
      expect(msg.toLowerCase(), contains('too many'));
    });

    test('a reserved username explains itself', () {
      final msg = describeAuthException('username_reserved');
      expect(msg.toLowerCase(), contains('reserved'));
    });

    test('a taken username explains itself', () {
      expect(describeAuthException('username_taken').toLowerCase(),
          contains('already taken'));
    });

    test('a non-institutional email names the required domain', () {
      final msg = describeAuthException('email_domain_not_allowed');
      expect(msg, contains(kInstitutionalEmailDomain));
    });

    test('missing migrations are called a setup issue, not user error', () {
      final msg = describeAuthException(
          'PostgrestException: function public.foo does not exist');
      expect(msg.toLowerCase(), contains('setup'));
    });
  });

  group('moderation verdicts are distinguished', () {
    test('a ban is called a ban, not a suspension', () {
      // Calling a permanent removal "suspended" invites someone to wait
      // out something that will never lapse instead of appealing.
      final msg = describeAuthException(
          PostgrestException(message: 'account_banned', details: 'Abuse'));
      expect(msg.toLowerCase(), contains('banned'));
      expect(msg, contains('Abuse'));
    });

    test('a suspension names its expiry', () {
      final msg = describeAuthException(PostgrestException(
          message: 'account_suspended', details: '2026-11-04 — Spam'));
      expect(msg.toLowerCase(), contains('suspended'));
      expect(msg, contains('2026-11-04'));
      expect(msg, contains('Spam'));
    });

    test('a suspension with no detail still reads sensibly', () {
      final msg = describeAuthException(
          PostgrestException(message: 'account_suspended'));
      expect(msg.toLowerCase(), contains('suspended'));
      expect(msg, isNot(contains('null')));
    });

    test('details being a non-String does not throw', () {
      // `details` is typed dynamic; a blind cast used to throw from inside
      // the very handler whose job is to explain the failure.
      expect(
        () => describeAuthException(PostgrestException(
            message: 'account_banned', details: {'not': 'a string'})),
        returnsNormally,
      );
    });
  });

  group('credentials stay deliberately collapsed', () {
    test('wrong password and unknown account give the SAME message', () {
      // Enumeration resistance. Two different messages would turn the
      // sign-in form into an account-existence oracle for a campus safety
      // app. The server collapses these too (0008/0009/0018) — splitting
      // them here would discard that at the last step.
      final a = describeAuthException('invalid_credentials');
      final b = describeAuthException(
          "type 'Null' is not a subtype of type 'String'");
      expect(a, equals(b),
          reason: 'these two must be indistinguishable to the user');
    });

    test('neither mentions whether the account exists', () {
      for (final input in ['invalid_credentials', '28000', '28P01']) {
        final msg = describeAuthException(input).toLowerCase();
        expect(msg, isNot(contains('no such')));
        expect(msg, isNot(contains('not found')));
        expect(msg, isNot(contains('does not exist')));
      }
    });
  });

  group('email send failures', () {
    test('a quota says it is temporary', () {
      final msg = describeEmailSendFailure('quota_exceeded');
      expect(msg.toLowerCase(), contains('limit'));
      expect(msg.toLowerCase(), contains('later'));
    });

    test('an unverified sender is called a setup issue', () {
      final msg = describeEmailSendFailure('sender_not_verified');
      expect(msg.toLowerCase(), contains("isn't set up"));
      expect(msg.toLowerCase(), contains('not something you did'));
    });

    test('the skip hint is appended when offered', () {
      final msg = describeEmailSendFailure('quota_exceeded',
          skipHint: ' You can Skip for now.');
      expect(msg, endsWith('You can Skip for now.'));
    });

    test('an unknown code still produces something non-technical', () {
      final msg = describeEmailSendFailure('something_new');
      expect(msg, isNotEmpty);
      expect(msg, isNot(contains('something_new')));
    });
  });

  test('no message ever leaks a raw exception string', () {
    // Better to say less than to show "PostgrestException(message: ...,
    // code: 23505, details: ...)" to a student.
    for (final input in [
      'PostgrestException(message: boom, code: 42P01)',
      'FormatException: oops',
      'random nonsense',
    ]) {
      final msg = describeAuthException(input);
      expect(msg, isNot(contains('Exception')));
      expect(msg, isNot(contains('code:')));
    }
  });
}
