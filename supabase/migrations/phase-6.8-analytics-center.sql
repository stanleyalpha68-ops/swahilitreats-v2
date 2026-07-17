-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 6.8 Migration
-- Advanced Business Intelligence & Analytics Center
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Additive only — nothing existing is altered, renamed, or dropped.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ALREADY EXISTS (read this before assuming this phase starts from
-- zero — most of it doesn't)
-- ───────────────────────────────────────────────────────────────────────
-- Phase 6.1 already built a real Executive Dashboard: a tab with 8
-- sub-tabs (Overview/Revenue/Orders/Customers/Employees/Inventory/Top
-- Products/Insights), a working date-range picker (today/yesterday/
-- last7/last30/this-month/last-month/this-year/custom), realtime
-- auto-refresh, and CSV/Excel/PDF export — all backed by four SQL views
-- (v_daily_business_stats, v_product_sales_stats,
-- v_employee_performance_stats, v_customer_stats) that already do exactly
-- what Part 15 asks for ("optimize analytical queries... design for
-- thousands of orders": aggregate in Postgres, not in the browser).
--
-- So Part 1's "Analytics Center" is not a green field, and this
-- migration does not duplicate any of the above. What's actually missing
-- against the phase-6.8 brief, checked part by part against the live
-- schema and admin.html:
--
--   • Category Performance (Part 5) / Sales by Category (Part 3) — no
--     `category` column exists on `products` anywhere. Can't report on
--     something that isn't recorded.
--   • Profit Contribution (Part 5) / Inventory Value (Part 7) — no cost
--     column exists on `products` either, only `price` (the sale price).
--     Both parts explicitly say "prepare architecture," which is the
--     honest scope here: without a real cost, "profit" isn't a number,
--     it's a guess.
--   • Branch Analytics (Part 8) — there is no `branches` table, and
--     orders aren't tied to one. The closest existing dimension is
--     `orders.campus` (free text) — Branch Management itself is already
--     flagged `comingSoon: true` in admin.html's own MODULE_REGISTRY.
--     Part 8 asks to "prepare architecture for future branches" — so
--     that's what this migration does, without pretending campus data
--     is branch data.
--   • Weekly/Quarterly report presets (Part 10) — the existing date
--     picker has daily/monthly/yearly/custom but no week or quarter
--     option.
--   • Everything else Part 2–9 asks for (retention, CLV, acceptance
--     rate, stock turnover, etc.) is a computation over data that
--     already exists in full on `orders`/`employees`/`order_reviews`/
--     `employee_inventory`/the Phase 6.6 loyalty tables — no schema
--     changes needed, just new queries against what's already there.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION ACTUALLY ADDS
-- ───────────────────────────────────────────────────────────────────────
--   1. products.category      — nullable text. Existing rows default to
--      null (shown as "Uncategorized" in the UI) until an Owner/Admin
--      fills them in; nothing breaks by adding a column nobody has to
--      use yet.
--   2. products.cost_price    — nullable numeric. Same story — Part 5's
--      "prepare architecture" for Profit Contribution and Part 7's for
--      Inventory Value both become real the moment this column has
--      values, with no further migration needed.
--   3. branches table          — Part 8's "prepare architecture for
--      future branches," genuinely empty today. orders.campus remains
--      the real analytics dimension until this table has rows; Branch
--      Analytics reads whichever one actually has data (see the
--      application code's own comment on this).
--   4. Two indexes on `orders` — created_at and campus are both filtered
--      or grouped on by nearly every chart in this phase (and the
--      existing Executive Dashboard). Postgres can already use the
--      primary key for point lookups, but a full-table sequential scan
--      is what "thousands of orders" (Part 15) turns into without these.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1/2. products.category, products.cost_price
-- ───────────────────────────────────────────────────────────────────────
alter table public.products add column if not exists category text;
alter table public.products add column if not exists cost_price numeric;

comment on column public.products.category is
  'Free-text product category (Phase 6.8 Part 5/Part 3). Null = "Uncategorized" in Category Performance / Sales by Category until an Owner/Admin sets it — see the products edit form in admin.html.';
comment on column public.products.cost_price is
  'Per-unit cost (Phase 6.8 Part 5/Part 7 "prepare architecture"). Null = profit/inventory-value figures show "cost not set" rather than a computed number — this project does not guess at a margin.';


-- ───────────────────────────────────────────────────────────────────────
-- 3. branches — Part 8's "prepare architecture for future branches"
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.branches (
  id           bigint generated always as identity primary key,
  name         text not null,
  code         text unique,
  campus       text,             -- links a future real branch back to today's free-text campus values, so historical orders.campus data can be re-attributed later without a backfill script rewriting `orders`
  address      text,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.branches is
  'Phase 6.8 Part 8 — architecture only, deliberately empty on creation. Branch Analytics in admin.html groups by orders.campus (the real dimension in this data today) until rows exist here; the moment this table is populated and campus values are mapped via the campus column, the same screen can switch to grouping by branch_id instead. Also the real backing table for the "Branch Management" module already stubbed comingSoon:true in MODULE_REGISTRY — building that module out is not part of this phase.';

create or replace function public.set_branches_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_branches_updated_at on public.branches;
create trigger trg_branches_updated_at
  before update on public.branches
  for each row execute function public.set_branches_updated_at();

alter table public.branches enable row level security;

drop policy if exists "branches_public_read" on public.branches;
create policy "branches_public_read"
  on public.branches for select to anon, authenticated using (true);

drop policy if exists "branches_staff_write" on public.branches;
create policy "branches_staff_write"
  on public.branches for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 4. Performance indexes (Part 15)
-- ───────────────────────────────────────────────────────────────────────
create index if not exists orders_created_at_idx on public.orders (created_at);
create index if not exists orders_campus_idx on public.orders (campus);
