// Standard permissive CORS headers for Edge Functions invoked from the
// Flutter client via supabase.functions.invoke(). Mobile app requests
// don't send an Origin header the way a browser would, but keeping this
// makes the functions also callable/testable from a browser (e.g. the
// Supabase dashboard's function invoker) without a separate config.
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};
