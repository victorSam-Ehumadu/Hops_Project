// Thin wrapper around Resend's Send Email API
// (https://resend.com/docs/api-reference/emails/send-email).
//
// WHY RESEND, HAVING PREVIOUSLY BEEN SENDGRID
//
// SendGrid was chosen originally for one specific reason: its free tier
// supported "Single Sender Verification" — verify one mailbox you already
// own by clicking a link, no DNS and no domain purchase — whereas Resend's
// free path (the onboarding@resend.dev sandbox sender) only ever delivered
// to the Resend account's own address until a domain was verified by DNS.
// With no domain, SendGrid was the only one that could mail a real student.
//
// Both halves of that have since changed:
//
//   1. The project now owns hopsapp.me and its DNS is already set up, so
//      Resend's domain requirement is no longer an obstacle — it is a step
//      that has effectively been done.
//   2. The SendGrid trial expired, and sends began failing with
//      401 "Maximum credits exceeded".
//
// Resend's free tier is 3,000 emails/month (100/day), which is far more
// headroom than SendGrid's post-trial allowance, and the Single Sender
// advantage that justified SendGrid no longer applies.
//
// Every caller just awaits sendEmail(); this is the only file that changed
// in the switch, and sendEmail's signature is deliberately identical to
// the SendGrid version so the three functions were untouched.
//
// Required setup:
//   1. Sign up at resend.com.
//   2. Domains -> Add Domain -> hopsapp.me, and add the DNS records it
//      shows (see docs/deployment-domain-and-backup.md for the Namecheap
//      specifics — same Host-field rules as before).
//   3. API Keys -> Create, with Sending access.
//   4. supabase secrets set RESEND_API_KEY=re_your_key_here
//      (HOPS_EMAIL_FROM is unchanged and carries over as-is.)
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const FROM_ADDRESS = Deno.env.get("HOPS_EMAIL_FROM");

// Every email this project sends is small, controlled HTML (our own
// templates in email_template.ts — never raw user input as the top-level
// markup, though a report reason/ban reason can appear escaped inside it),
// so a regex strip is safe here and doesn't need a real HTML parser.
// Sending HTML with no text/plain alternative is itself a minor spam
// signal — mail filters expect a multipart/alternative with both parts —
// so this exists to close that gap.
//
// Unlike the SendGrid era, spam-folder placement is no longer the expected
// outcome: hopsapp.me is domain-authenticated (SPF + DKIM) with a DMARC
// record, so receivers have a cryptographic reason to trust the sender.
// Check the Authentication-Results header on a real delivery rather than
// assuming either way.
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
  if (!RESEND_API_KEY) {
    console.error(
      "RESEND_API_KEY is not set — cannot send email. Run: supabase secrets set RESEND_API_KEY=re_...",
    );
    return { ok: false, error: "email_not_configured" };
  }
  if (!FROM_ADDRESS) {
    console.error(
      'HOPS_EMAIL_FROM is not set — cannot send email. Run: supabase secrets set HOPS_EMAIL_FROM="Hops <no-reply@hopsapp.me>" (the domain must be verified in Resend).',
    );
    return { ok: false, error: "email_not_configured" };
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    // Resend takes `from` as a single "Name <addr>" string, so the
    // parseFromAddress() helper SendGrid needed (it wanted name and email
    // as separate JSON fields) is gone. HOPS_EMAIL_FROM passes straight
    // through in whichever of the two documented forms it holds.
    body: JSON.stringify({
      from: FROM_ADDRESS,
      to: [opts.to],
      subject: opts.subject,
      html: opts.html,
      text: stripHtmlToText(opts.html),
      ...(opts.replyTo ? { reply_to: opts.replyTo } : {}),
    }),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    console.error("Resend send failed:", res.status, detail);
    // Quota and rate limiting are reported distinctly from a genuine
    // misconfiguration, because they are not the same problem and the
    // previous lumping of them cost real debugging time: SendGrid's
    // "Maximum credits exceeded" surfaced in the app as "the mail server
    // rejected it", which points at the sender and sent us auditing DNS
    // that was perfectly correct.
    //
    // 429 is Resend's rate limit (2 requests/second) as well as its
    // monthly cap, and both are states that resolve on their own.
    if (res.status === 429 || detail.includes("quota") ||
        detail.includes("limit")) {
      return { ok: false, error: "quota_exceeded" };
    }
    // 403 from Resend is usually an unverified sending domain, which IS a
    // configuration fault and worth distinguishing from a transient one.
    if (res.status === 403) {
      return { ok: false, error: "sender_not_verified" };
    }
    return { ok: false, error: "send_failed" };
  }

  // Resend returns 200 with {"id": "..."} — worth logging, since that id
  // is what their dashboard and support search on when a specific message
  // has to be traced. SendGrid returned an empty 202 and gave us nothing
  // to record here.
  const body = await res.json().catch(() => null);
  if (body?.id) console.log("Resend accepted message:", body.id);

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
