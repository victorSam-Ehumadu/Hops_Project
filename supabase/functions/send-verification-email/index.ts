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
    // The client sent no token at all — a bug on its side, not an expired
    // session. Named differently so it cannot be mistaken for one.
    if (typeof hops_token !== "string" || hops_token.length === 0) {
      return new Response(JSON.stringify({ ok: false, error: "missing_session" }), {
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

    // Three DIFFERENT failures, reported separately.
    //
    // These were one branch returning "invalid_session" for all of them.
    // Because this returns a non-2xx, functions.invoke() throws rather
    // than handing the body back, so the client's catch ran
    // describeAuthException over the error text, matched "invalid_session"
    // and told the user "Your session has expired — please sign in again."
    //
    // That sentence is wrong for two of the three, and the advice is
    // useless for both: signing in again cannot conjure an email address
    // onto an account that has none, and it cannot help a token that
    // simply does not match any row. It also hid which one had happened,
    // which is most of why this took so long to pin down.
    if (!profile) {
      return new Response(JSON.stringify({ ok: false, error: "unknown_session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!profile.email) {
      return new Response(JSON.stringify({ ok: false, error: "no_email_on_file" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (new Date(profile.token_expires_at).getTime() < Date.now()) {
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
