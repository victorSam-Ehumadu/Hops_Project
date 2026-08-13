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
