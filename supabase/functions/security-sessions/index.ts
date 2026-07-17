// Phase 7.5.1A — Owner-only session and device control plane.
// Deploy: supabase functions deploy security-sessions
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const str = (value: unknown, max = 180) => typeof value === "string" ? value.trim().slice(0, max) : "";

function sessionId(jwt: string): string | null {
  try { return JSON.parse(atob(jwt.split(".")[1] || ""))?.session_id || null; } catch { return null; }
}
function deviceParts(userAgent: string) {
  const browser = /Edg\//.test(userAgent) ? "Microsoft Edge" : /Firefox\//.test(userAgent) ? "Firefox" : /Chrome\//.test(userAgent) ? "Chrome" : /Safari\//.test(userAgent) ? "Safari" : "Unknown browser";
  const operating_system = /Windows/.test(userAgent) ? "Windows" : /Android/.test(userAgent) ? "Android" : /iPhone|iPad|iPod/.test(userAgent) ? "iOS" : /Mac OS/.test(userAgent) ? "macOS" : /Linux/.test(userAgent) ? "Linux" : "Unknown OS";
  return { browser, operating_system, device_name: `${browser} on ${operating_system}` };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return reply({ error: "Missing Authorization header" }, 401);
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
  const { data: userData, error: userError } = await caller.auth.getUser();
  if (userError || !userData.user) return reply({ error: "Invalid or expired session" }, 401);
  const admin = createClient(url, serviceKey);
  const { data: owner } = await admin.from("employees").select("id,is_owner").eq("user_id", userData.user.id).maybeSingle();
  if (!owner?.is_owner) return reply({ error: "Only the Owner account can manage sessions and devices" }, 403);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply({ error: "Invalid JSON body" }, 400); }
  const current = sessionId(jwt);
  const event = async (event_type: string, severity: string, details: Record<string, unknown> = {}) => {
    await admin.from("security_events").insert({ event_type, severity, employee_id: owner.id, portal: "admin", details });
  };
  const notify = async (title: string, message: string) => {
    await admin.from("notifications").insert({ employee_id: owner.id, title, message });
  };
  try {
    if (body.action === "list") {
      const { data, error } = await admin.rpc("list_owner_session_details", { p_owner_user_id: userData.user.id });
      if (error) throw error;
      // Sessions that pre-date Phase 7.5.1A do not yet have a session_devices
      // row.  Supabase's verified auth.sessions.user_agent gives them a useful
      // browser/OS fallback without storing or exposing raw IP addresses.
      const sessions = (data || []).map((session: Record<string, unknown>) => {
        const fallback = deviceParts(str(session.session_user_agent, 1000));
        return {
          ...session,
          device_name: session.device_name || fallback.device_name,
          browser: session.browser || fallback.browser,
          operating_system: session.operating_system || fallback.operating_system,
        };
      });
      return reply({ sessions, current_session_id: current });
    }
    if (body.action === "record_activity") {
      if (!current) return reply({ error: "Current session could not be identified" }, 400);
      const token = str(body.device_token, 100);
      if (!token) return reply({ error: "A device token is required" }, 400);
      const ua = str(body.user_agent || req.headers.get("user-agent"), 1000);
      const parts = deviceParts(ua);
      const location_label = str(body.location_label, 120) || null;
      const latitude = Number(body.latitude), longitude = Number(body.longitude);
      const { data: existing } = await admin.from("session_devices").select("session_id").eq("session_id", current).maybeSingle();
      const { data: trusted } = await admin.from("trusted_devices").select("id").eq("employee_id", owner.id).eq("device_token", token).is("revoked_at", null).gt("trusted_until", new Date().toISOString()).maybeSingle();
      const verification_required = !trusted && !existing;
      // Impossible travel is an alert, never an automatic block.  Coordinates
      // are optional and are only supplied by the browser when location
      // permission was already granted; no location prompt is forced.
      let impossibleTravel = false;
      if (!existing && Number.isFinite(latitude) && Number.isFinite(longitude)) {
        const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
        const { data: prior } = await admin.from("session_devices").select("latitude,longitude,last_seen_at,location_label")
          .eq("owner_user_id", userData.user.id).neq("session_id", current).is("terminated_at", null)
          .not("latitude", "is", null).not("longitude", "is", null).gte("last_seen_at", since)
          .order("last_seen_at", { ascending: false }).limit(1).maybeSingle();
        if (prior) {
          const r = 6371, rad = Math.PI / 180;
          const a = Math.sin((latitude - Number(prior.latitude)) * rad / 2) ** 2 + Math.cos(Number(prior.latitude) * rad) * Math.cos(latitude * rad) * Math.sin((longitude - Number(prior.longitude)) * rad / 2) ** 2;
          const km = 2 * r * Math.asin(Math.sqrt(a));
          const hours = Math.max((Date.now() - new Date(prior.last_seen_at).getTime()) / 3600000, 0.01);
          impossibleTravel = km / hours > 900;
          if (impossibleTravel) { await event("impossible_travel", "high", { from: prior.location_label, to: location_label, distance_km: Math.round(km), elapsed_minutes: Math.round(hours * 60) }); await notify("Impossible travel alert", `A new login appears to be ${Math.round(km)} km from your recent activity. Verify this device.`); }
        }
      }
      const row = { session_id: current, owner_user_id: userData.user.id, employee_id: owner.id, device_token: token, ...parts, user_agent: ua, location_label, latitude: Number.isFinite(latitude) ? latitude : null, longitude: Number.isFinite(longitude) ? longitude : null, last_seen_at: new Date().toISOString(), verification_required };
      const { error } = await admin.from("session_devices").upsert(row, { onConflict: "session_id" });
      if (error) throw error;
      if (!existing) await event("successful_owner_login", "low", { device_name: parts.device_name, location_label, session_id: current });
      if (verification_required) { await event("new_device", "high", { device_name: parts.device_name, location_label, session_id: current }); await notify("New device login", `${parts.device_name}${location_label ? ` near ${location_label}` : ""} signed in and needs 2FA verification.`); }
      return reply({ verification_required, impossible_travel: impossibleTravel });
    }
    if (body.action === "verify_device") {
      if (!current) return reply({ error: "Current session could not be identified" }, 400);
      await admin.from("session_devices").update({ verification_required: false, verified_at: new Date().toISOString() }).eq("session_id", current).eq("owner_user_id", userData.user.id);
      return reply({ verified: true });
    }
    if (body.action === "terminate") {
      const target = str(body.session_id, 50);
      if (!target) return reply({ error: "session_id is required" }, 400);
      if (target === current) return reply({ error: "Current session cannot be terminated here. Use Force reauthentication instead." }, 400);
      const { data, error } = await admin.rpc("terminate_owner_session", { p_owner_user_id: userData.user.id, p_session_id: target });
      if (error) throw error;
      await admin.from("session_devices").update({ terminated_at: new Date().toISOString() }).eq("session_id", target).eq("owner_user_id", userData.user.id);
      await event("session_terminated", "medium", { session_id: target }); await notify("Session terminated", "One of your active sessions was signed out.");
      return reply({ terminated: data === true });
    }
    if (body.action === "terminate_others") {
      if (!current) return reply({ error: "Current session could not be identified" }, 400);
      const { data, error } = await admin.rpc("terminate_other_owner_sessions", { p_owner_user_id: userData.user.id, p_keep_session_id: current });
      if (error) throw error;
      await admin.from("session_devices").update({ terminated_at: new Date().toISOString() }).eq("owner_user_id", userData.user.id).neq("session_id", current).is("terminated_at", null);
      await event("session_terminated", "medium", { other_sessions: true }); await notify("Other sessions terminated", "All other devices were signed out.");
      return reply({ terminated_count: data || 0 });
    }
    if (body.action === "force_reauthentication") {
      const { data, error } = await admin.rpc("terminate_all_owner_sessions", { p_owner_user_id: userData.user.id });
      if (error) throw error;
      await event("security_alert", "high", { action: "force_reauthentication" }); await notify("Reauthentication required", "All sessions were revoked. Sign in again to continue.");
      return reply({ terminated_count: data || 0 });
    }
    if (body.action === "trust_device") {
      if (!current) return reply({ error: "Current session could not be identified" }, 400);
      const { data: device } = await admin.from("session_devices").select("device_token,device_name,user_agent").eq("session_id", current).eq("owner_user_id", userData.user.id).maybeSingle();
      if (!device) return reply({ error: "Current device has not been registered" }, 400);
      const trusted_until = new Date(Date.now() + 30 * 86400000).toISOString();
      const { error } = await admin.from("trusted_devices").upsert({ employee_id: owner.id, device_token: device.device_token, device_label: str(body.device_name, 100) || device.device_name, user_agent: device.user_agent, trusted_until, last_seen_at: new Date().toISOString(), revoked_at: null }, { onConflict: "device_token" });
      if (error) throw error;
      await event("trusted_device_added", "low", { device_name: device.device_name, trusted_until }); await notify("Trusted device added", `${device.device_name || "Current device"} is trusted for 30 days.`);
      return reply({ trusted_until });
    }
    if (body.action === "rename_device" || body.action === "revoke_device") {
      const id = Number(body.device_id); if (!Number.isSafeInteger(id)) return reply({ error: "A valid device_id is required" }, 400);
      const { data: device } = await admin.from("trusted_devices").select("id,device_label").eq("id", id).eq("employee_id", owner.id).maybeSingle();
      if (!device) return reply({ error: "Trusted device not found" }, 404);
      const values = body.action === "rename_device" ? { device_label: str(body.device_name, 100) } : { revoked_at: new Date().toISOString() };
      const { error } = await admin.from("trusted_devices").update(values).eq("id", id).eq("employee_id", owner.id); if (error) throw error;
      const label = str((values as Record<string, unknown>).device_label) || device.device_label || "Device";
      await event(body.action === "rename_device" ? "trusted_device_added" : "trusted_device_removed", "low", { device_id: id, device_name: label });
      if (body.action === "revoke_device") await notify("Trusted device removed", `${label} is no longer trusted.`);
      return reply({ ok: true });
    }
    return reply({ error: "Unknown action" }, 400);
  } catch (e) { return reply({ error: e instanceof Error ? e.message : "Unexpected error" }, 500); }
});
