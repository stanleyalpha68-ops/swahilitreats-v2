-- ============================================================================
-- PHASE 7.5.1 — Enterprise Security & Authentication System
-- ============================================================================
-- ANALYSIS FIRST (see chat for the full writeup). Summary of what already
-- existed before this migration, so nothing here duplicates it:
--   - Supabase Auth (email/password) — untouched, still the only identity
--     provider. This migration adds TOTP as a second factor using
--     Supabase Auth's OWN built-in MFA (auth.mfa.enroll/challenge/verify,
--     client-side, no secrets ever touch our own tables) — not a custom
--     TOTP implementation.
--   - employee/login.html already does role-based workspace routing;
--     login.html was just patched (chat, same phase) to match it.
--   - audit_log already gets a 'login' row on success; security_events
--     already gets a 'failed_login' row on failure. Part 7's "Login
--     History" is a VIEW over those two — no new table.
--   - employees.role / is_owner already fully drive the Permission Engine
--     — reused as-is for "only the Owner needs 2FA".
--
-- WHAT THIS MIGRATION ADDS (genuinely new):
--   1. trusted_devices       — soft, app-tracked device trust (30-day
--                               "remember this device" for the Owner's 2FA).
--   2. owner_recovery_codes  — one-time TOTP-bypass codes, hashed with
--                               pgcrypto, single-use.
--   3. security_login_history — a VIEW unioning audit_log + security_events,
--                               not a new table, so it can never drift from
--                               the two things that already write to it.
--   4. Three SECURITY DEFINER functions that bridge to auth.sessions/
--      auth.refresh_tokens for the "Active Sessions" dashboard and the
--      "Terminate Session" action. auth.* is not an exposed PostgREST
--      schema (by design, Supabase does not recommend exposing it), so a
--      SECURITY DEFINER function in public — callable via .rpc() — is the
--      supported bridge. The Edge Function (deploy instructions in chat)
--      calls these with the service role so it can act on ANY user's
--      sessions, not just the caller's own; the functions themselves
--      still double-check "is this an Owner?" before doing anything.
--
-- CAVEAT stated plainly: Postgres access tokens (JWTs) remain valid until
-- their own expiry even after the underlying session row is deleted here —
-- this is documented, standard Supabase/JWT behavior, not a bug in this
-- migration. "Terminate session" means: the refresh token is destroyed so
-- the session can never be renewed again, and it disappears from this
-- dashboard immediately. It does NOT mean the other browser's current tab
-- is force-closed mid-JWT-lifetime. Keep your project's JWT expiry (Auth
-- settings → JWT expiry limit) reasonably short if this gap matters for
-- your threat model — this migration doesn't change that setting.
--
-- VERIFY BEFORE RUNNING: this migration reads from auth.sessions using
-- only the columns Supabase's own docs confirm exist everywhere (id,
-- user_id, created_at, updated_at). Run `\d auth.sessions` in the SQL
-- editor first — if your project's version also exposes user_agent/ip/aal/
-- not_after (common on current projects), uncomment the enhanced SELECT
-- list marked below to show browser/OS/last-activity detail on the
-- dashboard instead of just timestamps.
-- ============================================================================

create extension if not exists pgcrypto;


-- ----------------------------------------------------------------------------
-- 1. Trusted devices (Part 5)
-- ----------------------------------------------------------------------------
create table if not exists public.trusted_devices (
  id               bigint generated always as identity primary key,
  employee_id      bigint not null references public.employees(id),
  device_token     text not null unique,          -- random token stored in the browser (localStorage), not a secret credential on its own — see chat
  device_label     text,                          -- "Chrome on Mac", user-editable
  user_agent       text,
  trusted_until    timestamp with time zone not null,
  last_seen_at     timestamp with time zone not null default now(),
  created_at       timestamp with time zone not null default now(),
  revoked_at       timestamp with time zone
);

create index if not exists idx_trusted_devices_employee on public.trusted_devices(employee_id);

alter table public.trusted_devices enable row level security;
drop policy if exists "td_owner_self" on public.trusted_devices;
create policy "td_owner_self" on public.trusted_devices for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.id = trusted_devices.employee_id and e.is_owner))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.id = trusted_devices.employee_id and e.is_owner));

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'trusted_devices'
  ) then
    alter publication supabase_realtime add table public.trusted_devices;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 2. Recovery codes (Part 9) — hashed, single-use
-- ----------------------------------------------------------------------------
create table if not exists public.owner_recovery_codes (
  id           bigint generated always as identity primary key,
  employee_id  bigint not null references public.employees(id),
  code_hash    text not null,                     -- crypt()'d, never store plaintext
  used_at      timestamp with time zone,
  created_at   timestamp with time zone not null default now(),
  batch_id     uuid not null                       -- regenerating invalidates the whole previous batch_id
);

create index if not exists idx_recovery_codes_employee on public.owner_recovery_codes(employee_id, batch_id);

alter table public.owner_recovery_codes enable row level security;
drop policy if exists "rc_owner_self" on public.owner_recovery_codes;
create policy "rc_owner_self" on public.owner_recovery_codes for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.id = owner_recovery_codes.employee_id and e.is_owner))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.id = owner_recovery_codes.employee_id and e.is_owner));

