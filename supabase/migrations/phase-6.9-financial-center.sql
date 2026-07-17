-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 6.9 Migration
-- Financial Center & Business Accounting
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Additive only — nothing existing is altered, renamed, or dropped.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ALREADY EXISTS (checked before writing this)
-- ───────────────────────────────────────────────────────────────────────
-- Revenue, profit-margin, and discount-impact math already exist —
-- Phase 6.8 built a "💵 Financial" sub-tab inside the Executive
-- Dashboard that computes Total Revenue, AOV, an estimated discount
-- impact, and gross margin (from products.cost_price, added that same
-- phase). This migration and the module built on it do not duplicate
-- that screen — the new Financial Center is the deeper, dedicated module
-- MODULE_REGISTRY already stubbed out (`{ key: "financial", ...,
-- comingSoon: true }`), and it reuses Phase 6.8's cost/margin math
-- rather than recomputing it a different way.
--
-- What genuinely does not exist anywhere in the schema: any concept of
-- an expense, a budget, or cash outflow. `orders`/`order_items` capture
-- money coming in; nothing captures money going out. That's the real
-- gap this phase fills.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION ADDS
-- ───────────────────────────────────────────────────────────────────────
--   1. expenses          — Part 3. One row per expense. Categorized by a
--      fixed set matching the brief's own list (inventory_purchases,
--      packaging, transport, utilities, rent, salaries, marketing,
--      maintenance, miscellaneous). receipt_url is nullable — Part 3
--      explicitly says "attach receipts (architecture)," so the column
--      exists and nothing yet requires or displays a real upload flow.
--      Expenses over a configurable threshold route through the
--      *existing* approval_requests table via approval_id, exactly the
--      way Phase 6.6's reward_redemption_requests already does — no new
--      approval mechanism invented for this phase.
--   2. budgets           — Part 7. One row per budget period (monthly/
--      quarterly/annual/department/branch). "Actual" and "% used" are
--      NOT stored columns — they're always computed live from `expenses`
--      at read time in the application, the same reasoning Phase 6.1's
--      views used: a stored actual would drift the instant a new expense
--      is logged, and Postgres can aggregate this cheaply.
--   3. Financial settings — no new table. Reuses business_rules (Phase
--      6.2) with a new category = 'financial' row, exactly like Phase
--      6.6 added 'vip'/'coupons'/'rewards' categories to the same table.
--      Holds the expense-approval threshold and alert thresholds (Part 8)
--      as configurable JSON, editable from the existing Business Rules
--      Center with zero new UI required for that part.
--   4. Indexes on expenses/budgets for date-range and category filtering
--      (Part 14) — the same reasoning as Phase 6.8's orders indexes.
--
-- Financial Alerts (Part 8) and Forecasting (Part 9) need no new tables
-- at all — both are computed live in the application from
-- expenses/budgets/orders, the same pattern Phase 6.8 used for Business
-- Insights/Smart Alerts/Forecasting. Cash Flow (Part 5) is also
-- computed, not stored: "cash in" is delivered-order revenue, "cash out"
-- is approved expenses, both already fully queryable.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. expenses (Part 3)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.expenses (
  id              bigint generated always as identity primary key,
  title           text not null,
  description     text,
  category        text not null check (category = any (array[
                     'inventory_purchases','packaging','transport','utilities',
                     'rent','salaries','marketing','maintenance','miscellaneous'
                   ])),
  amount          numeric not null check (amount >= 0),
  expense_date    date not null default current_date,
  branch          text,                 -- free text today (campus-style), same honest limitation as Phase 6.8's Branch Analytics until real branches exist
  status          text not null default 'approved' check (status = any (array[
                     'draft','pending_approval','approved','rejected','archived'
                   ])),
  receipt_url     text,                 -- Part 3 "attach receipts (architecture)" — nullable, no upload flow built this phase
  approval_id     bigint references public.approval_requests (id) on delete set null,
  created_by      text,
  approved_by     text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table public.expenses is
  'Phase 6.9 Part 3 — one row per business expense. Expenses at/above business_rules(''financial'').rules.expense_approval_threshold are created with status=pending_approval and a linked approval_requests row (request_type=''expense_approval''), reusing the existing Approval Center rather than a parallel workflow. Archived (not deleted) expenses keep status=''archived'' so historical P&L/reports stay accurate.';

create index if not exists expenses_expense_date_idx on public.expenses (expense_date);
create index if not exists expenses_category_idx on public.expenses (category);
create index if not exists expenses_status_idx on public.expenses (status);

create or replace function public.set_expenses_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_expenses_updated_at on public.expenses;
create trigger trg_expenses_updated_at
  before update on public.expenses
  for each row execute function public.set_expenses_updated_at();

alter table public.expenses enable row level security;

-- Owner: full read/write. Admin: read/write (frontend PermissionEngine
-- gates which Admins actually reach the module — see Part 10's own note
-- that DB-level roles here are deliberately broader than the in-app
-- permission check, the same posture Phase 6.6/6.8 already took).
-- Manager: read-only, matching Part 10's "read-only if permitted."
drop policy if exists "expenses_owner_admin_write" on public.expenses;
create policy "expenses_owner_admin_write"
  on public.expenses for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));

drop policy if exists "expenses_manager_read" on public.expenses;
create policy "expenses_manager_read"
  on public.expenses for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.role = 'manager'));


-- ───────────────────────────────────────────────────────────────────────
-- 2. budgets (Part 7)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.budgets (
  id             bigint generated always as identity primary key,
  name           text not null,
  budget_type    text not null check (budget_type = any (array['monthly','quarterly','annual','department','branch'])),
  category       text,             -- expense category this budget tracks, null = tracks total expenses
  branch         text,             -- null = whole business
  period_start   date not null,
  period_end     date not null,
  amount         numeric not null check (amount >= 0),
  alert_threshold_pct integer not null default 90,   -- Part 8 "Budget Exceeded" fires at/above this % used
  active         boolean not null default true,
  created_by     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint budgets_period_valid check (period_end >= period_start)
);

comment on table public.budgets is
  'Phase 6.9 Part 7. "Actual" and "% used" are computed at read time (sum of expenses in category/branch/period_start..period_end), never stored — see this migration''s header for why.';

create index if not exists budgets_period_idx on public.budgets (period_start, period_end);
create index if not exists budgets_category_idx on public.budgets (category);

create or replace function public.set_budgets_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_budgets_updated_at on public.budgets;
create trigger trg_budgets_updated_at
  before update on public.budgets
  for each row execute function public.set_budgets_updated_at();

alter table public.budgets enable row level security;

drop policy if exists "budgets_owner_admin_write" on public.budgets;
create policy "budgets_owner_admin_write"
  on public.budgets for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));

drop policy if exists "budgets_manager_read" on public.budgets;
create policy "budgets_manager_read"
  on public.budgets for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.role = 'manager'));


-- ───────────────────────────────────────────────────────────────────────
-- 3. Financial settings — a business_rules row, not a new table
-- ───────────────────────────────────────────────────────────────────────
insert into public.business_rules (category, label, icon, sort_order, rules)
values (
  'financial', 'Financial Center', '💰', 90,
  jsonb_build_object(
    'expense_approval_threshold', 5000,
    'low_cash_alert_threshold', 10000,
    'high_expense_single_threshold', 20000,
    'revenue_drop_alert_pct', 20,
    'high_discount_alert_pct', 30,
    'budget_alert_default_pct', 90
  )
)
on conflict (category) do nothing;
