-- ---------------------------------------------------------------------------
-- 0023 — get_password_salt_by_email could not run its own fallback branch.
--
-- THE BUG
--
-- 0018 defined this function with `set search_path = public`, and its
-- fallback branch calls `digest(...)` — a pgcrypto function. On Supabase
-- pgcrypto lives in the `extensions` schema, not `public`, so `digest` is
-- not on the path and the call fails with
--
--   42883: function digest(text, unknown) does not exist
--
-- WHY IT WENT UNNOTICED, AND WHY IT MATTERS
--
-- That branch runs on exactly one input: an email with no account. Every
-- successful sign-in takes the other branch (a real salt is found and
-- returned), so the function appeared to work for as long as nobody typed
-- an unknown address.
--
-- The visible symptom was a sign-in error that blamed the server —
-- "something went wrong on our end" — for what is simply a wrong email.
-- The user is told to retry something that can never succeed, and gets no
-- hint that the credentials are the problem.
--
-- The fallback exists for enumeration resistance: it returns a stable,
-- real-looking salt for an unknown address so that the salt lookup cannot
-- be used to probe which emails have accounts. Being unable to run, it was
-- failing closed in the worst way — not leaking existence, but breaking
-- sign-in's error reporting instead.
--
-- Note the client is now also hardened against this independently (see
-- fetchPasswordSaltForEmail): a server-side fault there falls back to a
-- locally derived fake salt so sign-in still reports bad credentials
-- rather than a server error. Both fixes are wanted — this one makes the
-- function correct, that one stops any future fault in it from being
-- reported as something the user did wrong.
--
-- Only this one function was affected; every other pgcrypto caller in this
-- schema was already created with the extensions schema on its path.
-- ---------------------------------------------------------------------------

create or replace function public.get_password_salt_by_email(
  p_email text
) returns text
language plpgsql
security definer
-- `extensions` added. plpgsql resolves function names at RUN time, so the
-- SET clause is what fixes this; a `language sql` body would have needed
-- the call schema-qualified instead (see 0021's note).
set search_path = public, extensions
as $fn$
declare
  v_salt text;
begin
  select password_salt into v_salt
    from public.profiles
    where lower(email) = lower(p_email);

  if v_salt is not null then
    return v_salt;
  end if;

  -- Deterministic per address, so repeated probes of the same unknown
  -- email return a consistent value exactly as a real account would.
  return encode(digest('hops-no-such-account:' || lower(p_email), 'sha256'), 'hex');
end;
$fn$;

revoke all on function public.get_password_salt_by_email(text) from public;
grant execute on function public.get_password_salt_by_email(text) to anon;

-- ---------------------------------------------------------------------------
-- Verify, since the broken branch is the one that is easy not to exercise:
--
--   -- a real account: returns that account's stored salt
--   select public.get_password_salt_by_email('<a real account email>');
--
--   -- no such account: must return 64 hex chars, NOT an error
--   select public.get_password_salt_by_email('definitely-not-a-user@example.com');
--
-- Both must return a value. The second one erroring is this bug.
-- ---------------------------------------------------------------------------
