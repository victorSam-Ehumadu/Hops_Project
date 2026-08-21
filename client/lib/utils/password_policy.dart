// Shared password/username rules — used by both sign-up (auth_screen.dart)
// and the in-app "Change Password" flow (account_management_screen.dart)
// so the two can never drift out of sync with each other.

// Username: short enough to fit BLE's tight name budgets (advertisement
// names are capped at 29 bytes total, and a chunk of that is always taken
// by prefixes like "HPS:"/"EMG:" — see hops_constants.dart), long enough
// to actually be distinctive. 3-20 keeps real names/handles comfortable
// while forcing some minimum variety over just "a", "1", etc.
const int kMinUsernameLength = 3;
const int kMaxUsernameLength = 20;

const int kMinPasswordLength = 8;
// No legitimate password needs to be this long — this exists to reject
// someone pasting an arbitrarily large blob (a script, a file's contents)
// into the field before it ever reaches hashing/network code. It is NOT
// what stops that blob from being treated as SQL: nothing typed into any
// field in this app is ever concatenated into a query string. Every write
// this app makes goes through a Supabase RPC call with named, typed
// parameters (see supabase/migrations/*.sql) — Postgres binds those as
// data, never as code, the same structural guarantee a parameterized query
// gives you in any other stack. A password field containing the text
// "'; DROP TABLE profiles; --" is just a password that happens to look
// like SQL; it gets hashed like any other string and the server never
// interprets it as a command.
const int kMaxPasswordLength = 128;

/// Null return means valid. Checked in this order so the first thing a
/// user needs to fix is also the first thing they're told about.
String? validateUsername(String username) {
  final trimmed = username.trim();
  if (trimmed.isEmpty) return "Please enter a username.";
  if (trimmed.length < kMinUsernameLength) {
    return "Username must be at least $kMinUsernameLength characters.";
  }
  if (trimmed.length > kMaxUsernameLength) {
    return "Username must be $kMaxUsernameLength characters or fewer.";
  }
  if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(trimmed)) {
    return "Username can only contain letters, numbers, and underscores.";
  }
  return null;
}

final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

String? validateEmail(String email) {
  final trimmed = email.trim();
  if (trimmed.isEmpty) return "Please enter your email address.";
  if (!_emailPattern.hasMatch(trimmed)) {
    return "That doesn't look like a valid email address.";
  }
  return null;
}

// Deliberately exact (case-insensitive) matches against the single most
// common leaked/guessed passwords, rather than trying to be a full
// dictionary check — this catches the "12345678"/"password1" class of
// password that a complexity rule alone (which "Password1!" would satisfy)
// completely misses, without needing a network call or a bundled
// multi-megabyte wordlist.
const List<String> _weakPasswordBlocklist = [
  '12345678', '123456789', '1234567890', 'password', 'password1',
  'password123', 'qwerty123', 'qwertyuiop', 'letmein123', 'iloveyou',
  '11111111', '00000000', 'abc12345', 'admin1234', 'welcome123',
  'monkey123', 'football1', 'dragon123', 'master123', 'login1234',
  'starwars1', 'sunshine1', 'princess1', 'trustno1', 'passw0rd',
  'changeme', 'letmein1', 'freedom1', 'whatever1', 'qazwsx123',
];

/// Returns a user-facing reason the password is rejected, or null if it
/// passes every rule. Checked cheapest-first.
String? validatePassword(String password) {
  if (password.length < kMinPasswordLength) {
    return "Password must be at least $kMinPasswordLength characters.";
  }
  if (password.length > kMaxPasswordLength) {
    return "Password must be $kMaxPasswordLength characters or fewer.";
  }
  if (!RegExp(r'[A-Z]').hasMatch(password)) {
    return "Password must include at least one uppercase letter.";
  }
  if (!RegExp(r'[a-z]').hasMatch(password)) {
    return "Password must include at least one lowercase letter.";
  }
  if (!RegExp(r'[0-9]').hasMatch(password)) {
    return "Password must include at least one number.";
  }
  if (!RegExp(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]~`;/\\]').hasMatch(password)) {
    return "Password must include at least one symbol (e.g. !@#\$%).";
  }
  if (_weakPasswordBlocklist.contains(password.toLowerCase())) {
    return "That password is far too common — please choose something less guessable.";
  }
  return null;
}

enum PasswordStrength { veryWeak, weak, fair, strong, veryStrong }

/// A rough 0-4 strength score for the visual meter — NOT the same thing as
/// validatePassword's pass/fail rule check above (a password can score
/// "fair" here while still failing a hard requirement, e.g. missing a
/// symbol) — this is meant to encourage going beyond the bare minimum,
/// not to replace the hard rules.
PasswordStrength scorePasswordStrength(String password) {
  if (password.isEmpty) return PasswordStrength.veryWeak;
  if (_weakPasswordBlocklist.contains(password.toLowerCase())) {
    return PasswordStrength.veryWeak;
  }

  var score = 0;
  if (password.length >= kMinPasswordLength) score++;
  if (password.length >= 12) score++;
  if (RegExp(r'[A-Z]').hasMatch(password) && RegExp(r'[a-z]').hasMatch(password)) score++;
  if (RegExp(r'[0-9]').hasMatch(password)) score++;
  if (RegExp(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]~`;/\\]').hasMatch(password)) score++;

  switch (score) {
    case 0:
    case 1:
      return PasswordStrength.veryWeak;
    case 2:
      return PasswordStrength.weak;
    case 3:
      return PasswordStrength.fair;
    case 4:
      return PasswordStrength.strong;
    default:
      return PasswordStrength.veryStrong;
  }
}
