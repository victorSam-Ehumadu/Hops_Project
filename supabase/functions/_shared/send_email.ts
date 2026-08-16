// Thin wrapper around Resend's send API (https://resend.com) — chosen as
// the default because it needs nothing beyond a single API key and has a
// generous free tier, not because it's the only option. To use a
// different provider (SendGrid, Postmark, AWS SES, etc.), this is the
// only file that needs to change; every caller just awaits sendEmail().
//
// Required setup (not done by this code — see the README note at the
// bottom of each function's index.ts): run
//   supabase secrets set RESEND_API_KEY=re_your_key_here
// and verify a sending domain in the Resend dashboard (or use their
// shared onboarding@resend.dev sender for testing, which only delivers to
// the Resend account's own verified email while unverified).
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const FROM_ADDRESS = Deno.env.get("HOPS_EMAIL_FROM") ?? "Hops <onboarding@resend.dev>";

export async function sendEmail(opts: {
  to: string;
  subject: string;
  html: string;
  // Where a reply actually goes. Unset for OTP mail (nobody should reply to
  // a verification code). Moderation email sets this to a real inbox so
  // "reply to appeal" in the email body is a genuine instruction, not a
  // dead end — see send-moderation-email, which is the one caller that
  // passes it.
  replyTo?: string;
}): Promise<{ ok: boolean; error?: string }> {
  if (!RESEND_API_KEY) {
    console.error("RESEND_API_KEY is not set — cannot send email. Run: supabase secrets set RESEND_API_KEY=...");
    return { ok: false, error: "email_not_configured" };
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: FROM_ADDRESS,
      to: [opts.to],
      subject: opts.subject,
      html: opts.html,
      ...(opts.replyTo ? { reply_to: opts.replyTo } : {}),
    }),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    console.error("Resend send failed:", res.status, detail);
    return { ok: false, error: "send_failed" };
  }

  return { ok: true };
}

// 6-digit numeric OTP — easy to read aloud/type on a phone keyboard,
// ~1 in a million guess space which is plenty given the 5-attempt cap
// enforced server-side (see 0007_email_auth_and_otp.sql).
export function generateOtp(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

// Mirrors password_policy's hashing convention exactly (sha256 hex
// digest) so a hash computed here and one computed client-side from the
// same string are byte-for-byte comparable.
export async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
