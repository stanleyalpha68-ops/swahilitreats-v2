-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 6.7 Migration
-- Mobile Workforce Platform — Employee Devices (Part 5 + Part 8)
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste into the Supabase SQL Editor and run once. Additive only.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ALREADY EXISTED (checked before writing this)
-- ───────────────────────────────────────────────────────────────────────
-- The Admin side already has real, working Web Push: admin.html
-- subscribes via the standard Push API (no Firebase involved — this
-- project never needed it) and upserts { endpoint, keys, user_agent }
-- into an existing `push_subscriptions` table, keyed by endpoint only.
-- admin-sw.js already has working install/activate/fetch/push/
-- notificationclick handlers.
--
-- The Employee Portal (employee/index.html) has zero PWA wiring today —
-- no manifest link, no service worker registration, nothing. Part 1's
-- premise is accurate: it needs to be built from scratch.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHY A NEW TABLE INSTEAD OF REUSING push_subscriptions
-- ───────────────────────────────────────────────────────────────────────
-- push_subscriptions has no employee_id (or any owner) column — it's an
-- anonymous endpoint→keys map. That's fine for the single shared Admin
-- inbox, but Part 8 explicitly asks for per-employee, per-device fields
-- (Registered Device, Last Active, Platform, Browser, App Version, Push
-- Token) that don't fit an ownerless table without retrofitting a live
-- one. So employee_devices is its own table — one row per employee per
-- installed device — and happens to reuse the exact same subscribe()
-- call shape (endpoint + keys) as push_subscriptions, so a future phase
-- that actually sends pushes can treat both tables identically.
--
-- Per Part 5 and Part 8: this migration only stores what's needed for
-- devices to register themselves and for a future phase to send to
-- them. Nothing here sends a push, and nothing here restricts device
-- access — nothing in Part 8 asked for that yet.
-- ═══════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
-- CORRECTION — employees.id is bigint, not uuid
-- ───────────────────────────────────────────────────────────────────────
-- The first version of this migration typed employee_id as uuid,
-- confusing employees.id (bigint, the primary key every other table's
-- employee_id foreign key already points at — see employee_inventory,
-- inventory_transactions, notifications, audit_log, etc.) with
-- employees.user_id (uuid, the Supabase Auth link, used only for RLS
-- "is this the signed-in user's own row" checks, never as a foreign key
-- target elsewhere in this schema). Fixed below to match every other
-- employee_id column in the project.
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists public.employee_devices (
  id             bigint generated always as identity primary key,
  employee_id    bigint not null references public.employees (id) on delete cascade,
  device_label   text,                     -- e.g. "Chrome on Android" — derived client-side, editable later
  platform       text,                     -- 'android' | 'ios' | 'desktop' | 'unknown' (from navigator/UA hints)
  browser        text,
  app_version    text,                     -- matches EMPLOYEE_APP_VERSION in employee/index.html at registration time
  push_endpoint  text unique,              -- null until the employee grants notification permission
  push_keys      jsonb,                    -- { p256dh, auth } — same shape as push_subscriptions.keys
  user_agent     text,
  registered_at  timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  is_active      boolean not null default true
);

comment on table public.employee_devices is
  'One row per employee device that has opened the Employee PWA (Part 8 Device Readiness). Populated by initializePWA()/registerServiceWorker() in employee/index.html on every load (last_active_at bump) and by the push-subscribe flow (push_endpoint/push_keys) when granted. Nothing reads push_endpoint to actually send a push yet — see this file''s header.';

create index if not exists employee_devices_employee_id_idx on public.employee_devices (employee_id);

create or replace function public.set_employee_devices_last_active()
returns trigger language plpgsql as $$ begin new.last_active_at = now(); return new; end; $$;

drop trigger if exists trg_employee_devices_last_active on public.employee_devices;
create trigger trg_employee_devices_last_active
  before update on public.employee_devices
  for each row execute function public.set_employee_devices_last_active();

alter table public.employee_devices enable row level security;

-- An employee may only see/manage their own device rows.
drop policy if exists "employee_devices_own_rows" on public.employee_devices;
create policy "employee_devices_own_rows"
  on public.employee_devices for all
  to authenticated
  using (exists (select 1 from public.employees e where e.id = employee_devices.employee_id and e.user_id = auth.uid()))
  with check (exists (select 1 from public.employees e where e.id = employee_devices.employee_id and e.user_id = auth.uid()));

-- Owner/Admin can read every device — Part 8's "prepare the architecture
-- for future device management" needs this even though no management
-- screen is built this phase.
drop policy if exists "employee_devices_staff_read" on public.employee_devices;
create policy "employee_devices_staff_read"
  on public.employee_devices for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));
