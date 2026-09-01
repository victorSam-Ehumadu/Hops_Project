// POST { hops_token: string } -> { ok: boolean, error?: string }
// Sends a 6-digit verification code to whatever email is currently on
// file for the signed-in account (looked up server-side from the token —
// the client can't just hand over an arbitrary email to "verify"). Used
// right after signup, and again after Account Management > Change Email.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { generateOtp, sha256Hex, sendEmail } from "../_shared/send_email.ts";
import { renderHopsEmail, otpBodyHtml } from "../_shared/email_template.ts";

const OTP_TTL_MINUTES = 10;
const RESEND_COOLDOWN_SECONDS = 60;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { hops_token } = await req.json();
    if (typeof hops_token !== "string" || hops_token.length === 0) {
      return new Response(JSON.stringify({ ok: false, error: "invalid_session" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: profile } = await supabase
      .from("profiles")
      .select("id, email, token_expires_at")
      .eq("hops_token", hops_token)
      .maybeSingle();

    if (!profile || !profile.email || new Date(profile.token_expires_at).getTime() < Date.now()) {
      return new Response(JSON.stringify({ ok: false, error: "invalid_session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: recent } = await supabase
      .from("email_verification_otps")
      .select("created_at")
      .eq("profile_id", profile.id)
      .gte("created_at", new Date(Date.now() - RESEND_COOLDOWN_SECONDS * 1000).toISOString())
      .limit(1);

    if (recent && recent.length > 0) {
      // Not an error — the caller (e.g. a "Resend code" button tapped
      // twice) should just treat this as "already on its way."
      return new Response(JSON.stringify({ ok: true }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const otp = generateOtp();
    const otpHash = await sha256Hex(otp);
    const expiresAt = new Date(Date.now() + OTP_TTL_MINUTES * 60 * 1000).toISOString();

    await supabase.from("email_verification_otps").insert({
      profile_id: profile.id,
      otp_hash: otpHash,
      expires_at: expiresAt,
    });

    const { ok } = await sendEmail({
      to: profile.email,
      subject: "Verify your email for Hops",
      html: renderHopsEmail({
        heading: "Confirm your email",
        bodyHtml: otpBodyHtml({
          intro: "Welcome to Hops! Enter this code in the app to verify your email address.",
          code: otp,
          minutes: OTP_TTL_MINUTES,
        }),
      }),
    });

    return new Response(JSON.stringify({ ok }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("send-verification-email error:", err);
    return new Response(JSON.stringify({ ok: false, error: "server_error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
