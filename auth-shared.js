// ══════════════════════════════════════════════════════════════════════
// Phase 7.5.2 — shared staff-auth config + role routing.
//
// login.html (Owner/Admin/Manager) and employee/login.html (Employee, kept
// separate only because the Employee PWA is scope-locked to /employee/ and
// cannot redirect unauthenticated users outside that scope without kicking
// them out of the installed app) previously each hardcoded their own copy
// of the Supabase URL/anon key and their own role → workspace redirect
// rule. Two copies of the same rule is exactly the kind of drift that lets
// them quietly disagree — this file is the single source of truth both
// pages now call into. There is still only one Supabase Auth backend and
// one `employees` table; this changes nothing about how auth works, it
// just stops the redirect rule from being written twice.
// ══════════════════════════════════════════════════════════════════════

const STAFF_SUPABASE_URL  = "https://hamqmvjucrvsjhqfsehe.supabase.co";
const STAFF_SUPABASE_ANON = "sb_publishable_8g8mp-PH2uvpPR4RbTmGsg_kdXw9fXb";

/** Where a signed-in staff member's role sends them. Owner/Admin/Manager
 *  share the admin.html dashboard (RBAC + the workspace picker inside it
 *  narrow the view further); only "employee" gets the mobile-first portal.
 *  `basePath` lets employee/login.html (one directory deep) and login.html
 *  (root) both call this with the correct relative prefix. */
function staffRedirectPath(role, basePath) {
  return role === "employee" ? `${basePath}employee/index.html` : `${basePath}admin.html`;
}

/** Resolves the current session's role (defaulting to "employee" if no
 *  employees row is found — same fail-safe every bootstrap in this app
 *  already uses) and redirects. Returns without redirecting if there is
 *  no session, so callers can fall through to their own login form.
 *
 *  Phase 7.5.5 QA fix — this call is fired at page load *without* being
 *  awaited by the caller (so it never blocks the login form from being
 *  usable). That's fine on its own, but it means it can still be
 *  in-flight — mid getSession()/employees lookup — when the person
 *  finishes typing and submits the form themselves a moment later. If a
 *  stale, still-valid session was left behind by a previous staff
 *  member who didn't sign out (rather than one that's actually
 *  expired), both redirects race, and because window.location.replace()
 *  doesn't stop the rest of the script from running, whichever of the
 *  two finishes LAST wins — occasionally sending a person who just
 *  signed in correctly to the previous person's workspace instead of
 *  their own. `isAborted` lets a caller that starts its own,
 *  user-initiated sign-in cancel this stale check so it can never
 *  overwrite that newer, correct redirect. It's optional and changes
 *  nothing for the normal "already signed in, skip the form" case. */
async function staffCheckSessionAndRedirect(sb, basePath, isAborted) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return false;
  if (typeof isAborted === "function" && isAborted()) return false;
  const { data: emp } = await sb.from("employees").select("role").eq("user_id", session.user.id).maybeSingle();
  // Re-check after the network round-trip above — a manual sign-in can
  // easily start and finish while this query is in flight.
  if (typeof isAborted === "function" && isAborted()) return false;
  window.location.replace(staffRedirectPath(emp?.role ?? "employee", basePath));
  return true;
}

/** Phase 7.5.5 QA fix — the one piece of staff-side state that lives
 *  outside the Supabase session itself: the Owner's remembered
 *  Owner/Admin workspace pick (sessionStorage key below, read/written
 *  in admin.html). signOut() only clears the auth session; it was
 *  never clearing this. Harmless in a fresh tab (sessionStorage doesn't
 *  survive a closed tab), but if a tab stays open across a sign-out and
 *  a different staff member signs in on it, this call — added at every
 *  sign-out site — makes sure their previous workspace choice can never
 *  silently carry over. */
function staffClearCachedState() {
  try { sessionStorage.removeItem("swahili_treats_workspace"); } catch (_) { /* sessionStorage unavailable — nothing to clear */ }
}
