-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 7.5.4A Step 3 Migration
-- Delivery Location Management — Customer Checkout Integration (backend)
-- ═══════════════════════════════════════════════════════════════════════
--
-- Step 1 (...06) shipped the tables/columns/RLS/seed data. Step 2
-- (...07) shipped the Owner/Admin CRUD screen. This migration is the
-- database-side companion to Step 3: wiring products.html's checkout to
-- the new tables. Nothing here changes `orders.campus`, `branches`, or
-- any existing table shape — additive only, same as Steps 1 & 2.
--
-- WHAT THIS SHIPS
--   1. Two new nullable `branch_id` — already existed on both tables
--      since Step 1; this migration just adds lookup indexes for them,
--      since they're about to be read on every single checkout insert
--      (via the trigger in #2) instead of only occasionally from the
--      admin screen.
--   2. `branch_auto_assign_order()` (Phase 7.0 Part 4) is extended, not
--      replaced: it now prefers an explicit Owner/Admin-configured link
--      — `delivery_campuses.branch_id`, then `delivery_service_locations
--      .branch_id` — over the legacy exact campus-text guess. The text
--      guess is untouched and still runs, unchanged, whenever neither
--      new column is populated (which is true for every historical
--      order and for the seeded UoN campuses today) — so this is a
--      strict superset of the old behavior, never a regression.
--   3. A new validation trigger enforces, at the database level and
--      independent of any client, the three things the checkout brief
--      calls out: a delivery_campus_id must belong to the
--      service_location_id on the same row (no mismatched pairs), and
--      neither id may point at a location/campus that's inactive or
--      archived. Anon can already only ever *see* active rows (RLS from
--      Step 1), so a well-behaved client can't trigger this — this is a
--      defense-in-depth backstop against a forged/stale request, same
--      spirit as Step 2's `on delete restrict` backstop.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. Indexes for the branch_id lookups the trigger below now performs
--    on every order insert
-- ───────────────────────────────────────────────────────────────────────
create index if not exists delivery_campuses_branch_id_idx
  on public.delivery_campuses (branch_id);
create index if not exists delivery_service_locations_branch_id_idx
  on public.delivery_service_locations (branch_id);


-- ───────────────────────────────────────────────────────────────────────
-- 2. branch_auto_assign_order() — extended with explicit-link priority
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.branch_auto_assign_order()
returns trigger language plpgsql as $$
declare
  v_enabled boolean;
  v_branch_id bigint;
begin
  if new.branch_id is not null then
    return new;
  end if;

  -- Phase 7.5.4A Step 3: an explicit link set by the Owner/Admin in the
  -- Delivery Locations screen is a deliberate configuration choice, not
  -- a heuristic — so, unlike the legacy text-match fallback below, it's
  -- not gated by the auto_assign_orders_by_campus business rule.
  if new.delivery_campus_id is not null then
    select branch_id into v_branch_id
      from public.delivery_campuses where id = new.delivery_campus_id;
    if v_branch_id is not null then
      new.branch_id := v_branch_id;
      return new;
    end if;
  end if;

  if new.service_location_id is not null then
    select branch_id into v_branch_id
      from public.delivery_service_locations where id = new.service_location_id;
    if v_branch_id is not null then
      new.branch_id := v_branch_id;
      return new;
    end if;
  end if;

  -- Legacy fallback — unchanged from Phase 7.0 Part 4: exact campus-text
  -- match against branches.campus, only when it's unambiguous (exactly
  -- one active/opening_soon branch matches), only when the business
  -- rule is switched on.
  select coalesce((rules->>'auto_assign_orders_by_campus')::boolean, false)
    into v_enabled from public.business_rules where category = 'branch_automation';

  if v_enabled and new.campus is not null then
    if (select count(*) from public.branches b where b.campus = new.campus and b.status in ('active', 'opening_soon')) = 1 then
      select b.id into v_branch_id from public.branches b
        where b.campus = new.campus and b.status in ('active', 'opening_soon');
      new.branch_id := v_branch_id;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_branch_auto_assign_order on public.orders;
create trigger trg_branch_auto_assign_order
  before insert on public.orders
  for each row execute function public.branch_auto_assign_order();


-- ───────────────────────────────────────────────────────────────────────
-- 3. Validation trigger — mismatched pairs / inactive / archived rows
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.validate_order_delivery_location()
returns trigger language plpgsql as $$
declare
  v_parent_location_id bigint;
begin
  if new.delivery_campus_id is not null then
    select service_location_id into v_parent_location_id
      from public.delivery_campuses
      where id = new.delivery_campus_id and active = true and archived_at is null;

    if not found then
      raise exception 'Selected delivery campus (id=%) is not currently active', new.delivery_campus_id;
    end if;

    if new.service_location_id is not null and v_parent_location_id is distinct from new.service_location_id then
      raise exception 'delivery_campus_id % does not belong to service_location_id %', new.delivery_campus_id, new.service_location_id;
    end if;
  end if;

  if new.service_location_id is not null then
    perform 1 from public.delivery_service_locations
      where id = new.service_location_id and active = true and archived_at is null;
    if not found then
      raise exception 'Selected delivery location (id=%) is not currently active', new.service_location_id;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_order_delivery_location on public.orders;
create trigger trg_validate_order_delivery_location
  before insert or update on public.orders
  for each row execute function public.validate_order_delivery_location();
