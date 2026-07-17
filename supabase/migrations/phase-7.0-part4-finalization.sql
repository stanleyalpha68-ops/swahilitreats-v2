-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 7.0 (Part 4/4, FINAL) Migration
-- Enterprise Branch Integration, Automation & Finalization
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Run AFTER Parts 1, 2, and 3's migrations — this references `branches`,
-- `orders.branch_id`, `employees.branch_id`, and `audit_log`. Additive
-- only.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ALREADY EXISTS — READ THIS BEFORE ASSUMING ANYTHING NEW IS NEEDED
-- ───────────────────────────────────────────────────────────────────────
-- Branch Timeline (Part 3) needs NO new table. `audit_log` (Phase 6.5)
-- already records every branch-relevant action from Parts 1–3
-- (branch_initialized, employee_transferred, inventory_transferred,
-- branch_goal_created, etc.) with entity_type/entity_id/new_values —
-- and it's already append-only with no UI update path, so "timeline
-- entries must never be editable" is already true today, for free. The
-- application code for this part queries audit_log directly rather than
-- duplicating it into a parallel table.
--
-- Branch Operational Health (Part 2) mostly already exists too — Phase
-- 7.0 Part 2 built a Capacity sub-tab with Employees Available/Active
-- Deliveries/Orders Waiting/Inventory Health/Manager Assigned/Delivery
-- Coverage. Per this phase's own "remove duplicate logic" completion
-- requirement, that screen is EXTENDED with the additional dimensions
-- Part 2 of this phase asks for (Customer Satisfaction, Revenue Health,
-- Workflow Health, Realtime/Notification Status) rather than building a
-- second health screen next to it.
--
-- The existing `announcements` table (used by products.html for
-- customer-facing site-wide notices) is NOT reused for Part 5 — it has
-- no branch targeting and is customer-facing by design; repurposing it
-- would change what every existing customer-facing page shows. Branch
-- communication gets its own table below.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION ADDS
-- ───────────────────────────────────────────────────────────────────────
--   1. branches — new columns for Part 6's expanded settings (order
--      capacity, inventory thresholds, manager permission overrides,
--      announcement preferences, a theme placeholder) that didn't exist
--      after Parts 1–3.
--   2. branch_announcements — Part 5. Delivery reuses the existing
--      `notifications` table exactly as-is (one row per targeted
--      employee) — this table is the durable record/composer source
--      (priority, expiry, target branches), not a second delivery path.
--   3. branch_documents — Part 4, architecture only. Owner-upload-only,
--      no external document/storage integration, per the brief.
--   4. branch_config_snapshots — Part 7's Disaster Recovery
--      architecture: Configuration Export/Import/Restore Points. Holds
--      a JSON snapshot of a branch's own settings row — not a database
--      backup (that's Phase 6.10's existing, separately-scoped Backup
--      Readiness section in the Operations Center, not duplicated here).
--   5. business_rules('branch_automation') — Part 1's six automation
--      rules, all OFF by default and all individually toggleable, so
--      nothing in this migration silently changes existing branch
--      behavior the moment it's run.
--   6. Two real triggers — the two automation rules from Part 1 that are
--      genuinely safe and correct to run as an always-on DB trigger
--      (no judgment call, no dynamic threshold, just "keep two fields in
--      sync"). The other four automation rules are threshold/judgment
--      based (overload, low inventory, archival timing) and are computed
--      in the application when the Owner has the relevant screen open —
--      see PART 1's own application-code comment for why that's the
--      honest boundary in a browser-only architecture with no scheduled
--      server process, the same limitation already disclosed for Phase
--      6.10's alerts and Phase 7.0 Part 3's performance notifications.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. branches — Part 6 settings expansion
-- ───────────────────────────────────────────────────────────────────────
alter table public.branches add column if not exists order_capacity integer;              -- max concurrent open orders before "overloaded" — null = no cap configured
alter table public.branches add column if not exists inventory_thresholds jsonb not null default '{}'::jsonb;  -- per-category low-stock overrides, e.g. {"sweets": 15}; branch_inventory.low_stock_threshold (Part 2) remains the per-product source of truth
alter table public.branches add column if not exists manager_permissions jsonb not null default '{}'::jsonb;   -- branch-scoped permission overrides for this branch's manager — read by the Permission Engine, not a second engine
alter table public.branches add column if not exists announcement_preferences jsonb not null default '{"notify_manager": true, "notify_employees": true}'::jsonb;
alter table public.branches add column if not exists theme jsonb not null default '{}'::jsonb;   -- Part 6 "Branch Theme (future placeholder)" — unused until a per-branch UI skin exists

comment on column public.branches.manager_permissions is
  'Phase 7.0 Part 4 — overrides layered on top of the global Permission Engine for this branch''s manager (e.g. {"can_approve_transfers": true}). Reused by RBAC checks in admin.html, not a parallel permission system.';


-- ───────────────────────────────────────────────────────────────────────
-- 2. branch_announcements (Part 5)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.branch_announcements (
  id            bigint generated always as identity primary key,
  title         text not null,
  message       text not null,
  priority      text not null default 'normal' check (priority = any (array['low','normal','high','urgent'])),
  target_type   text not null check (target_type = any (array['single','multiple','all'])),
  target_branch_ids bigint[] not null default '{}',   -- empty + target_type='all' = every branch
  attachment_url text,      -- Part 5 "Attachments Placeholder" — nullable, no upload flow this phase
  expires_at    timestamptz,
  created_by    text,
  created_at    timestamptz not null default now()
);

comment on table public.branch_announcements is
  'Phase 7.0 Part 5 — the durable record of what was sent, when, to which branches. Actual delivery is one row per targeted employee in the existing `notifications` table (Phase 6.x), inserted at send time by sendBranchAnnouncement() in admin.html — this table is not a second delivery mechanism.';

create index if not exists branch_announcements_created_at_idx on public.branch_announcements (created_at);

alter table public.branch_announcements enable row level security;

drop policy if exists "branch_announcements_read" on public.branch_announcements;
create policy "branch_announcements_read"
  on public.branch_announcements for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));