-- Generates a fresh batch of 10 one-time codes for the Owner, invalidating
-- any previous batch (Part 9: "Regenerating recovery codes invalidates
-- previous ones"). Returns the PLAINTEXT codes exactly once — the caller
-- must show/download them immediately; they cannot be retrieved again.
create or replace function public.generate_owner_recovery_codes()
returns table (code text)
language plpgsql security definer set search_path = public as $$
declare
  v_employee_id bigint;
  v_batch uuid := gen_random_uuid();
  v_code text;
  i int;
begin
  select id into v_employee_id from public.employees where user_id = auth.uid() and is_owner limit 1;
  if v_employee_id is null then
    raise exception 'Only the Owner account can generate recovery codes';
  end if;

  delete from public.owner_recovery_codes where employee_id = v_employee_id;

  for i in 1..10 loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4)) || '-' ||
              upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
    insert into public.owner_recovery_codes (employee_id, code_hash, batch_id)
    values (v_employee_id, crypt(v_code, gen_salt('bf')), v_batch);
    code := v_code;
    return next;
  end loop;
end;
$$;

-- Verifies and burns one recovery code. Returns true exactly once per code.
create or replace function public.redeem_owner_recovery_code(p_code text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_employee_id bigint;
  v_row public.owner_recovery_codes%rowtype;
begin
  select id into v_employee_id from public.employees where user_id = auth.uid() and is_owner limit 1;
  if v_employee_id is null then return false; end if;

  select * into v_row from public.owner_recovery_codes
    where employee_id = v_employee_id and used_at is null and code_hash = crypt(p_code, code_hash)
    limit 1;
  if v_row.id is null then return false; end if;

  update public.owner_recovery_codes set used_at = now() where id = v_row.id;
  return true;
end;
$$;

grant execute on function public.generate_owner_recovery_codes() to authenticated;
grant execute on function public.redeem_owner_recovery_code(text) to authenticated;


-- ----------------------------------------------------------------------------
-- 3. Login History (Part 7) — a view, not a table; can never go stale
-- ----------------------------------------------------------------------------
create or replace view public.security_login_history as
select
  'success'::text as result,
  a.actor_employee_id as employee_id,
  a.actor_role as role,
  a.created_at,
  a.device_placeholder as user_agent,
  null::text as failure_reason,
  null::text as actor_identifier
from public.audit_log a
where a.action_type = 'login'
union all
select
  'failure'::text as result,
  s.employee_id,
  null::text as role,
  s.created_at,
  s.details->>'user_agent' as user_agent,
  s.details->>'reason' as failure_reason,
  s.actor_identifier
from public.security_events s
where s.event_type = 'failed_login'
order by created_at desc;

comment on view public.security_login_history is
  'Phase 7.5.1 Part 7 — immutable login history, reusing audit_log + security_events. No new table, so there is nothing here to accidentally make editable.';


-- ----------------------------------------------------------------------------
-- 4. Active Sessions bridge (Part 6) — SECURITY DEFINER functions
-- ----------------------------------------------------------------------------
-- Called BY THE EDGE FUNCTION using the service role, on behalf of the
-- Owner viewing their Security Dashboard. Still independently verifies
-- the target is an Owner account before touching anything, so even if the
-- edge function itself were misconfigured, these functions won't act on
-- an arbitrary employee's sessions.

create or replace function public.list_owner_sessions(p_owner_user_id uuid)
returns table (session_id uuid, created_at timestamptz, updated_at timestamptz)
language plpgsql security definer set search_path = public, auth as $$
begin
  if not exists (select 1 from public.employees where user_id = p_owner_user_id and is_owner) then
    raise exception 'Target user is not an Owner account';
  end if;
  -- Base, guaranteed-present columns only — see the header comment for how
  -- to add user_agent/ip/aal/not_after if your project's auth.sessions has them.
  return query
    select s.id, s.created_at, s.updated_at
    from auth.sessions s
    where s.user_id = p_owner_user_id
    order by s.created_at desc;
end;
$$;

create or replace function public.terminate_owner_session(p_owner_user_id uuid, p_session_id uuid)
returns boolean
language plpgsql security definer set search_path = public, auth as $$
begin
  if not exists (select 1 from public.employees where user_id = p_owner_user_id and is_owner) then
    raise exception 'Target user is not an Owner account';
  end if;
  delete from auth.refresh_tokens where session_id = p_session_id;
  delete from auth.sessions where id = p_session_id and user_id = p_owner_user_id;
  return found;
end;
$$;

create or replace function public.terminate_other_owner_sessions(p_owner_user_id uuid, p_keep_session_id uuid)
returns integer
language plpgsql security definer set search_path = public, auth as $$
declare
  v_count integer;
begin
  if not exists (select 1 from public.employees where user_id = p_owner_user_id and is_owner) then
    raise exception 'Target user is not an Owner account';
  end if;
  delete from auth.refresh_tokens where session_id in (
    select id from auth.sessions where user_id = p_owner_user_id and id <> p_keep_session_id
  );
  delete from auth.sessions where user_id = p_owner_user_id and id <> p_keep_session_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- These three are intentionally NOT granted to `authenticated` — only the
-- service role (used exclusively inside the Edge Function) may call them.
-- This is the actual privilege boundary: a compromised browser session can
-- never call these directly, only the server-side function can, and only
-- after it has independently checked the caller's own JWT belongs to the
-- Owner (see the Edge Function source in chat).
revoke all on function public.list_owner_sessions(uuid) from public, authenticated, anon;
revoke all on function public.terminate_owner_session(uuid, uuid) from public, authenticated, anon;
revoke all on function public.terminate_other_owner_sessions(uuid, uuid) from public, authenticated, anon;
grant execute on function public.list_owner_sessions(uuid) to service_role;
grant execute on function public.terminate_owner_session(uuid, uuid) to service_role;
grant execute on function public.terminate_other_owner_sessions(uuid, uuid) to service_role;

-- ============================================================================
-- END PHASE 7.5.1 SQL
-- ============================================================================
