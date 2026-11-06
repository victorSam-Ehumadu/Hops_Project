// POST { admin_hops_token, target_id, kind, reason?, suspended_until? }
//   -> { ok: boolean, error?: string }
//
// Tells a student their account was banned/suspended (or that a ban/
// suspension was lifted), with an appeal path for the two restrictive
// kinds. Triggered by the ADMIN app right after ban_user/suspend_user/
// unban_user/unsuspend_user succeeds in the database (see
// admin_user_detail_screen.dart) — same client-invokes-the-edge-function
// shape as every other email in this app (send-verification-email,
// send-password-reset-otp), rather than the database calling out on its
// own, which this project has no pg_net/http extension enabled for.
//
// Best-effort by design, both directions:
//   - The moderation action itself already happened by the time this is
//     called. A failure here (no email on file, SendGrid down,
//     SENDGRID_API_KEY missing) never un-bans/un-suspends anyone — it only
//     means the person finds out from the app's own sign-in screen instead
//     of their inbox.
//   - The client does not block its own UI on this call succeeding.
//
// Authorization is re-checked here independently of the RPC that already
// ran — this function has its own service-role Supabase client and trusts
// nothing the caller claims about itself beyond the hops_token, exactly
// like every admin-gated RPC in the SQL migrations.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { sendEmail } from "../_shared/send_email.ts";
import { renderHopsEmail, moderationBodyHtml } from "../_shared/email_template.ts";

const APPEALS_REPLY_TO = Deno.env.get("HOPS_APPEALS_EMAIL") ?? undefined;

const KIND_SUBJECTS: Record<string, string> = {
  ban: "Your Hops account has been banned",
  suspend: "Your Hops account has been suspended",
  unban: "Your Hops account access has been restored",
  unsuspend: "Your Hops suspension has been lifted",
};

const KIND_HEADINGS: Record<string, string> = {
  ban: "Account banned",
  suspend: "Account suspended",
  unban: "Account restored",
  unsuspend: "Suspension lifted",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { admin_hops_token, target_id, kind, reason, suspended_until } = await req.json();

    if (
      typeof admin_hops_token !== "string" || admin_hops_token.length === 0 ||
      typeof target_id !== "string" || target_id.length === 0 ||
      typeof kind !== "string" || !(kind in KIND_SUBJECTS)
    ) {
      return new Response(JSON.stringify({ ok: false, error: "invalid_request" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: admin } = await supabase
      .from("profiles")
      .select("id, role, token_expires_at")
      .eq("hops_token", admin_hops_token)
      .maybeSingle();

    if (!admin || admin.role !== "admin" || new Date(admin.token_expires_at).getTime() < Date.now()) {
      return new Response(JSON.stringify({ ok: false, error: "not_authorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: target } = await supabase
      .from("profiles")
      .select("email")
      .eq("id", target_id)
      .maybeSingle();

    if (!target) {
      return new Response(JSON.stringify({ ok: false, error: "user_not_found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!target.email) {
      // Not a server error — plenty of accounts predate mandatory email, or
      // never verified one. The moderation action already succeeded
      // regardless; this just means there's nowhere to send a copy of it.
      return new Response(JSON.stringify({ ok: false, error: "no_email_on_file" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { ok, error } = await sendEmail({
      to: target.email,
      subject: KIND_SUBJECTS[kind],
      replyTo: (kind === "ban" || kind === "suspend") ? APPEALS_REPLY_TO : undefined,
      html: renderHopsEmail({
        heading: KIND_HEADINGS[kind],
        bodyHtml: moderationBodyHtml({
          kind: kind as "ban" | "suspend" | "unban" | "unsuspend",
          reason: typeof reason === "string" ? reason : null,
          suspendedUntil: typeof suspended_until === "string" ? suspended_until : null,
          // Same value as replyTo above, so the body can never invite a
          // reply the header will not route.
          appealsEmail: APPEALS_REPLY_TO,
        }),
      }),
    });

    return new Response(JSON.stringify({ ok, error }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("send-moderation-email error:", err);
    return new Response(JSON.stringify({ ok: false, error: "server_error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

// Setup, same as the other functions in this folder (see README.md):
//   supabase functions deploy send-moderation-email
//   supabase secrets set SENDGRID_API_KEY=SG.your_key_here
//   supabase secrets set HOPS_EMAIL_FROM="Hops <you@example.com>"
//   supabase secrets set HOPS_APPEALS_EMAIL=appeals@yourdomain.example
// HOPS_APPEALS_EMAIL is optional — omit it and ban/suspend emails still
// send, just without a working "reply to appeal" (replies would go
// nowhere useful, so set this before relying on the appeal path).
