# 4.8 Security and Backup Design

## 4.8.1 Scope and assets

Hops is offline-first. Almost all of its data never reaches a server at all, and that
architectural fact does more for the system's security posture than any control described
below. Establishing what actually needs protecting therefore comes first.

**Server-side assets (Supabase, PostgreSQL).** Eight tables, holding identity and moderation
state only:

| Table | Holds | Sensitivity |
|---|---|---|
| `profiles` | username, email, salted password hash, salt, session token, RSA public key, role | High |
| `admin_actions_log` | audit trail of every moderator action | High (integrity) |
| `content_reports` | user-submitted reports of content and behaviour | High |
| `email_verification_otps` | one-time codes, attempt counters, expiry | High (short-lived) |
| `password_reset_otps` | one-time codes, attempt counters, expiry | High (short-lived) |
| `official_alerts_log` | record of admin-issued campus alerts | Medium (integrity) |
| `user_notifications` | moderation outcomes delivered to a user | Medium |
| `admin_requests` | pending requests for elevated privilege | High |

**On-device assets.** Everything else: the message log and relay queue, vibe records, tasks and
contact profiles (SQLite via `sqflite`), and small state in `SharedPreferences` (session token,
avatar path, enabled features, carrot balance, cosmetics, game progress). Additionally, the
device's **RSA private key**, held in `flutter_secure_storage`.

**Assets deliberately not held anywhere central.** Chat content, location or proximity history,
friend graphs, emergency-flare content, and Lost & Found entries. There is no server-side data
plane; peer features operate entirely over local Bluetooth. A total compromise of the Supabase
project would therefore expose account records and moderation history, but would not expose a
single message, a single flare, or any record of who was near whom.

## 4.8.2 Access control design

### The problem the design responds to

Supabase ships an anonymous API key inside the client application. In Hops that key is in
`client/.env` and is present in every installed copy of the app. It must therefore be treated as
public knowledge, not as a credential.

By default, Supabase grants full privileges on new public-schema tables to the `anon` and
`authenticated` roles. Before migration `0001_lockdown_profiles.sql`, this meant that anyone
extracting the key from the APK held direct `SELECT`, `INSERT`, `UPDATE`, `DELETE` and `TRUNCATE`
on `profiles` — including the password hash and session token columns.

Row Level Security alone cannot resolve this. The original sign-in flow issued
`select().eq('username', x)` and compared the hash on the client. Any policy permissive enough to
return that row is equally permissive when the same query is issued with no filter at all.

### The design adopted: deny-all plus a function surface

The database is configured so that no table is reachable directly, and every operation is a
named, typed, server-side procedure.

| Control | Count | Effect |
|---|---|---|
| Tables with RLS enabled | 8 (all) | Non-owner roles are denied by default |
| `CREATE POLICY` statements | **0** | Nothing re-opens that default |
| `SECURITY DEFINER` functions | 65 | The entire permitted operation set |
| `REVOKE` statements | 74 | Default grants explicitly withdrawn |
| `GRANT EXECUTE` statements | 61 | Each function opened deliberately |

RLS enabled with zero policies is a deny-all posture, not an oversight. The client cannot read
`profiles`; it calls `signin_hops_user`, which runs with the definer's privileges, performs the
comparison server-side, and returns only the safe subset of columns. The password hash goes in
and never comes back out.

Where genuinely public data is required — the public-key directory used for Emergency Flare
signature verification — it is exposed through a narrowed view, `profiles_public`, projecting
only `{id, username, public_key}`. Nothing sensitive is reachable through it.

Every function additionally sets `search_path = public`, which prevents a `search_path`
manipulation attack against a `SECURITY DEFINER` routine.

This structure also removes SQL injection as a category rather than mitigating it: no user input
is ever concatenated into a query. Every write is an RPC call with named, typed parameters.

### Authentication

- **Password storage.** Passwords are hashed on the client before transmission, so the plaintext
  never reaches the server — a deliberate rule inherited from `0001`. Migration
  `0018_salted_password_hashing.sql` added a per-account salt; because the client hashes first,
  the server cannot salt on the client's behalf, so the client requests the (non-secret) salt
  before hashing.
