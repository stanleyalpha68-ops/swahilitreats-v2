-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 6.10 Migration
-- System Monitoring, Operational Health & Maintenance Center
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Additive only — nothing existing is altered, renamed, or dropped.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ALREADY EXISTS (checked before writing this)
-- ───────────────────────────────────────────────────────────────────────
-- Unlike every module built so far, there is no pre-existing "coming
-- soon" stub for this one anywhere in MODULE_REGISTRY — Operations
-- Center is genuinely new ground, not an upgrade of a placeholder.
--
-- Some of what Part 2/3/6 ask for already exists and is reused, not
-- rebuilt:
--   • employees.status ('active'/'offline'/'inactive') and
--     employees.active (boolean) already model Employee Activity and
--     "Locked Accounts" (an inactive/deactivated employee) respectively.
--   • audit_log already captures every row-level business action.
--   • approval_requests already has its own status/backlog to monitor.
-- None of those need new columns — the Operations Center reads them,
-- same as the Analytics/Financial Centers already read `orders`.
--
-- What doesn't exist anywhere: a place to record an application error,
-- a failed login / security event, or a maintenance window. Those are
-- the three real gaps this migration fills.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION ADDS
-- ───────────────────────────────────────────────────────────────────────
--   1. system_errors      — Part 5's Error Center. One row per caught
--      error. Populated by a small logSystemError() helper added to
--      admin.html's existing try/catch blocks (non-invasive — the
--      catches already exist and already console.error(); this adds one
--      more line, it doesn't change what happens on failure) plus a
--      global window.onerror/unhandledrejection handler for anything
--      that slips past those. "Suggested Resolution" is a short static
--      lookup by source_type in the application, not stored per-row —
--      storing free-text advice per error would drift from the actual
--      fix the moment the code changes; a lookup table keyed by
--      source_type can be updated in one place instead.
--   2. security_events    — Part 6. Failed logins (both login.html and
--      employee/login.html), permission violations (RBAC.can() denials
--      the app already silently swallows today — this makes them
--      visible instead), and locked-account view reuses
--      employees.active directly rather than a new column.
--   3. maintenance_windows — Part 7. One row per maintenance window,
--      covering both "current state" and "history" with a single table
--      (status='active' right now = the current window; everything else
--      is the history Part 7 also asks for) rather than a separate
--      current-state singleton plus a log.
--   4. ops_alert_acks      — Part 9's "allow acknowledgement of alerts."
--      Alerts themselves are computed live (same reasoning as the
--      Financial Center's alerts — nothing to store or drift), but
--      "did the Owner already dismiss this one" needs to persist across
--      sessions, so each acknowledgement is one row keyed by a
--      deterministic alert_key the application derives from the alert's
--      own content (e.g. 'low_stock:14', 'workflow_backlog').
--   5. Indexes for the date/status/severity filtering every screen in
--      this phase does (Part 14).
--
-- Performance/DB-growth monitoring (Part 4) and Backup Readiness
-- (Part 8) need no new tables — both are read from Postgres system
-- catalogs (pg_stat_*, information_schema) and existing row counts at
-- query time, which is more honest than a stored snapshot that goes
-- stale. See the application code's own comments on exactly what's
-- queried for each.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. system_errors (Part 5)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.system_errors (
  id                 bigint generated always as identity primary key,
  severity           text not null default 'error' check (severity = any (array['info','warning','error','critical'])),
  source_type        text not null check (source_type = any (array[
                        'application','workflow','approval','realtime','permission',
                        'database','notification','sync'
                      ])),
  module             text,                 -- e.g. 'RewardsAdmin', 'Deliveries', 'FinancialCenter' — free text, matches admin.html's own module naming
  message            text not null,
  stack              text,
  context            jsonb not null default '{}'::jsonb,
  actor_employee_id  bigint references public.employees (id) on delete set null,
  status             text not null default 'open' check (status = any (array['open','acknowledged','resolved'])),
  resolved_by        text,
  resolved_at        timestamptz,
  created_at         timestamptz not null default now()
);

comment on table public.system_errors is
  'Phase 6.10 Part 5 — centralized error log, written by logSystemError() (added to existing catch blocks, non-invasively) and a global window.onerror/unhandledrejection handler in admin.html. "Suggested Resolution" is looked up by source_type in the app, not stored here — see this migration''s header.';

create index if not exists system_errors_created_at_idx on public.system_errors (created_at);
create index if not exists system_errors_status_idx on public.system_errors (status);
create index if not exists system_errors_severity_idx on public.system_errors (severity);

alter table public.system_errors enable row level security;

-- Any authenticated staff session may INSERT (an error can be thrown
-- from an Admin's or Manager's session too, not just the Owner's — the
-- log needs to capture it regardless of who hit it). Only Owner/Admin
-- may read or update status, matching Part 12.
drop policy if exists "system_errors_staff_insert" on public.system_errors;
create policy "system_errors_staff_insert"
  on public.system_errors for insert
  to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

drop policy if exists "system_errors_owner_admin_manage" on public.system_errors;
create policy "system_errors_owner_admin_manage"
  on public.system_errors for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));

