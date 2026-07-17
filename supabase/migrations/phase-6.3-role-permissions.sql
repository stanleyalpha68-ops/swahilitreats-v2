-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 6.3 Migration
-- Access Control & Workspace Separation
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Additive only — nothing existing is altered, renamed, or dropped.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS PHASE ACTUALLY NEEDED FROM THE DATABASE
-- ───────────────────────────────────────────────────────────────────────
-- Phase 6.3 is mostly a *frontend* restructuring: the same tabs/modules
-- that already exist (Orders, Products, Inventory, Employees, Executive
-- Dashboard, Business Rules, Settings, …) get grouped into per-role
-- workspaces with their own navigation, a workspace picker for the
-- Owner, and a centralized permission engine — see admin.html's new
-- MODULE_REGISTRY / PermissionEngine. None of that requires new tables;
-- it's a new layer on top of the PERMISSIONS object and RBAC.can() that
-- already govern tab access today.
--
-- One thing genuinely belongs in the database, though: Part 6 asks that
-- the permission engine "avoid hardcoded permission checks" and "support
-- future custom permissions" — i.e. eventually, which roles can reach
-- which modules should be data, not just a JS object literal. This
-- migration adds that table, `role_permissions`, seeded to mirror
-- today's real behavior exactly.
--
-- Importantly: admin.html's PermissionEngine.loadPermissions() treats
-- this table as an *optional, currently-informational* overlay — if it's
-- empty, missing, or unreachable, every permission check falls straight
-- back to the existing hardcoded PERMISSIONS object and MODULE_REGISTRY,
-- so nothing about today's access behavior changes because of this
-- migration by itself. That's deliberate: flipping real enforcement over
-- to be fully data-driven is exactly the kind of change that deserves
-- its own careful phase (Part 12's "future compatibility," not "do it
-- now") — this migration just lays the table so that future phase is a
-- data change, not a schema one.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHY NO OTHER TABLE GOT NEW RLS THIS PHASE
-- ───────────────────────────────────────────────────────────────────────
-- Part 10 asks for backend enforcement, not just hidden buttons — and
-- wherever this migration COULD add that safely, it does (see below).
-- But retrofitting RLS onto `orders`, `employees`, `products`, etc. now,
-- with no staging environment to verify against, risks silently breaking
-- core flows this project has explicitly protected across five phases —
-- customer checkout, the delivery workflow, admin employee management —
-- for all of which today's access pattern (the anon key, wide open) is
-- an existing, load-bearing assumption. That's a genuine, larger
-- undertaking (most likely: introduce it gradually, table by table, with
-- real testing at each step) rather than something to bolt on as a side
-- effect of a navigation redesign. Where this phase CAN add real,
-- narrowly-scoped protection — a brand new table nothing else depends on
-- yet — it does, following the same pattern Phase 6.2 established for
-- `business_rules`.
--
-- ───────────────────────────────────────────────────────────────────────
-- 1. role_permissions
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.role_permissions (
  id          bigint generated always as identity primary key,
  role        text not null,
  module_key  text not null,
  can_access  boolean not null default true,
  updated_at  timestamptz not null default now(),
  unique (role, module_key)
);

comment on table public.role_permissions is
  'Optional, data-driven overlay for which roles can access which modules. admin.html''s PermissionEngine currently treats this as informational and falls back to its built-in PERMISSIONS/MODULE_REGISTRY whenever this table is empty or unreachable — see Phase 6.3''s migration notes for why.';

create index if not exists role_permissions_role_idx on public.role_permissions (role);

create or replace function public.set_role_permissions_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_role_permissions_updated_at on public.role_permissions;
create trigger trg_role_permissions_updated_at
  before update on public.role_permissions
  for each row
  execute function public.set_role_permissions_updated_at();

-- Row Level Security — same real, auth.uid()-based enforcement pattern
-- introduced in Phase 6.2 for business_rules. Unlike business_rules,
-- SELECT is restricted to authenticated staff (not anon) — no
-- customer-facing, logged-out page has any reason to read this table.
alter table public.role_permissions enable row level security;

drop policy if exists "role_permissions_staff_read" on public.role_permissions;
create policy "role_permissions_staff_read"
  on public.role_permissions
  for select
  to authenticated
  using (true);

drop policy if exists "role_permissions_owner_write" on public.role_permissions;
create policy "role_permissions_owner_write"
  on public.role_permissions
  for all
  to authenticated
  using (
    exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true)
  )
  with check (
    exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true)
  );


-- ───────────────────────────────────────────────────────────────────────
-- 2. Seed — mirrors admin.html's existing PERMISSIONS object and the new
-- MODULE_REGISTRY's workspace assignments exactly, so turning this table
-- into the live source of truth later starts from parity with today's
-- real behavior, not a guess.
-- ───────────────────────────────────────────────────────────────────────
insert into public.role_permissions (role, module_key, can_access) values
  ('admin',   'orders',        true), ('manager', 'orders',        true),
  ('admin',   'products',      true),
  ('admin',   'announcements', true), ('manager', 'announcements', true),
  ('admin',   'analytics',     true),
  ('admin',   'customers',     true),
  ('admin',   'inventory',     true), ('manager', 'inventory',     true),
  ('admin',   'invreports',    true), ('manager', 'invreports',    true),
  ('admin',   'discounts',     true),
  ('admin',   'variants',      true),
  ('admin',   'employees',     true), ('manager', 'employees',     true),
  ('admin',   'executive',     true),
  ('admin',   'settings',      true),
  ('owner',   'businessrules', true)
on conflict (role, module_key) do nothing;


-- ───────────────────────────────────────────────────────────────────────
-- That's the whole migration. See admin.html's MODULE_REGISTRY and
-- PermissionEngine for how workspaces, navigation, and route guards are
-- built on top of this plus the existing PERMISSIONS/RBAC system.
-- ───────────────────────────────────────────────────────────────────────
