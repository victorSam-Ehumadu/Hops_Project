# Demonstrating the backup and recovery design

A runbook for showing the backup procedure to an examiner, supervisor or judge.
Roughly four minutes. Companion to `report-4.8-security-and-backup-design.md`,
which carries the reasoning; this file is only about performing it live.

The point being demonstrated is **not** that a file can be produced. It is that
the file has been proven to restore. Most projects can show the first. Very few
can show the second, and that gap is where the marks are.

---

## The single most important property of this demo

**The restore test needs no internet connection.** It runs entirely against a
local PostgreSQL instance using a dump file already on disk.

Only step 2 below — taking a *fresh* dump — needs the network. If the venue's
wifi fails, drop that step and run the rest. The demonstration still stands on
its own, because restoring a backup is the part that actually matters.

Plan for this in advance rather than discovering it in the room.

---

## Before the room

Do all of this the day before, not on the morning.

1. **Take a fresh dump so the file on disk is current.**

   ```
   powershell -ExecutionPolicy Bypass -File .\scripts\backup-db.ps1
   ```

2. **Run the verification once, so you know it passes on this machine today.**

   ```
   powershell -ExecutionPolicy Bypass -File .\scripts\verify-backup.ps1
   ```

3. **Confirm the local PostgreSQL service is running and set to start
   automatically.** If it is stopped, the restore fails and it looks like the
   backup failed.

   ```
   Get-Service postgresql*
   ```

4. **Have both passwords to hand** — the Supabase database password and the
   local postgres password. They are different, and being unable to produce one
   in front of an examiner reads as not knowing your own system.

5. **Increase the terminal font size.** Row counts are the evidence; they have
   to be readable from the back.

6. **Open `docs/report-4.8-security-and-backup-design.md`** in a second window,
   at section 4.8.5. You may be asked to show where this is written up.

---

## The demonstration

### Step 1 — State what is at risk, in one sentence

> "Almost all of Hops runs offline — messages, alerts and proximity data never
> leave the device. The only thing on a server is identity and moderation:
> accounts, reports, and the admin audit log. That is the only thing that needs
> a backup, and it is the thing I would not be able to reconstruct."

This frames the whole demonstration. It also pre-empts "what about the chat
data?", which is otherwise the obvious first question.

### Step 2 — Take a live backup *(skip if the network is unavailable)*

```
powershell -ExecutionPolicy Bypass -File .\scripts\backup-db.ps1 -Masked
```

**Use `-Masked` whenever the screen is projected or shared.** The default prompt
echoes what you paste, and the connection URI contains the database password.
With the switch, input is hidden.

Point out, while it runs, that the script confirms the connection back with the
password starred out:

```
Connecting as: postgresql://postgres.xxxx:********@aws-0-....pooler.supabase.com:5432/postgres
```

Expected output:

```
Backup complete.
  File:  backups\hops_backup_<date>.sql
  Size:  ~81 KB
  Lines: ~2100

Tables captured:
  admin_actions_log
  admin_requests
  ...
```

### Step 3 — Show that completeness is checked, not assumed

Say this explicitly, because it is the difference between a backup and a file:

> "The script does not report success just because `pg_dump` exited. `pg_dump`
> writes a completion marker as its last action, and the script checks for it.
> A dump that was cut off partway would still open, still look like SQL, and
> still be useless — so a truncated file is rejected rather than reported as a
> backup."

If asked to prove it, show the marker directly:

```
Get-Content (Get-ChildItem backups\*.sql | Select -Last 1) -Tail 5
```

### Step 4 — Restore it, which is the actual demonstration

```
powershell -ExecutionPolicy Bypass -File .\scripts\verify-backup.ps1
```

While it runs:

> "An untested backup is an assumption, not a backup. This restores the dump
> into a throwaway database on this machine, counts every table, and then drops
> it. It never touches the cloud database."

Expected output:

```
Restored tables and row counts:
   admin_actions_log            30 rows
   admin_requests                0 rows
   content_reports              12 rows
   email_verification_otps      10 rows
   official_alerts_log           4 rows
   password_reset_otps           1 rows
   profiles                      9 rows
   user_notifications            1 rows

   Tables:    8
   Rows:      67
   Functions: 40
   Indexes:   8

RESTORE VERIFIED - the backup is usable.
```

**Pre-empt the yellow warnings before they are asked about.** Some restore
errors are expected and are not failures:

> "Those refer to `supabase_admin` and to extensions that exist on Supabase but
> not on this laptop. They are expected — the dump is deliberately portable, so
> role grants specific to that project are stripped. What matters is that all
> eight tables and all sixty-seven rows came back."

Being the one to raise this, rather than being caught by it, is worth more than
a clean run would have been.

### Step 5 — Close on recovery, not on backup

> "Recovery is: create a new Supabase project, run this file into it with
> `psql`, and change two lines in the client's `.env`. Because the client holds
> no server-side feature data, repointing it at the restored database restores
> the entire system. Target recovery time is under an hour."

---

## Questions you should expect

**"Why not just use Supabase's own backups?"**
Point-in-time recovery is a paid feature and is not on this project's tier. More
importantly, a managed snapshot is tied to the provider. This dump is plain SQL
and restores into any PostgreSQL instance — including the one on this laptop,
which is exactly what you just watched.

**"How often does this run?"**
Weekly, manually. The recovery point objective is therefore seven days, and that
is stated in the report rather than hidden. Automating it was scoped out because
a scheduled job holding the database password unattended is a larger security
question than the risk it removes at this stage.

**"Is that dump file safe to keep there?"**
No, and it is treated accordingly. It contains every row in the database,
including password hashes and the full moderation log. `backups/` is gitignored,
scoped as a folder rather than a `*.sql` rule — the latter would also have
excluded the nineteen migration files, which do belong in version control.

**"What about the data on the phones?"**
Deliberately not backed up. It is private to its device by design, and
centralising it to back it up would destroy the property that motivates the
offline-first architecture. That trade-off is stated in §4.8.4 rather than left
implicit.

**"What if the backup file is corrupted?"**
That is what step 4 exists to detect, and why the completion marker is checked in
step 3. The retention policy keeps the four most recent dumps, so a bad file does
not leave you with nothing.

**"Could you restore it right now if I asked?"**
Yes — that is step 4, and it needs no internet.

---

## If something goes wrong live

| Symptom | Cause | What to do |
|---|---|---|
| `could not translate host name` | Direct-connection endpoint is IPv6-only; venue network is IPv4 | Use the Session pooler URI. Have it ready in advance. |
| `password authentication failed` | Wrong password, or a special character in it breaking the URI | Skip step 2 and demonstrate with the dump already on disk. |
| Restore fails to connect | Local PostgreSQL service stopped | `Start-Service postgresql*`. Check this beforehand. |
| No network at all | Venue wifi | Skip step 2 entirely. Say so plainly and continue — the restore is the demonstration. |

The recovery move in every case is the same: fall back to the dump already in
`backups/` and run the restore. Say what happened and why it does not affect the
point being made. Handling a failure calmly demonstrates more understanding than
an unbroken run does.

---

## After the demonstration

The verification script drops its scratch database itself, so there is nothing to
clean up. If it was interrupted mid-run, the scratch database may survive:

```
& "C:\Program Files\PostgreSQL\17\bin\dropdb.exe" -U postgres --if-exists hops_restore_test
```

Record the run in the verification table in §4.8.5 of
`report-4.8-security-and-backup-design.md` — date, row count, outcome. An
examiner asking "when did you last test this?" should get a date, not an
estimate.
