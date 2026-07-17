-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 7.5.4A Step 2 Migration
-- Delivery Location Management — Admin Interface companion schema tweaks
-- ═══════════════════════════════════════════════════════════════════════
--
-- Step 1 (20260101000006) shipped delivery_service_locations,
-- delivery_campuses, the orders FK columns, RLS, and seed data. Building
-- the admin CRUD screen surfaced three small, additive gaps — nothing
-- here touches a column, index, or row that Step 1 already shipped:
--
--   1. "Archive instead of delete" needs somewhere to record it. Every
--      other soft-deletable table in this app (announcements, expenses,
--      approval_requests, notifications) uses a nullable `archived_at`
--      timestamp rather than a third boolean or a bigger status enum —
--      so that's what's added here, to both new tables. `active` keeps
--      its Step 1 meaning unchanged ("shown to customers right now");
--      `archived_at` is a separate, independent lifecycle state ("no
--      longer managed day-to-day, kept only for historical integrity").
--
--   2. "Prevent deleting locations referenced by historical orders" was
--      not actually enforced at the database level in Step 1 — both new
--      order FK columns were declared `on delete set null`, which would
--      silently null out historical attribution if a row were ever
--      deleted directly (e.g. via the SQL editor or a future script),
--      bypassing this admin UI entirely. They're switched to
--      `on delete restrict` here so the database itself refuses the
--      delete, independent of what any UI does or doesn't expose. (The
--      admin UI built in this phase never offers a delete button at
--      all — only Archive — so this is a defense-in-depth backstop, not
--      the primary mechanism.)
--
--   3. Duplicate-name prevention needs a DB-level backstop too (the UI
--      checks client-side, but two admins could race). Added as partial,
--      case-insensitive UNIQUE indexes that only consider non-archived
--      rows — so an archived "JKUAT" never blocks creating a fresh
--      active "JKUAT" later. This replaces Step 1's plain
--      `unique (service_location_id, name)` constraint on
--      delivery_campuses with the same case-insensitive, archived-aware
--      version, for consistency between the two tables.
--
-- Nothing here changes `orders.campus`, `branches`, or any other
-- existing table. Still database-only in spirit — this file plus the
-- admin.html changes described in the accompanying explanation are what
-- Step 2 delivers.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. archived_at — soft-delete lifecycle, same pattern as
--    announcements.archived_at / expenses / approval_requests
-- ───────────────────────────────────────────────────────────────────────
alter table public.delivery_service_locations
  add column if not exists archived_at timestamp with time zone;
alter table public.delivery_campuses
  add column if not exists archived_at timestamp with time zone;

comment on column public.delivery_service_locations.archived_at is
  'Phase 7.5.4A Step 2 — set when Owner/Admin archives this location instead of deleting it. Row is preserved for historical order integrity; archived locations are excluded from the management list''s default view and from duplicate-name checks against active rows.';
comment on column public.delivery_campuses.archived_at is
  'Phase 7.5.4A Step 2 — same soft-delete semantics as delivery_service_locations.archived_at, scoped to one campus.';


-- ───────────────────────────────────────────────────────────────────────
-- 2. Duplicate-name prevention — case-insensitive, archived rows excluded
-- ───────────────────────────────────────────────────────────────────────
alter table public.delivery_campuses
  drop constraint if exists delivery_campuses_location_name_key;

create unique index if not exists delivery_service_locations_name_active_uidx
  on public.delivery_service_locations (lower(name))
  where archived_at is null;

create unique index if not exists delivery_campuses_location_name_active_uidx
  on public.delivery_campuses (service_location_id, lower(name))
  where archived_at is null;


-- ───────────────────────────────────────────────────────────────────────
-- 3. Delete protection for locations/campuses referenced by real orders
-- ───────────────────────────────────────────────────────────────────────
alter table public.orders
  drop constraint if exists orders_service_location_id_fkey,
  add constraint orders_service_location_id_fkey
    foreign key (service_location_id) references public.delivery_service_locations (id) on delete restrict;

alter table public.orders
  drop constraint if exists orders_delivery_campus_id_fkey,
  add constraint orders_delivery_campus_id_fkey
    foreign key (delivery_campus_id) references public.delivery_campuses (id) on delete restrict;


-- ───────────────────────────────────────────────────────────────────────
-- 4. Refresh the options view so archived rows never leak into it
--    (Step 1's version only checked campus `active`/location `active`;
--    an archived-but-still-active-flagged row could otherwise appear)
-- ───────────────────────────────────────────────────────────────────────
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
  and c.archived_at is null
  and sl.display_mode in ('campus_only', 'university_campus')
where sl.active = true
  and sl.archived_at is null
order by sl.display_order, sl.name, c.display_order, c.name;
