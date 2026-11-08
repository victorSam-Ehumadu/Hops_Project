import { HOPS_LOGO_BASE64, HOPS_LOGO_WIDTH, HOPS_LOGO_HEIGHT } from "./email_logo.ts";

// Displayed width for the header — scaled down from the source's native
// 240x156 (full size would dominate the header) while preserving its
// actual aspect ratio, computed here rather than hardcoded so a future
// swap to a differently-shaped image (see email_logo.ts) doesn't need a
// second place updated to avoid stretching it.
const DISPLAY_WIDTH = 140;
const DISPLAY_HEIGHT = Math.round((DISPLAY_WIDTH / HOPS_LOGO_WIDTH) * HOPS_LOGO_HEIGHT);

// One shared visual shell for every transactional email Hops sends (OTP
// codes for now) — keeps them consistent and means a future third email
// type doesn't need its own layout written from scratch.
export function renderHopsEmail(opts: {
  heading: string;
  bodyHtml: string;
}): string {
  return `<!doctype html>
<html>
  <body style="margin:0;padding:0;background:#f4f6f5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6f5;padding:32px 0;">
      <tr>
        <td align="center">
          <table role="presentation" width="420" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:20px;overflow:hidden;max-width:92%;">
            <tr>
              <td align="center" style="background:#0f8a5f;padding:28px 24px;">
                <img src="data:image/png;base64,${HOPS_LOGO_BASE64}" width="${DISPLAY_WIDTH}" height="${DISPLAY_HEIGHT}" alt="Hops" style="border-radius:10px;display:block;margin:0 auto;" />
                <div style="color:#ffffff;font-size:20px;font-weight:700;margin-top:10px;letter-spacing:0.3px;">Hops</div>
              </td>
            </tr>
            <tr>
              <td style="padding:32px 28px 8px 28px;">
                <div style="font-size:18px;font-weight:700;color:#111827;margin-bottom:12px;">${opts.heading}</div>
                <div style="font-size:14px;line-height:1.6;color:#374151;">${opts.bodyHtml}</div>
              </td>
            </tr>
            <tr>
              <td style="padding:24px 28px 28px 28px;">
                <div style="font-size:11px;color:#9ca3af;line-height:1.5;border-top:1px solid #f1f5f4;padding-top:16px;">
                  You're receiving this because this email address was entered in the Hops app.
                  If that wasn't you, you can safely ignore this message.
                </div>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>`;
}

// Shared OTP-specific body — used by both send-password-reset-otp and
// send-verification-email so the code itself is presented identically.
export function otpBodyHtml(opts: { intro: string; code: string; minutes: number }): string {
  return `
    <p style="margin:0 0 20px 0;">${opts.intro}</p>
    <div style="text-align:center;margin:0 0 20px 0;">
      <span style="display:inline-block;font-size:32px;font-weight:700;letter-spacing:8px;color:#0f8a5f;background:#eafaf2;border-radius:12px;padding:14px 20px;">${opts.code}</span>
    </div>
    <p style="margin:0;color:#6b7280;">This code expires in ${opts.minutes} minutes. If you didn't request this, you can ignore this email — your account is still safe.</p>
  `;
}

// Ban/suspend/reinstatement body — used by send-moderation-email. One
// function handling all four kinds (not four near-identical templates)
// so the wording can't quietly drift between them.
//
// Every restrictive kind (ban, suspend) includes an appeal path — that's
// the whole reason this template exists rather than reusing a bare
// user_notifications row: a suspension with no way to contest it is just
// a wall, and reply_to on the send call (see send-moderation-email) is
// what makes "reply to this email" a real instruction instead of one that
// bounces.
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

