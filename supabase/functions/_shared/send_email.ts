// Thin wrapper around SendGrid's Mail Send API
// (https://docs.sendgrid.com/api-reference/mail-send/mail-send) — chosen
// over Resend for this project specifically because Resend's free path
// (the onboarding@resend.dev sandbox sender) only ever delivers to the
// Resend account's own verified email address until a full domain is
// verified via DNS. SendGrid's free tier supports "Single Sender
// Verification" instead: verify one email address you already own (click a
// link, no DNS records, no domain purchase) and send from it to anyone.
// To use a different provider (Postmark, SES, etc.), this is the only file
// that needs to change; every caller just awaits sendEmail().
//
// Required setup (not done by this code — see the README note at the
// bottom of each function's index.ts): sign up at sendgrid.com, verify a
// Single Sender under Settings > Sender Authentication, create an API key
// (Mail Send permission is enough), then:
//   supabase secrets set SENDGRID_API_KEY=SG.your_key_here
//   supabase secrets set HOPS_EMAIL_FROM="Hops <you@example.com>"
// HOPS_EMAIL_FROM must be exactly the address you verified — SendGrid
// rejects sends from any address that isn't a verified Single Sender (or
// on a verified domain), so there's no working default to fall back to
// here the way there might be with a pre-verified provider domain.
const SENDGRID_API_KEY = Deno.env.get("SENDGRID_API_KEY");
const FROM_ADDRESS = Deno.env.get("HOPS_EMAIL_FROM");

// Accepts "Name <email@example.com>" (matching how HOPS_EMAIL_FROM is
// documented/set above) or a bare "email@example.com". SendGrid wants
// name/email as separate JSON fields rather than one combined string.
function parseFromAddress(raw: string): { email: string; name?: string } {
  const match = raw.match(/^(.*)<([^<>]+)>\s*$/);
  if (match) {
    const name = match[1].trim().replace(/^"|"$/g, "");
    return { email: match[2].trim(), name: name.length > 0 ? name : undefined };
  }
  return { email: raw.trim() };
}

// Every email this project sends is small, controlled HTML (our own
// templates in email_template.ts — never raw user input as the top-level
// markup, though a report reason/ban reason can appear escaped inside it),
// so a regex strip is safe here and doesn't need a real HTML parser.
// Sending HTML with no text/plain alternative is itself a minor spam
// signal — mail filters expect a multipart/alternative with both parts —
// so this exists to close that gap. It is NOT what fixes spam-folder
// placement on its own; that needs SendGrid Domain Authentication (DKIM/
// SPF on a real domain). Single Sender Verification, which is what this
// project currently has configured, has no domain-level authentication to
// give Gmail/Yahoo/Outlook a reason to trust an unfamiliar sender, and
// that's a spam-filtering decision made entirely on the recipient's side —
// nothing this file sends can override it.
function stripHtmlToText(html: string): string {
  return html
    .replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|tr|td|h[1-6])>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

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
  if (!SENDGRID_API_KEY) {
    console.error("SENDGRID_API_KEY is not set — cannot send email. Run: supabase secrets set SENDGRID_API_KEY=...");
    return { ok: false, error: "email_not_configured" };
  }
  if (!FROM_ADDRESS) {
    console.error("HOPS_EMAIL_FROM is not set — cannot send email. Run: supabase secrets set HOPS_EMAIL_FROM=\"Hops <you@example.com>\" (must match a verified Single Sender in SendGrid).");
    return { ok: false, error: "email_not_configured" };
  }

  const res = await fetch("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${SENDGRID_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      personalizations: [{ to: [{ email: opts.to }] }],
      from: parseFromAddress(FROM_ADDRESS),
      subject: opts.subject,
      // text/plain listed first — SendGrid (like most providers) expects
      // the plain part before the html part in a multipart/alternative.
      content: [
        { type: "text/plain", value: stripHtmlToText(opts.html) },
        { type: "text/html", value: opts.html },
      ],
      ...(opts.replyTo ? { reply_to: { email: opts.replyTo } } : {}),
    }),
  });

  // SendGrid returns 202 with an empty body on success — unlike Resend it
  // doesn't hand back a message id to log, so there's nothing to read out
  // of a successful response here.
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    console.error("SendGrid send failed:", res.status, detail);
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
