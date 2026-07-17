-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 7.5.4A Migration
-- Delivery Location Management (database architecture only)
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Purely additive: two new tables, two new nullable columns on the
-- existing `orders` table, one new view. Nothing existing is altered
-- destructively, nothing dropped, nothing renamed.
--
-- SCOPE OF THIS PHASE (per the brief)
-- Database architecture ONLY. products.html's checkout form still posts
-- the old hard-coded <select> (Main Campus / Chiromo Campus / Lower
-- Kabete Campus) into `orders.campus` exactly as it does today. Nothing
-- in this migration changes that, and nothing in this migration requires
-- it to change before this can be safely run. Wiring the checkout UI to
-- read from the tables below, and building the Owner/Admin config screen,
-- are separate future phases.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ALREADY EXISTS (read this first)
-- ───────────────────────────────────────────────────────────────────────
-- `orders.campus` is free text, populated today from a hard-coded
-- <select> in products.html with exactly three values: "Main Campus",
-- "Chiromo Campus", "Lower Kabete Campus". `public.branches` (Phase 7.0)
-- is a *different* concept: it represents the business's own operating
-- units — the physical kitchen/ops locations that fulfil orders, own
-- inventory, employ staff, and get attributed revenue in
-- get_branch_performance(). A branch does not need to correspond 1:1
-- with a customer-facing delivery area, and today there may be only one
-- (or zero) real branch rows even though the business already delivers
-- to three distinct campuses. This phase does NOT touch `branches` and
-- does NOT require any branch rows to exist.
--
-- ───────────────────────────────────────────────────────────────────────
-- ARCHITECTURE
-- ───────────────────────────────────────────────────────────────────────
-- Two new tables model the two levels the business asked for:
--
--   delivery_service_locations  ("Service Location" — a University or a
--                                 named delivery area, e.g. "University
--                                 of Nairobi", "JKUAT", "Nairobi CBD")
--     └── delivery_campuses      (specific delivery points under a
--                                 location, e.g. "Lower Kabete",
--                                 "Main Campus", "Chiromo")
--
-- `display_mode` lives on delivery_service_locations because the brief
-- is explicit that the mode is a property of how a *location* is
-- configured, not something the customer ever chooses:
--
--   'campus_only'       → customer sees only the campus list; the
--                          service location's own name is never shown.
--                          (This is what the business runs today, three
--                          campuses under one implicit, unlabeled
--                          University of Nairobi — see seed data below.)
--   'university_only'   → customer sees only the location name and picks
--                          nothing underneath it. This location should
--                          have zero customer-facing campus rows.
--   'university_campus'  → customer sees the location name, then picks
--                          one of its campuses underneath.
--
-- Reuse, not duplication, of branch data: both new tables carry an
-- OPTIONAL, nullable `branch_id` pointing at the existing
-- `public.branches` table. That FK is how a service location or an
-- individual campus can be attributed to a real operating branch for
-- fulfilment/analytics purposes — WITHOUT copying any branch column
-- (name, address, phone, etc.) onto the new tables and without requiring
-- one to exist. Nothing in `branches` is duplicated; nothing in
-- `branches` is modified.
--
-- Backward compatibility for orders: two new nullable FK columns are
-- added to `orders` (`service_location_id`, `delivery_campus_id`). The
-- existing `orders.campus` text column is untouched — every existing
-- row, every existing query (`.select("...campus...")`), and every
-- existing analytics rollup that groups by `o.campus` keeps working
-- exactly as-is, because nothing about that column changed. The new
-- columns are simply unpopulated (NULL) for all historical rows and for
-- any order placed before the checkout form is migrated in a future
-- phase. Only once products.html is updated to read from these new
-- tables would new orders start populating them, alongside — not
-- instead of — the legacy `campus` text, so nothing downstream breaks
-- mid-migration either.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION ADDS
-- ───────────────────────────────────────────────────────────────────────
--   1. delivery_service_locations — the University/Area level, with
--      display_mode, active flag, display_order, optional branch_id.
--   2. delivery_campuses — the Campus level, scoped to a service
--      location, with its own active flag, display_order, optional
--      branch_id, optional GPS (mirrors branches.gps_lat/gps_lng).
--   3. orders.service_location_id / orders.delivery_campus_id — nullable
--      FKs, additive only.
--   4. public.delivery_location_options — a read-only view that flattens
--      active locations + their active campuses into the exact shape a
--      future checkout dropdown needs in one query. No UI reads it yet.
--   5. RLS on both new tables, following the same pattern already used
--      for other public-facing reference data (`products`,
--      `announcements`): anon + authenticated can read active rows only
--      (needed the moment a future checkout page queries this directly);
--      staff (any row in `employees`) can read everything, including
--      inactive/draft locations; only Owner/Admin can write — same
--      `current_employee_is_owner() / current_employee_role()` helper
--      functions introduced in Phase 7.5.1B, reused here rather than
--      re-implemented.
--   6. Seed data — the business's three real, currently-fixed campuses,
--      inserted as a single 'campus_only' service location so the
--      *current* customer-visible behavior (no university shown, three
--      flat campus choices) is reproduced exactly, with names matching
--      products.html's existing option values verbatim so a future
--      backfill/join against historical `orders.campus` text is a
--      straightforward equality match.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. delivery_service_locations
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.delivery_service_locations (
  id             bigint generated always as identity primary key,
  name           text not null,                       -- e.g. "University of Nairobi", "JKUAT"
  slug           text unique,                          -- optional stable key for future code references
  display_mode   text not null default 'campus_only'
                 check (display_mode in ('campus_only', 'university_only', 'university_campus')),
  active         boolean not null default true,
  display_order  integer not null default 0 check (display_order >= 0),
  branch_id      bigint references public.branches (id) on delete set null,  -- optional: whole location fulfilled by one branch
  notes          text,
  created_by     text,
  created_at     timestamp with time zone not null default now(),
  updated_at     timestamp with time zone not null default now()
);

comment on table public.delivery_service_locations is
  'Phase 7.5.4A — top-level delivery area (a University or named zone). display_mode is set only by Owner/Admin and controls what the customer sees; the customer never chooses it. Optional branch_id links this location to an existing public.branches row for fulfilment/analytics — does not duplicate branch data.';
comment on column public.delivery_service_locations.display_mode is
  'campus_only: show campus list, hide this location''s name. university_only: show only this location''s name, no campus picker (should have zero customer-facing campus rows). university_campus: show this location''s name, then its campuses.';


-- ───────────────────────────────────────────────────────────────────────
-- 2. delivery_campuses
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.delivery_campuses (
  id                  bigint generated always as identity primary key,
  service_location_id bigint not null references public.delivery_service_locations (id) on delete cascade,
  name                text not null,                   -- e.g. "Lower Kabete", "Main Campus", "Chiromo"
  code                text,                             -- optional short code, unique per location
  active              boolean not null default true,
  display_order       integer not null default 0 check (display_order >= 0),
  branch_id           bigint references public.branches (id) on delete set null,  -- optional: this specific campus fulfilled by one branch
  gps_lat             numeric,
  gps_lng             numeric,
  created_by          text,
  created_at          timestamp with time zone not null default now(),
  updated_at          timestamp with time zone not null default now(),
  constraint delivery_campuses_location_name_key unique (service_location_id, name)
);

comment on table public.delivery_campuses is
  'Phase 7.5.4A — specific delivery point under a delivery_service_locations row. Optional branch_id links this campus to an existing public.branches row for fulfilment/analytics — does not duplicate branch data. For a university_only location this table should hold zero customer-facing rows.';

create index if not exists delivery_campuses_service_location_id_idx
  on public.delivery_campuses (service_location_id);


-- ───────────────────────────────────────────────────────────────────────
-- 3. orders — additive, nullable FK columns only
-- ───────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists service_location_id bigint references public.delivery_service_locations (id) on delete set null;
alter table public.orders
  add column if not exists delivery_campus_id bigint references public.delivery_campuses (id) on delete set null;

comment on column public.orders.service_location_id is
  'Phase 7.5.4A — optional FK, populated only once checkout is migrated to the new location picker. The legacy orders.campus text column is untouched and remains the source of truth for all existing rows and existing analytics.';
comment on column public.orders.delivery_campus_id is
  'Phase 7.5.4A — optional FK companion to service_location_id. NULL for every historical order and for any order placed before checkout is migrated.';

create index if not exists orders_service_location_id_idx on public.orders (service_location_id);
create index if not exists orders_delivery_campus_id_idx on public.orders (delivery_campus_id);


-- ───────────────────────────────────────────────────────────────────────
-- 4. updated_at maintenance (same lightweight pattern as media_files)
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.delivery_locations_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_service_locations_updated_at on public.delivery_service_locations;
create trigger trg_service_locations_updated_at
  before update on public.delivery_service_locations
  for each row execute function public.delivery_locations_set_updated_at();

drop trigger if exists trg_campuses_updated_at on public.delivery_campuses;
create trigger trg_campuses_updated_at
  before update on public.delivery_campuses
  for each row execute function public.delivery_locations_set_updated_at();


-- ───────────────────────────────────────────────────────────────────────
-- 5. RLS — same posture already used for products/announcements
-- ───────────────────────────────────────────────────────────────────────
alter table public.delivery_service_locations enable row level security;

drop policy if exists "dsl_public_read" on public.delivery_service_locations;
create policy "dsl_public_read" on public.delivery_service_locations for select to anon, authenticated
  using (active = true);

drop policy if exists "dsl_staff_full_read" on public.delivery_service_locations;
create policy "dsl_staff_full_read" on public.delivery_service_locations for select to authenticated
  using (public.current_employee_id() is not null);

drop policy if exists "dsl_admin_write" on public.delivery_service_locations;
create policy "dsl_admin_write" on public.delivery_service_locations for all to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin')
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');

alter table public.delivery_campuses enable row level security;

drop policy if exists "dc_public_read" on public.delivery_campuses;
create policy "dc_public_read" on public.delivery_campuses for select to anon, authenticated
  using (active = true);

drop policy if exists "dc_staff_full_read" on public.delivery_campuses;
create policy "dc_staff_full_read" on public.delivery_campuses for select to authenticated
  using (public.current_employee_id() is not null);

drop policy if exists "dc_admin_write" on public.delivery_campuses;
create policy "dc_admin_write" on public.delivery_campuses for all to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin')
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');


-- ───────────────────────────────────────────────────────────────────────
-- 6. Read-only convenience view for a future checkout picker
-- ───────────────────────────────────────────────────────────────────────
-- Flattens active locations + their active campuses into one row per
-- selectable option, in display_order. Not consumed by any page yet —
-- provided now so the future checkout UI has a single, already-correct
-- query to call instead of re-deriving display_mode logic client-side.
create or replace view public.delivery_location_options as
select
  sl.id                  as service_location_id,
  sl.name                as service_location_name,
  sl.display_mode,
  sl.display_order        as service_location_display_order,
  c.id                    as campus_id,
  c.name                  as campus_name,
  c.display_order         as campus_display_order
from public.delivery_service_locations sl
left join public.delivery_campuses c
  on c.service_location_id = sl.id
  and c.active = true
  and sl.display_mode in ('campus_only', 'university_campus')
where sl.active = true
order by sl.display_order, sl.name, c.display_order, c.name;

comment on view public.delivery_location_options is
  'Phase 7.5.4A — read-only, flattened active locations + active campuses for a future checkout picker. For university_only rows, campus_id/campus_name are NULL by construction (no join performed for that mode) — the checkout UI should show just service_location_name with no sub-picker.';


-- ───────────────────────────────────────────────────────────────────────
-- 7. Seed data — reproduce today's live behavior exactly
-- ───────────────────────────────────────────────────────────────────────
-- One service location, mode 'campus_only', so its own name is never
-- shown to the customer — matching the fact that no university name is
-- displayed today. Campus names match products.html's <option> values
-- verbatim (including the "Campus" suffix already baked into two of the
-- three) so a future text-to-FK backfill of historical orders.campus
-- values can match on exact string equality.
insert into public.delivery_service_locations (name, slug, display_mode, active, display_order, notes)
select 'University of Nairobi', 'uon', 'campus_only', true, 1,
       'Seeded by Phase 7.5.4A from the three hard-coded options in products.html. display_mode=campus_only reproduces current behavior: no university name shown to customers, flat campus list only.'
where not exists (
  select 1 from public.delivery_service_locations where slug = 'uon'
);

insert into public.delivery_campuses (service_location_id, name, display_order)
select sl.id, v.name, v.ord
from public.delivery_service_locations sl
cross join (values
  ('Main Campus', 1),
  ('Chiromo Campus', 2),
  ('Lower Kabete Campus', 3)
) as v(name, ord)
where sl.slug = 'uon'
  and not exists (
    select 1 from public.delivery_campuses c
    where c.service_location_id = sl.id and c.name = v.name
  );