- **Enumeration resistance.** A salt lookup for an unregistered email returns a deterministic,
  salt-shaped value derived from the email itself, rather than an error or an empty string.
  Sign-in errors are collapsed to a single message. Neither step reveals whether an account
  exists, and repeated lookups for the same absent email return the same value, so variation
  across calls does not leak either.
- **Backward compatibility.** Pre-migration accounts carry `password_salt = ''`, which the
  hashing helper treats as a no-op prefix. Existing hashes keep matching; a real salt is adopted
  at the next password change.
- **One-time codes.** Both OTP flows (email verification, password reset) expire after 24 hours
  and lock after **5 failed attempts**, bounding both brute force and the lifetime of a stale
  code.
- **Sessions.** A rotating `hops_token` is issued on sign-in and stored in `SharedPreferences`.

### Key management

Each device generates an RSA keypair at sign-up. The public key is stored in `profiles` and
distributed to peers through the key directory; the private key is written to
`flutter_secure_storage` (backed by the Android Keystore) and is **never transmitted after
generation**. It signs Emergency Flares and Official Alerts, which is what allows a receiving
device to verify that an alert genuinely originated from the claimed sender — including while
completely offline, since verification needs only the cached public key.

### Privilege separation

The administrator application is a second Dart entry point in the same package. It authenticates
against a `profiles` row with `role = 'admin'` and can never create one; administrator accounts
are provisioned out-of-band. Every moderator action is written to `admin_actions_log`, producing
a tamper-evident audit trail independent of the moderator's own account.

## 4.8.3 Known limitations

Stated explicitly, because a security section that claims no weaknesses is not credible.

| Limitation | Consequence | Position taken |
|---|---|---|
| Sender tags on the BLE wire are truncated to 8 characters | Two users sharing those first 8 characters can cancel each other's alerts | Inherent to the advertisement size limit; not fixable in the notification layer |
| The anonymous key ships inside the app | Must be assumed public | Neutralised by the deny-all design above — the key grants only `EXECUTE` on vetted functions |
| Carrot balance is client-side only | A modified client can grant itself cosmetics | Accepted: carrots buy cosmetics only, with no real-money path into the app, so the worst case is free customisation, not fraud |
| `debugUnlimitedCarrots` is currently `true` | The economy is bypassed | Demo and QA convenience; must be set to `false` before any public release |
| The weak-password blocklist is unreachable | A capitalised variant of a blocked password is accepted | Identified by the unit test suite; the blocklist check needs to move above the character-class checks |
| Advertising can fail silently on central-only hardware | Such a device receives alerts but cannot send | Detected at startup and surfaced to the user rather than failing quietly |

## 4.8.4 Backup design

### What requires backup

Only the Supabase database. On-device data is deliberately excluded: it is private to its device
by design, and centralising it for backup would undo the privacy property that motivates the
offline-first architecture. Loss of a device's local data is therefore an accepted outcome, and
is stated to users rather than silently mitigated.

Source code is version-controlled in Git with a remote, which constitutes its own backup path and
is not restated here.

### Method

Logical backup using `pg_dump`, producing a plain-text SQL file containing both schema and data.
This format was chosen over Supabase's managed snapshots for three reasons: it is portable to any
PostgreSQL instance rather than tied to one project, it is human-readable and therefore
inspectable and partially recoverable even if damaged, and it is available on the project's free
tier, where managed point-in-time recovery is not.

Two scripts implement the procedure, in `scripts/`:

| Script | Purpose |
|---|---|
| `backup-db.ps1` | Takes and validates a dump |
| `verify-backup.ps1` | Restores it into a throwaway local database and counts the result |

The dump uses `--schema=public` to skip Supabase-managed schemas that a non-superuser cannot
read, and `--no-owner --no-privileges` to strip role grants specific to this project, so the file
can be restored into a different one.

### Design decisions in the backup procedure

Each of these responds to a failure actually encountered while establishing the procedure, and is
recorded here because the reasoning is not evident from the commands alone.

