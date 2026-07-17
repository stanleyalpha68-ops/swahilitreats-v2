-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 7.5.4A Step 4 Migration
-- Delivery Location Management — Final Validation Fix
-- ═══════════════════════════════════════════════════════════════════════
--
-- Step 4 is verification/hardening only, not a redesign. This migration
-- fixes exactly one gap found during final validation: the explicit
-- Linked Branch path added in Step 3 did not re-check branch eligibility
-- at order time.
--
-- THE GAP
-- `branches.active` is kept in sync with `branches.status` by an
-- existing Phase 7.0 trigger (`new.active := new.status in ('active',
-- 'opening_soon')`), and the legacy campus-text fallback in
-- branch_auto_assign_order() has always filtered on that eligibility
-- (`b.status in ('active','opening_soon')`, count = 1). The Step 3
-- explicit-link branches (`delivery_campuses.branch_id` /
-- `delivery_service_locations.branch_id`) did NOT re-check this at
-- insert time — an Owner/Admin could link a branch while it was active,
-- the branch could later close, and new orders would silently keep
-- routing to it since the FK itself is only cleared by `on delete set
-- null` (branch row deletion), not by a later status change.
--
-- THE FIX
-- `branch_auto_assign_order()` is redefined (not replaced in shape —
-- same signature, same trigger, same priority order: explicit campus
-- link, then explicit location link, then legacy text match) to only
-- use an explicit link when the linked branch is currently eligible
-- (`active = true`, kept correct by the existing Phase 7.0 sync
-- trigger). An explicit link to a branch that has since closed is
-- skipped — falling through to the next priority level — instead of
-- silently assigning orders to an ineligible branch.
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.branch_auto_assign_order()
returns trigger language plpgsql as $$
declare
  v_enabled boolean;
  v_branch_id bigint;
begin
  if new.branch_id is not null then
    return new;
  end if;

  -- Explicit campus-level link — only honoured while the linked branch
  -- is currently eligible (active = true, synced from status by the
  -- existing Phase 7.0 trigger). An ineligible link falls through to
  -- the next priority level below rather than assigning a closed branch.
  if new.delivery_campus_id is not null then
    select branch_id into v_branch_id
      from public.delivery_campuses where id = new.delivery_campus_id;
    if v_branch_id is not null
       and exists (select 1 from public.branches where id = v_branch_id and active = true) then
      new.branch_id := v_branch_id;
      return new;
    end if;
  end if;

  -- Explicit location-level link — same eligibility gate.
  if new.service_location_id is not null then
    select branch_id into v_branch_id
      from public.delivery_service_locations where id = new.service_location_id;
    if v_branch_id is not null
       and exists (select 1 from public.branches where id = v_branch_id and active = true) then
      new.branch_id := v_branch_id;
      return new;
    end if;
  end if;

  -- Legacy fallback — unchanged from Phase 7.0 Part 4 / Step 3: exact
  -- campus-text match against branches.campus, only when it's
  -- unambiguous (exactly one active/opening_soon branch matches), only
  -- when the business rule is switched on.
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

-- Trigger itself is unchanged (same name, same timing) — recreating it
-- is not required since only the function body changed, but included
-- here for clarity/idempotency in case this file is ever run standalone.
drop trigger if exists trg_branch_auto_assign_order on public.orders;
create trigger trg_branch_auto_assign_order
  before insert on public.orders
  for each row execute function public.branch_auto_assign_order();
