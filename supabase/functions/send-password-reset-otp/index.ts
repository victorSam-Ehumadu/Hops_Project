// POST { email: string } -> always { ok: true } regardless of whether that
// email actually has an account (enumeration resistance — same reasoning
// as signin_hops_user's collapsed "invalid username or password" result).
// If it does, a 6-digit OTP is generated, its hash stored in
// password_reset_otps, and the plaintext code emailed to that address.
// Actual verification + password change happens entirely in Postgres via
// verify_password_reset_otp() — see 0007_email_auth_and_otp.sql — this
// function's only job is "generate a code and get it to their inbox."
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { generateOtp, sha256Hex, sendEmail } from "../_shared/send_email.ts";
import { renderHopsEmail, otpBodyHtml } from "../_shared/email_template.ts";

const OTP_TTL_MINUTES = 10;
// Minimum gap between two requests for the same email — cheap abuse/spam
// guard so someone can't be bombarded with reset emails by a third party
// repeatedly submitting their address.
const RESEND_COOLDOWN_SECONDS = 60;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { email } = await req.json();
    if (typeof email !== "string" || !email.includes("@")) {
      return new Response(JSON.stringify({ ok: false, error: "invalid_email" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    const normalizedEmail = email.trim().toLowerCase();

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: profile } = await supabase
      .from("profiles")
      .select("id, email")
      .ilike("email", normalizedEmail)
      .maybeSingle();

    // Always the same response shape whether or not an account exists —
    // only the branch below differs, and only server-side.
    if (profile) {
      const { data: recent } = await supabase
        .from("password_reset_otps")
        .select("created_at")
        .ilike("email", normalizedEmail)
        .gte("created_at", new Date(Date.now() - RESEND_COOLDOWN_SECONDS * 1000).toISOString())
        .limit(1);

      if (!recent || recent.length === 0) {
        const otp = generateOtp();
        const otpHash = await sha256Hex(otp);
        const expiresAt = new Date(Date.now() + OTP_TTL_MINUTES * 60 * 1000).toISOString();

        await supabase.from("password_reset_otps").insert({
          email: normalizedEmail,
          otp_hash: otpHash,
          expires_at: expiresAt,
        });

        await sendEmail({
          to: normalizedEmail,
          subject: "Your Hops password reset code",
          html: renderHopsEmail({
            heading: "Reset your password",
            bodyHtml: otpBodyHtml({
              intro: "Enter this code in Hops to choose a new password.",
              code: otp,
              minutes: OTP_TTL_MINUTES,
            }),
          }),
        });
      }
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("send-password-reset-otp error:", err);
    // Still a generic ok:true shape on the outside would leak nothing, but
    // an actual server error is worth surfacing distinctly so the client
    // doesn't tell the user "check your email" when nothing was sent.
    return new Response(JSON.stringify({ ok: false, error: "server_error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