drop policy if exists "system_errors_owner_admin_update" on public.system_errors;
create policy "system_errors_owner_admin_update"
  on public.system_errors for update
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 2. security_events (Part 6)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.security_events (
  id             bigint generated always as identity primary key,
  event_type     text not null check (event_type = any (array[
                    'failed_login','permission_violation','unauthorized_access',
                    'suspicious_activity','account_locked'
                  ])),
  severity       text not null default 'medium' check (severity = any (array['low','medium','high','critical'])),
  actor_identifier text,             -- email/phone attempted, when the person isn't a resolvable employee (e.g. a failed login before auth succeeds)
  employee_id    bigint references public.employees (id) on delete set null,
  portal         text,               -- 'admin' | 'employee' — which login surface / workspace this happened on
  details        jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);

comment on table public.security_events is
  'Phase 6.10 Part 6. Failed logins are written from login.html/employee/login.html themselves (before a session exists — see the anon insert policy below), everything else from within admin.html once a session exists.';

create index if not exists security_events_created_at_idx on public.security_events (created_at);
create index if not exists security_events_event_type_idx on public.security_events (event_type);

alter table public.security_events enable row level security;

-- Failed-login events are written by definition before the person has a
-- session — same trust model this project already uses for orders and
-- reward_redemption_requests (anon insert, staff-only read). The insert
-- payload here is narrow (an email/phone string, an event_type, a
-- timestamp) and cannot be used to read or affect anything else.
drop policy if exists "security_events_anon_insert" on public.security_events;
create policy "security_events_anon_insert"
  on public.security_events for insert
  to anon, authenticated
  with check (true);

drop policy if exists "security_events_owner_admin_read" on public.security_events;
create policy "security_events_owner_admin_read"
  on public.security_events for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 3. maintenance_windows (Part 7)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.maintenance_windows (
  id               bigint generated always as identity primary key,
  title            text not null,
  message          text not null,            -- shown to employees/customers while active
  status           text not null default 'scheduled' check (status = any (array['scheduled','active','completed','cancelled'])),
  scheduled_start  timestamptz not null,
  scheduled_end    timestamptz,
  started_at       timestamptz,
  ended_at         timestamptz,
  created_by       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on table public.maintenance_windows is
  'Phase 6.10 Part 7. The row with status=''active'' (if any) IS the current maintenance state — read by employee/index.html and products.html/customer-hub.html to show the friendly maintenance message Part 7 asks for. Every other row is history. Owner access is never blocked by this — see admin.html''s own maintenance-mode check, which explicitly exempts the Owner workspace.';

create index if not exists maintenance_windows_status_idx on public.maintenance_windows (status);

create or replace function public.set_maintenance_windows_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_maintenance_windows_updated_at on public.maintenance_windows;
create trigger trg_maintenance_windows_updated_at
  before update on public.maintenance_windows
  for each row execute function public.set_maintenance_windows_updated_at();

alter table public.maintenance_windows enable row level security;

-- Publicly readable — customer-facing pages and the Employee PWA both
-- need to check "is maintenance active" without a staff session, exactly
-- like they already read `announcements` and `settings` today.
drop policy if exists "maintenance_windows_public_read" on public.maintenance_windows;
create policy "maintenance_windows_public_read"
  on public.maintenance_windows for select to anon, authenticated using (true);

drop policy if exists "maintenance_windows_owner_write" on public.maintenance_windows;
create policy "maintenance_windows_owner_write"
  on public.maintenance_windows for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true));


-- ───────────────────────────────────────────────────────────────────────
-- 4. ops_alert_acks (Part 9)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.ops_alert_acks (
  id              bigint generated always as identity primary key,
  alert_key       text not null,            -- deterministic per alert, e.g. 'low_stock:14', 'workflow_backlog'
  acknowledged_by text,
  acknowledged_at timestamptz not null default now(),
  expires_at      timestamptz               -- null = until manually cleared; otherwise the alert re-fires after this (e.g. next day) even if the underlying condition persists
);

comment on table public.ops_alert_acks is
  'Phase 6.10 Part 9. An acknowledged alert stays acknowledged until expires_at (if set) or is cleared — computeOpsAlerts() in admin.html checks this table before showing an alert that was already dismissed.';

create index if not exists ops_alert_acks_alert_key_idx on public.ops_alert_acks (alert_key);

alter table public.ops_alert_acks enable row level security;

drop policy if exists "ops_alert_acks_owner_admin" on public.ops_alert_acks;
create policy "ops_alert_acks_owner_admin"
  on public.ops_alert_acks for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));
