-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 7.0 (Part 3/4) Migration
-- Enterprise Branch Intelligence, Analytics & Financial Integration
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Run AFTER phase-7.0-branch-management-foundation.sql (Part 1) and
-- phase-7.0-part2-branch-operations.sql (Part 2) — this references
-- `branches`, `orders.branch_id`, and `expenses`. Additive only.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ALREADY EXISTS (checked before writing this)
-- ───────────────────────────────────────────────────────────────────────
-- Part 1 built `branches`; Part 2 built `orders.branch_id`,
-- `branch_inventory`, and `employees.branch_id`. Phase 6.8's Analytics
-- Center already has a "🏬 Branch Analytics" sub-tab (grouped by
-- `orders.campus`, the only dimension that existed at the time — its own
-- code comments say so). Phase 6.9's Financial Center already computes
-- "Profit by Branch" the same way. Per this phase's explicit
-- instruction, neither gets redesigned — both get upgraded in place to
-- prefer real `branch_id` grouping when branches exist, falling back to
-- the original campus grouping otherwise, so a business with no branches
-- configured yet sees zero change in behavior.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION ADDS
-- ───────────────────────────────────────────────────────────────────────
--   1. expenses.branch_id — Part 2's `expenses.branch` (free text, Phase
--      6.9) is kept as-is; this adds a real FK alongside it so branch
--      financial rollups (Part 2 of this phase) don't depend on text
--      matching. A best-effort backfill links existing expense rows
--      whose free-text `branch` exactly matches one branch's name or
--      campus; anything ambiguous or unmatched stays null, same
--      conservative approach as Part 2's orders.branch_id backfill.
--   2. branch_goals — Part 7's Owner-defined KPI targets. "Actual"
--      progress is always computed live against v_branch_daily_stats/
--      expenses at read time (same reasoning as every other "don't store
--      a number that can drift" decision across this project), so this
--      table only holds the target itself.
--   3. v_branch_daily_stats — a view, not a table: the single most
--      valuable performance addition for this phase (Part 13's
--      "aggregated queries, support dozens of branches"). Mirrors
--      v_daily_business_stats' shape exactly (Phase 6.1), just grouped
--      by branch_id too, so every screen in this phase (Analytics,
--      Financial, Rankings, Comparison, Goals progress) sums the same
--      pre-aggregated rows instead of five different screens each
--      re-scanning raw `orders`.
--   4. Indexes for the new branch_id/period lookups.
--
-- Branch Customer Intelligence (Part 4) and Branch Employee Performance
-- (Part 5) need no new tables or views — both compute directly from
-- `orders`/`employees` filtered by branch_id, reusing v_customer_stats/
-- v_employee_performance_stats (Phase 6.1) where the shape already fits
-- and adding a branch_id filter in the application where it doesn't
-- (see that code's own comments for exactly where each line is drawn).
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. expenses.branch_id
-- ───────────────────────────────────────────────────────────────────────
alter table public.expenses add column if not exists branch_id bigint references public.branches (id) on delete set null;
create index if not exists expenses_branch_id_idx on public.expenses (branch_id);

comment on column public.expenses.branch_id is
  'Phase 7.0 Part 3. Alongside the original free-text `branch` column (Phase 6.9) — new expenses should set both going forward (see admin.html''s expense form), old rows keep whatever text they had. The one-time backfill below only links exact name/campus matches.';

update public.expenses e
set branch_id = b.id
from public.branches b
where e.branch_id is null
  and e.branch is not null
  and (e.branch = b.name or e.branch = b.campus)
  and (
    select count(*) from public.branches b2 where b2.name = e.branch or b2.campus = e.branch
  ) = 1;


-- ───────────────────────────────────────────────────────────────────────
-- 2. branch_goals (Part 7)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.branch_goals (
  id             bigint generated always as identity primary key,
  branch_id      bigint not null references public.branches (id) on delete cascade,
  goal_type      text not null check (goal_type = any (array[
                    'revenue','orders','customers','delivery_time','profit','inventory_accuracy'
                  ])),
  label          text,
  target_value   numeric not null,
  period_start   date not null,
  period_end     date not null,
  status         text not null default 'active' check (status = any (array['active','completed','missed','cancelled'])),
  created_by     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint branch_goals_period_valid check (period_end >= period_start)
);

comment on table public.branch_goals is
  'Phase 7.0 Part 7. target_value''s unit depends on goal_type (KES for revenue/profit, count for orders/customers, minutes for delivery_time, % for inventory_accuracy). Progress/"actual" is computed live in the application, never stored here — see this migration''s header.';

create index if not exists branch_goals_branch_idx on public.branch_goals (branch_id);
create index if not exists branch_goals_period_idx on public.branch_goals (period_start, period_end);

create or replace function public.set_branch_goals_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_branch_goals_updated_at on public.branch_goals;
create trigger trg_branch_goals_updated_at
  before update on public.branch_goals
  for each row execute function public.set_branch_goals_updated_at();

alter table public.branch_goals enable row level security;

drop policy if exists "branch_goals_read" on public.branch_goals;
create policy "branch_goals_read"
  on public.branch_goals for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));

drop policy if exists "branch_goals_owner_write" on public.branch_goals;
create policy "branch_goals_owner_write"
  on public.branch_goals for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.is_owner = true));


-- ───────────────────────────────────────────────────────────────────────
-- 3. v_branch_daily_stats — mirrors v_daily_business_stats, grouped by
--    branch_id too (Part 13 performance)
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_branch_daily_stats as
select
  date_trunc('day', created_at)::date as day,
  branch_id,
  count(*)                                                            as orders_count,
  count(*) filter (where status = 'delivered')                        as delivered_count,
  count(*) filter (where status = 'cancelled')                        as cancelled_count,
  count(*) filter (where status = 'pending')                          as pending_count,
  coalesce(sum(total_price) filter (where status = 'delivered'), 0)   as revenue,
  avg(extract(epoch from (delivered_at - delivery_started_at)) / 60.0)
    filter (where delivered_at is not null and delivery_started_at is not null) as avg_delivery_minutes
from public.orders
where branch_id is not null
group by 1, 2;

comment on view public.v_branch_daily_stats is
  'Phase 7.0 Part 3. Same shape as v_daily_business_stats (Phase 6.1), grouped by branch_id too. Orders with no branch_id are excluded — they cannot be attributed to a branch, and Branch Analytics/Financials/Rankings/Comparison/Goals all read this view directly rather than re-aggregating raw orders themselves.';