export function moderationBodyHtml(opts: {
  kind: "ban" | "suspend" | "unban" | "unsuspend" | "warn";
  /// "warn" only: which warning this is, and the policy limit.
  warningNumber?: number | null;
  warningLimit?: number | null;
  reason?: string | null;
  suspendedUntil?: string | null; // ISO, "suspend" only
  /// The mailbox a reply will actually reach, from HOPS_APPEALS_EMAIL.
  ///
  /// Required to print the appeal instruction, and that is the point. The
  /// "reply to appeal" paragraph used to be unconditional while the
  /// Reply-To header it depends on was optional, so with the secret unset
  /// a banned student was told a real person would read their appeal and
  /// their reply went to the no-reply sending address. Promising a route
  /// that does not exist is worse than offering none: it costs the person
  /// the effort of writing it and the belief that it was read.
  appealsEmail?: string | null;
}): string {
  const reasonHtml = opts.reason && opts.reason.trim().length > 0
    ? `<p style="margin:0 0 16px 0;"><strong>Reason given:</strong> ${escapeHtml(opts.reason)}</p>`
    : "";

  // A warning is not a restriction — nothing about the account changes —
  // so it gets its own body rather than being bent into the suspension
  // wording. It leads with where they stand, because "you have had a
  // warning" and "you have had your second of three" are very different
  // messages and only the second one lets someone correct course.
  if (opts.kind === "warn") {
    const n = opts.warningNumber ?? 0;
    const limit = opts.warningLimit ?? 0;
    const standingHtml = n > 0 && limit > 0
      ? `<div style="margin:20px 0;padding:16px;background:#f4f6f5;border-radius:12px;">
      <p style="margin:0;font-weight:700;color:#111827;">This is warning ${n} of ${limit}.</p>
      <p style="margin:6px 0 0 0;color:#374151;">${
          n >= limit
            ? "Further reports may lead to your account being suspended or banned."
            : `After ${limit} warnings, your account may be suspended or banned.`
        }</p>
    </div>`
      : "";
    return `
      <p style="margin:0 0 16px 0;">A Hops administrator has issued a warning on your account. Your account is still active and you can keep using Hops normally.</p>
      ${reasonHtml}
      ${standingHtml}
      <p style="margin:0;color:#6b7280;">You can see this warning in the app under Notifications.</p>
    `;
  }

  if (opts.kind === "unban" || opts.kind === "unsuspend") {
    const what = opts.kind === "unban" ? "ban" : "suspension";
    return `
      <p style="margin:0 0 16px 0;">Good news — the ${what} on your Hops account has been lifted. You can sign in normally.</p>
      <p style="margin:0;color:#6b7280;">If you have any questions, just reply to this email.</p>
    `;
  }

  const untilHtml = opts.kind === "suspend" && opts.suspendedUntil
    ? `<p style="margin:0 0 16px 0;"><strong>Suspended until:</strong> ${
        new Date(opts.suspendedUntil).toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" })
      }</p>`
    : "";

  const headline = opts.kind === "ban"
    ? "Your Hops account has been permanently suspended (banned)."
    : "Your Hops account has been temporarily suspended.";

  // Only offered when a reply can actually land somewhere. With no mailbox
  // configured the email still says what happened and why — it just does
  // not invite a reply that would go nowhere.
  const appeal = (opts.appealsEmail ?? "").trim();
  const appealHtml = appeal
    ? `<div style="margin:20px 0;padding:16px;background:#f4f6f5;border-radius:12px;">
      <p style="margin:0;font-weight:700;color:#111827;">Think this is a mistake?</p>
      <p style="margin:6px 0 0 0;color:#374151;">Reply directly to this email to appeal — a real person on the Hops admin team will read it and follow up with you.</p>
    </div>`
    : `<div style="margin:20px 0;padding:16px;background:#f4f6f5;border-radius:12px;">
      <p style="margin:0;font-weight:700;color:#111827;">Think this is a mistake?</p>
      <p style="margin:6px 0 0 0;color:#374151;">Contact your campus Hops administrator to have this reviewed.</p>
    </div>`;

  return `
    <p style="margin:0 0 16px 0;">${headline}</p>
    ${reasonHtml}
    ${untilHtml}
    ${appealHtml}
  `;
}
