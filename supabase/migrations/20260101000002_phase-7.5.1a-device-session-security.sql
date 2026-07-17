-- Phase 7.5.1A — Enterprise Session Management & Device Security
--
-- This migration deliberately extends (rather than replaces) Phase 7.5.1:
--   * trusted_devices remains the source of truth for device trust;
--   * auth.sessions remains the source of truth for live Supabase sessions;
--   * security_events and notifications remain the audit/notification systems.
-- The only new table is session_devices, because Supabase's auth.sessions
-- intentionally does not provide portable browser, device, or location fields.

-- 1. Per-session metadata, owned and written only by the server-side Edge
-- function.  It permits a useful sessions centre without exposing auth.*.
create table if not exists public.session_devices (
  session_id uuid primary key,
  owner_user_id uuid not null,
  employee_id bigint not null references public.employees(id) on delete cascade,
  device_token text not null,
  device_name text,
  browser text,
  operating_system text,
  user_agent text,
  location_label text,
  latitude numeric(8,5),
  longitude numeric(8,5),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  verification_required boolean not null default false,
  verified_at timestamptz,
  terminated_at timestamptz
);
create index if not exists session_devices_owner_active_idx
  on public.session_devices(owner_user_id, last_seen_at desc) where terminated_at is null;
alter table public.session_devices enable row level security;
-- No browser policy: the Edge Function is the only client boundary.

-- 2. The existing table had a fixed event-type check.  Expand that existing
-- event stream for device/session events; it stays append-only (there are no
-- UPDATE or DELETE policies), and event creation is now server-side except
-- for the pre-auth failed-login event that already needs anon insertion.
alter table public.security_events drop constraint if exists security_events_event_type_check;
alter table public.security_events add constraint security_events_event_type_check check (event_type = any (array[
  'failed_login','permission_violation','unauthorized_access','suspicious_activity','account_locked',
  'new_device','trusted_device_added','trusted_device_removed','session_terminated',
  'password_changed','recovery_code_used','successful_owner_login','impossible_travel','security_alert'
]));
drop policy if exists "security_events_anon_insert" on public.security_events;
create policy "security_events_failed_login_insert" on public.security_events for insert to anon, authenticated
  with check (event_type = 'failed_login' and severity in ('low','medium','high','critical'));
create policy "security_events_authenticated_self_insert" on public.security_events for insert to authenticated
  with check (employee_id is not null and exists (select 1 from public.employees e where e.id = security_events.employee_id and e.user_id = auth.uid()));

-- 3. Trusted-device writes move behind the Edge Function.  The Owner may
-- still read only their own devices, but cannot forge a trust record, change
-- expiry, or manipulate another owner's device identifier via the REST API.
drop policy if exists "td_owner_self" on public.trusted_devices;
create policy "td_owner_read" on public.trusted_devices for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()
                 and e.id = trusted_devices.employee_id and e.is_owner));

-- 4. Server-only RPC helpers.  These retain the Phase 7.5.1 auth.sessions
-- bridge, add metadata joins, and ensure a terminated session is marked in
-- the session record before it is removed from auth.sessions.
create or replace function public.list_owner_session_details(p_owner_user_id uuid)
returns table (session_id uuid, created_at timestamptz, updated_at timestamptz,
  device_name text, browser text, operating_system text, location_label text,
  first_seen_at timestamptz, last_seen_at timestamptz, verification_required boolean,
  session_user_agent text, assurance_level text, expires_at timestamptz)
language sql security definer set search_path = public, auth stable as $$
  select s.id, s.created_at, s.updated_at, d.device_name, d.browser, d.operating_system,
         d.location_label, d.first_seen_at, coalesce(d.last_seen_at, s.updated_at),
         coalesce(d.verification_required, false), s.user_agent, s.aal::text, s.not_after
  from auth.sessions s left join public.session_devices d on d.session_id = s.id
  where s.user_id = p_owner_user_id
    and exists (select 1 from public.employees e where e.user_id = p_owner_user_id and e.is_owner)
  order by s.updated_at desc;
$$;

create or replace function public.terminate_all_owner_sessions(p_owner_user_id uuid)
returns integer language plpgsql security definer set search_path = public, auth as $$
declare v_count integer;
begin
  if not exists (select 1 from public.employees where user_id=p_owner_user_id and is_owner) then
    raise exception 'Target user is not an Owner account';
  end if;
  update public.session_devices set terminated_at=now() where owner_user_id=p_owner_user_id and terminated_at is null;
  delete from auth.refresh_tokens where session_id in (select id from auth.sessions where user_id=p_owner_user_id);
  delete from auth.sessions where user_id=p_owner_user_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.list_owner_session_details(uuid) from public, authenticated, anon;
revoke all on function public.terminate_all_owner_sessions(uuid) from public, authenticated, anon;
grant execute on function public.list_owner_session_details(uuid) to service_role;
grant execute on function public.terminate_all_owner_sessions(uuid) to service_role;

alter publication supabase_realtime add table public.security_events;