drop policy if exists "branch_announcements_owner_admin_write" on public.branch_announcements;
create policy "branch_announcements_owner_admin_write"
  on public.branch_announcements for insert
  to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 3. branch_documents (Part 4 — architecture only)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.branch_documents (
  id             bigint generated always as identity primary key,
  branch_id      bigint not null references public.branches (id) on delete cascade,
  document_type  text not null check (document_type = any (array[
                    'lease_agreement','license','health_certificate','insurance','utility_document','inspection_report'
                  ])),
  title          text not null,
  file_url       text,        -- nullable — no external document storage is wired up this phase, per the brief
  notes          text,
  uploaded_by    text,
  uploaded_at    timestamptz not null default now()
);

comment on table public.branch_documents is
  'Phase 7.0 Part 4 — architecture placeholder. file_url is nullable because no document storage/upload integration exists yet; a row can be created to track "we need a health certificate on file" before a real file exists. Owner-upload-only, enforced by the RLS policy below, not just the UI.';

create index if not exists branch_documents_branch_idx on public.branch_documents (branch_id);

alter table public.branch_documents enable row level security;

drop policy if exists "branch_documents_read" on public.branch_documents;
create policy "branch_documents_read"
  on public.branch_documents for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin' or e.role = 'manager')));

drop policy if exists "branch_documents_owner_write" on public.branch_documents;
create policy "branch_documents_owner_write"
  on public.branch_documents for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true));


-- ───────────────────────────────────────────────────────────────────────
-- 4. branch_config_snapshots (Part 7 — Disaster Recovery architecture)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.branch_config_snapshots (
  id           bigint generated always as identity primary key,
  branch_id    bigint not null references public.branches (id) on delete cascade,
  snapshot     jsonb not null,     -- the branch row's settings fields at export time (name, hours, radius, thresholds, etc. — never employees/orders/financial data)
  label        text,
  created_by   text,
  created_at   timestamptz not null default now()
);

comment on table public.branch_config_snapshots is
  'Phase 7.0 Part 7 — architecture only, per the brief ("do not implement external backup services"). exportBranchConfiguration() writes a row here AND offers the same JSON as a download; importBranchConfiguration() can restore branch *settings* fields from either source. This is configuration recovery, not a database backup — see Phase 6.10''s existing, separately-scoped Backup Readiness section for that.';

create index if not exists branch_config_snapshots_branch_idx on public.branch_config_snapshots (branch_id);

alter table public.branch_config_snapshots enable row level security;

drop policy if exists "branch_config_snapshots_owner_only" on public.branch_config_snapshots;
create policy "branch_config_snapshots_owner_only"
  on public.branch_config_snapshots for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true));


-- ───────────────────────────────────────────────────────────────────────
-- 5. business_rules('branch_automation') — Part 1, all OFF by default
-- ───────────────────────────────────────────────────────────────────────
insert into public.business_rules (category, label, icon, sort_order, rules)
values (
  'branch_automation', 'Branch Automation', '🤖', 96,
  jsonb_build_object(
    'auto_assign_orders_by_campus', false,
    'auto_toggle_ordering_on_status_change', false,
    'auto_notify_managers_low_inventory', true,
    'auto_alert_owner_overload', true,
    'auto_archive_closed_after_days', 90,
    'auto_archive_enabled', false
  )
)
on conflict (category) do nothing;


-- ───────────────────────────────────────────────────────────────────────
-- 6. Real triggers for the two rules safe to run always-on
-- ───────────────────────────────────────────────────────────────────────

-- Rule: auto_toggle_ordering_on_status_change — when a branch's status
-- moves to a closed/paused state, its ordering/delivery toggles turn
-- off automatically; moving back to active/opening_soon does NOT
-- automatically turn them back on (that's a deliberate choice the Owner
-- makes via the Wizard/Settings — an automatic re-enable could put a
-- branch back in front of customers before it's actually ready).
create or replace function public.branch_auto_toggle_ordering()
returns trigger language plpgsql as $$
declare
  v_enabled boolean;
begin
  select coalesce((rules->>'auto_toggle_ordering_on_status_change')::boolean, false)
    into v_enabled from public.business_rules where category = 'branch_automation';

  if v_enabled and new.status in ('temporarily_closed', 'closed', 'archived') and old.status <> new.status then
    new.ordering_enabled := false;
    new.delivery_enabled := false;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_branch_auto_toggle_ordering on public.branches;
create trigger trg_branch_auto_toggle_ordering
  before update on public.branches
  for each row execute function public.branch_auto_toggle_ordering();

-- Rule: auto_assign_orders_by_campus — a new order with no branch_id yet
-- gets matched to a branch by exact campus text, same conservative
-- "only if unambiguous" rule Part 2/3's own backfills used. This is the
-- honestly-computable version of "nearest active branch" — true
-- geographic nearest-branch needs the gps_lat/gps_lng columns (Part 1,
-- still unpopulated placeholders) to mean anything.
create or replace function public.branch_auto_assign_order()
returns trigger language plpgsql as $$
declare
  v_enabled boolean;
  v_branch_id bigint;
begin
  select coalesce((rules->>'auto_assign_orders_by_campus')::boolean, false)
    into v_enabled from public.business_rules where category = 'branch_automation';

  if v_enabled and new.branch_id is null and new.campus is not null then
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
