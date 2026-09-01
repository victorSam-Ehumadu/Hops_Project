-- Generic OTP confirmation, reusing the same email_verification_otps table
-- and send-verification-email Edge Function that signup/change-email
-- already use (see 0007_email_auth_and_otp.sql). This is the piece that
-- was missing for Change Password: unlike a new email (which needs
-- verifying because you might not actually control it),  a password change
-- needs an OTP for a different reason — it's a second factor confirming
-- whoever is sitting at an unlocked/stolen phone with a live session is
-- actually able to receive mail at the account's address, before letting
-- them lock the real owner out by changing the password.
--
-- Deliberately its own function rather than reusing
-- verify_signup_email_otp — that one's side effect (flipping
-- email_verified = true) belongs to "you proved you own this email
-- address," not "you proved you can act on this account right now." A
-- password-change confirmation shouldn't silently mark a still-unconfirmed
-- signup email as verified as a side effect of an unrelated action.
create or replace function public.verify_account_otp(
  p_hops_token text,
  p_otp_hash text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id uuid;
  v_otp public.email_verification_otps%rowtype;
begin
  select id into v_profile_id
    from public.profiles
    where hops_token = p_hops_token
      and token_expires_at > (now() at time zone 'utc');

  if v_profile_id is null then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  select * into v_otp
    from public.email_verification_otps
    where profile_id = v_profile_id
      and used = false
      and expires_at > (now() at time zone 'utc')
    order by created_at desc
    limit 1;

  if not found or v_otp.attempts >= 5 then
    return false;
  end if;

  if v_otp.otp_hash is distinct from p_otp_hash then
    update public.email_verification_otps set attempts = attempts + 1 where id = v_otp.id;
    return false;
  end if;

  update public.email_verification_otps set used = true where id = v_otp.id;
  return true;
end;
$$;

revoke all on function public.verify_account_otp(text, text) from public;
grant execute on function public.verify_account_otp(text, text) to anon;