1. **The connection URI is read at a prompt, never typed as an argument.** PowerShell records
   every typed command to `ConsoleHost_history.txt` in plaintext, permanently. The URI contains
   the database password. Values entered at a `Read-Host` prompt are not recorded.
2. **The URI is extracted from whatever is pasted.** A URI cannot contain whitespace or quotes,
   so surrounding text can be discarded unambiguously. Without this, pasting a full command line
   silently produces duplicate arguments and an obscure failure.
3. **Completion is verified, not assumed.** `pg_dump` writes `-- PostgreSQL database dump
   complete` only after the final object. The script checks for it and refuses to report success
   otherwise. A truncated dump is more dangerous than no dump, because it still looks like a
   backup.
4. **The connection is echoed back with the password masked.** A wrong host is visible before a
   connection is attempted.
5. **Session pooler, never transaction pooler.** `pg_dump` holds one repeatable-read snapshot for
   the duration of the dump. The transaction pooler may hand it a different backend mid-dump,
   producing an internally inconsistent file. The direct-connection endpoint publishes an IPv6
   address only, so on an IPv4 network the session pooler is the correct choice.
6. **Dumps are excluded from version control.** `backups/` is gitignored. A dump contains every
   row in the cloud database, including password hashes and the full moderation history. The rule
   is scoped to that folder rather than a blanket `*.sql`, which would also exclude the nineteen
   migration files.

### Recovery objectives

| Objective | Target | Basis |
|---|---|---|
| Recovery Point Objective | 7 days | Manual weekly dump; a week of account and moderation activity is the accepted maximum loss |
| Recovery Time Objective | 1 hour | Provision a new Supabase project, run `psql -f`, update `SUPABASE_URL` in `client/.env` |
| Retention | 4 most recent dumps | Roughly one month of history at weekly cadence |
| Off-site copy | 1 encrypted copy off the development machine | A backup stored only on the machine it protects fails to the most likely cause of loss |

### Recovery procedure

1. Create a new Supabase project.
2. Restore the schema and data: `psql "<new-project-uri>" -f backups\hops_backup_<date>.sql`
3. Re-run any migration applied after the dump was taken.
4. Update `SUPABASE_URL` and `SUPABASE_ANON_KEY` in `client/.env`.
5. Rebuild and redeploy the client.

Step 4 is what makes recovery viable at all: because the client holds no server-side feature
data, repointing it at a restored database restores the whole system.

## 4.8.5 Restore verification

A backup that has never been restored is an assumption. The procedure is therefore tested, not
merely defined: `verify-backup.ps1` restores the most recent dump into a scratch database on a
local PostgreSQL instance, counts every table, reports function and index totals, and drops the
scratch database. It never contacts the cloud database.

Errors referring to Supabase-managed roles such as `supabase_admin`, or to extensions absent
locally, are expected and do not indicate a failed restore. What is asserted is that every table
and every row returns.

**Verification record**

| Field | Value |
|---|---|
| Backup file | `hops_backup_20260901-224525.sql` |
| Size | 82,924 bytes |
| Completion marker present | Yes |
| Tables in dump | 8 |
| Rows in dump | 67 |
| Functions in dump | 40 |
| Indexes in dump | 8 |
| Restore tested on | 1 September 2026 |
| Restored into | Local PostgreSQL 17.11, scratch database `hops_restore_test` |
| Tables recovered | 8 of 8 |
| Rows recovered | 67 of 67 |
| Outcome | **Verified** — restore completed and the scratch database was dropped |

The demonstration procedure for this, including what to do if the venue has no
network, is in `backup-demo-runbook.md`.

Row counts captured in the verified dump:

| Table | Rows |
|---|---|
| `admin_actions_log` | 30 |
| `content_reports` | 12 |
| `email_verification_otps` | 10 |
| `profiles` | 9 |
| `official_alerts_log` | 4 |
| `password_reset_otps` | 1 |
| `user_notifications` | 1 |
| `admin_requests` | 0 |
| **Total** | **67** |
