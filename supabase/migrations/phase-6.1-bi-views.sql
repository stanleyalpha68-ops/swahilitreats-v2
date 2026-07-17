-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 6.1 Migration
-- Executive Dashboard & Business Intelligence
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Every object below is new and additive — nothing existing is altered,
-- renamed, or dropped, so Customer Ordering, the Admin Dashboard,
-- Employee Portal, Inventory, Order Tracking, Notifications, and the
-- Customer Hub are all unaffected.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHY VIEWS, AND WHY ONLY THESE FOUR
-- ───────────────────────────────────────────────────────────────────────
-- Part 15 asks the dashboard to stay fast "for businesses with thousands
-- of orders." Every KPI in this phase is, in the end, some aggregation
-- over `orders` (plus `employees`, `products`, and Phase 5.3's
-- `order_reviews`) — but pulling thousands of raw order rows into the
-- browser just to sum/group/average them client-side is exactly the
-- "unnecessary database call" Part 15 warns against, and it gets slower
-- in direct proportion to how successful the business becomes.
--
-- So this migration adds four plain SQL VIEWs that do the grouping in
-- Postgres instead, once, at query time:
--
--   • v_daily_business_stats      — one row per calendar day (orders,
--     revenue, timing). Powers the Revenue Dashboard (Part 2), Orders
--     Dashboard (Part 3), the Revenue/Orders Trend charts (Part 10), and
--     every date filter (Part 11) — a filter just becomes "sum the rows
--     between these two dates," and even years of history is at most a
--     few thousand *day* rows rather than every order ever placed.
--
--   • v_product_sales_stats       — one row per product. Powers Top
--     Products (Part 7), Sales/Revenue-by-Product charts (Part 10), and
--     the product-related Business Insights (Part 8). Grouped by a
--     *normalized* product name (variant suffixes like "(Size: Large)"
--     stripped) rather than a product_id, because `orders` only ever
--     stored a display-name string for the item ordered (see
--     products.html's checkout) — there is no product_id on `orders` to
--     group by instead, and this view can't safely assume one exists.
--
--   • v_employee_performance_stats — one row per employee (orders
--     delivered/cancelled, revenue generated, average delivery time, and
--     average delivery rating pulled from Phase 5.3's `order_reviews`).
--     Powers the Employee Dashboard (Part 5).
--
--   • v_customer_stats            — one row per phone number (orders,
--     spend, first/last order). Powers the Customer Dashboard (Part 4) —
--     "new vs returning," "top customer," VIP tiers, etc. are all cheap
--     computations over this compact per-customer view instead of every
--     order every customer ever placed.
--
-- These are plain views, not materialized ones: Postgres re-runs the
-- underlying query each time, so the numbers are always current with no
-- refresh job to maintain — appropriate for a single-location business.
-- If order volume ever grows large enough that these views themselves
-- become slow, the natural upgrade (Part 18) is turning them into
-- MATERIALIZED VIEWs refreshed on a schedule via pg_cron — nothing in
-- admin.html would need to change to adopt that later, since it queries
-- these views by name either way.
--
-- No new tables were needed — everything here is aggregation over data
-- that already exists.
--
-- ───────────────────────────────────────────────────────────────────────
-- A HONEST NOTE ON SECURITY (Part 16)
-- ───────────────────────────────────────────────────────────────────────
-- Part 16 asks that only Owners/Admins can reach this dashboard, and asks
-- for "Row Level Security where applicable." The real enforcement point
-- this phase is the admin app itself: the new Executive Dashboard tab is
-- gated by the existing PERMISSIONS system to the "admin" role only,
-- exactly like the existing Settings tab (managers cannot see it, and
-- neither can employees — see admin.html).
--
-- These views are NOT given their own RLS, because they can't be more
-- restrictive than the tables they read from — `orders` and `employees`
-- currently have no restrictive RLS at all (every existing page, customer
-- tracking included, already reads them directly with the public anon
-- key). Adding RLS to those tables now would be a cross-cutting change
-- that risks breaking Order Tracking, the Customer Hub, and Notifications
-- in the same stroke, which is out of scope for a dashboard-focused phase.
-- If stronger database-level protection is wanted later, the right move
-- is a dedicated security pass across the whole schema (introducing real
-- authenticated sessions for staff, then scoping RLS to them) rather than
-- a partial policy bolted onto just these four views.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. v_daily_business_stats — Revenue & Orders Dashboards (Parts 2, 3, 10, 11)
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_daily_business_stats as
select
  date_trunc('day', created_at)::date as day,
  count(*)                                                            as orders_count,
  count(*) filter (where status = 'delivered')                        as delivered_count,
  count(*) filter (where status = 'cancelled')                        as cancelled_count,
  count(*) filter (where status = 'pending')                          as pending_count,
  count(*) filter (where status in ('accepted', 'claimed'))           as accepted_count,
  count(*) filter (where status in ('preparing', 'in_progress'))      as preparing_count,
  count(*) filter (where status in ('delivering', 'out_for_delivery')) as delivering_count,
  coalesce(sum(total_price) filter (where status = 'delivered'), 0)   as revenue,
  avg(extract(epoch from (accepted_at - created_at)) / 60.0)
    filter (where accepted_at is not null)                            as avg_acceptance_minutes,
  avg(extract(epoch from (delivered_at - delivery_started_at)) / 60.0)
    filter (where delivered_at is not null and delivery_started_at is not null) as avg_delivery_minutes,
  avg(extract(epoch from (coalesce(delivered_at, completed_at) - created_at)) / 60.0)
    filter (where coalesce(delivered_at, completed_at) is not null)   as avg_fulfillment_minutes
from public.orders
group by 1;

comment on view public.v_daily_business_stats is
  'One row per calendar day of order activity — backs the Revenue and Orders dashboards, their trend charts, and every date-range filter in the Phase 6.1 Executive Dashboard.';


-- ───────────────────────────────────────────────────────────────────────
-- 2. v_product_sales_stats — Top Products & product charts (Parts 7, 8, 10)
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_product_sales_stats as
select
  regexp_replace(coalesce(product, 'Unknown'), '\s*\([^)]*\)\s*$', '') as product_name,
  count(*)                                                           as orders_count,
  coalesce(sum(quantity), 0)                                         as total_quantity,
  coalesce(sum(total_price) filter (where status = 'delivered'), 0)  as total_revenue,
  min(created_at)                                                    as first_sold_at,
  max(created_at)                                                    as last_sold_at
from public.orders
group by 1;

comment on view public.v_product_sales_stats is
  'One row per product (variant suffixes normalized away) — backs Top Products, Sales/Revenue-by-Product charts, and product-related Business Insights.';


-- ───────────────────────────────────────────────────────────────────────
-- 3. v_employee_performance_stats — Employee Dashboard (Part 5)
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_employee_performance_stats as
select
  o.assigned_employee_id                                              as employee_id,
  count(*) filter (where o.status = 'delivered')                      as orders_delivered,
  count(*) filter (where o.status = 'cancelled')                      as orders_cancelled,
  coalesce(sum(o.total_price) filter (where o.status = 'delivered'), 0) as revenue_generated,
  avg(extract(epoch from (o.delivered_at - o.delivery_started_at)) / 60.0)
    filter (where o.delivered_at is not null and o.delivery_started_at is not null) as avg_delivery_minutes,
  (
    select round(avg(r.delivery_rating)::numeric, 2)
    from public.order_reviews r
    join public.orders o2 on o2.order_id = r.order_id
    where o2.assigned_employee_id = o.assigned_employee_id
  ) as avg_delivery_rating,
  (
    select count(*)
    from public.order_reviews r
    join public.orders o2 on o2.order_id = r.order_id
    where o2.assigned_employee_id = o.assigned_employee_id
  ) as ratings_count
from public.orders o
where o.assigned_employee_id is not null
group by o.assigned_employee_id;

comment on view public.v_employee_performance_stats is
  'One row per employee who has ever been assigned an order — deliveries, cancellations, revenue, average delivery time, and average customer rating (from order_reviews). Backs the Employee Dashboard and its productivity leaderboard.';


-- ───────────────────────────────────────────────────────────────────────
-- 4. v_customer_stats — Customer Dashboard (Part 4)
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_customer_stats as
select
  phone,
  max(customer_name)                                                 as customer_name,
  count(*)                                                            as orders_count,
  coalesce(sum(total_price) filter (where status = 'delivered'), 0)   as total_spent,
  min(created_at)                                                     as first_order_at,
  max(created_at)                                                     as last_order_at
from public.orders
where phone is not null
group by phone;

comment on view public.v_customer_stats is
  'One row per customer phone number — order count, lifetime spend, and first/last order date. Backs the Customer Dashboard: new vs returning, top customer, VIP tiers, customer growth.';


-- ───────────────────────────────────────────────────────────────────────
-- Helpful indexes on the underlying `orders` columns these views group
-- and filter by. If any of these already exist, this is a harmless no-op.
-- ───────────────────────────────────────────────────────────────────────
create index if not exists orders_created_at_idx           on public.orders (created_at);
create index if not exists orders_status_idx                on public.orders (status);
create index if not exists orders_assigned_employee_id_idx  on public.orders (assigned_employee_id);
create index if not exists orders_phone_idx                 on public.orders (phone);


-- ───────────────────────────────────────────────────────────────────────
-- That's the whole migration. See admin.html's new "📈 Executive
-- Dashboard" tab for how these four views are queried and combined.
-- ───────────────────────────────────────────────────────────────────────
