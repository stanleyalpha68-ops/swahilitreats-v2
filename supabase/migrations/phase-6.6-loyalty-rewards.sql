-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 6.6 Migration
-- Loyalty & Rewards Administration
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Additive only — nothing existing is altered, renamed, or dropped.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ACTUALLY EXISTED BEFORE THIS MIGRATION (read this first)
-- ───────────────────────────────────────────────────────────────────────
-- The brief marks "Loyalty Architecture" as already complete. Checking
-- the live schema and admin.html against that: there is no customers
-- table, no points table, no coupons table, and no VIP table anywhere.
-- What exists is:
--   • v_customer_stats (Phase 6.1)  — orders/spend per phone number.
--   • business_rules rows for 'loyalty', 'vip', 'coupons', 'rewards',
--     and 'referrals' (Phase 6.2) — but these are just default *config*
--     (points-per-currency-unit, VIP thresholds, etc.), not customer
--     data. No points have ever been earned or stored anywhere.
-- So Part 1 below is not "extend the loyalty system" — it's building it
-- for the first time, using those existing config rows as the rules
-- engine rather than re-inventing one.
--
-- Separately: `orders`, `employees`, `products`, `notifications`,
-- `audit_log`, `approval_requests`, `approval_history`,
-- `approval_comments`, and `approval_chain_progress` are all real,
-- already-live tables that admin.html queries today, even though their
-- own CREATE TABLE statements aren't in this migrations folder (only
-- Phases 5.3 onward were checked in here — earlier phases' SQL was
-- applied straight into Supabase). This migration reads their shape from
-- how admin.html actually calls them, and reuses them as instructed:
-- notifications and audit_log directly, approval_requests for the
-- redemption/manual-reward approval workflow.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHY THESE SIX TABLES, AND NOT MORE
-- ───────────────────────────────────────────────────────────────────────
-- Customers are, and remain, rows of `orders` grouped by phone — there is
-- deliberately no new `customers` table, so nothing about checkout,
-- Order Tracking, or the Customer Hub needs to change. Everything below
-- keys off `phone` the same way v_customer_stats already does.
--
--   1. loyalty_points_ledger  — append-only. Every earn, manual add,
--      manual removal, redemption spend, and expiry is one row. Current
--      points = sum of non-expired rows; lifetime points = sum of the
--      positive ones. An audit trail for points falls out of this for
--      free — there's no separate "current_points" column anywhere to
--      drift out of sync with reality.
--   2. customer_loyalty        — the one thing about a customer that
--      truly can't be derived: a manual VIP override, and their referral
--      code / who referred them. One row per phone, created on demand.
--   3. coupons                 — coupon *definitions* (Part 6).
--   4. customer_coupons        — coupon *instances* issued to a specific
--      phone (Part 4/6/7) — a coupon definition can back many instances,
--      which is what makes bulk generation and campaign-issued coupons
--      possible from the same table.
--   5. reward_campaigns        — campaign definitions (Part 5).
--   6. reward_redemption_requests — the eligible → request → review →
--      issue pipeline from Part 7, deliberately separate from
--      manual-issue coupons/points so "a customer asked for this" and
--      "an admin decided to give this" stay distinguishable in reports.
--
-- VIP levels themselves (Part 8) are NOT a new table — they're already
-- fully modeled as business_rules.category = 'vip' → rules.levels (see
-- EXEC_RULE_DEFAULTS in admin.html). Reused as-is; the app just needs a
-- read path into it, which it already has via loadBusinessRules().
--
-- ───────────────────────────────────────────────────────────────────────
-- AUDIT TRAIL (Part 12) — DELIBERATE CHOICE, READ BEFORE ASSUMING TRIGGERS
-- ───────────────────────────────────────────────────────────────────────
-- audit_log rows need actor_employee_id/actor_role. Other tables' audit
-- triggers (if any exist in the live database — their source isn't in
-- this repo) aren't visible to this migration, and guessing at their
-- internals to copy them here would risk logging the wrong actor or
-- silently failing. admin.html already has a proven, correct path for
-- exactly this problem — createAuditRecord() — used today for events a
-- trigger structurally can't catch (login/logout). Every mutating
-- function in Part 15 (issueReward, createCoupon, redeemReward, etc.)
-- calls it directly, at the point the actor is actually known. That
-- satisfies "never require developers to manually create audit records"
-- in the sense Part 12 means it: no admin.html screen forgets to call
-- it, because it's baked into the shared functions, not left to each
-- screen to remember.
--
-- ───────────────────────────────────────────────────────────────────────
-- SECURITY (Part 11) — MATCHING THE EXISTING, LOAD-BEARING PATTERN
-- ───────────────────────────────────────────────────────────────────────
-- Exactly like orders/order_reviews today, customers place requests
-- (redemption requests, coupon reads) with the anon key and no login —
-- there is no customer authentication anywhere in this app. So:
--   • coupons / customer_coupons / reward_campaigns: publicly readable
--     (a customer needs to see their own coupons/eligible rewards),
--     staff-write restricted to authenticated employees who are Owner or
--     Admin — same exists()-against-employees check as Phase 6.2/6.3.
--   • reward_redemption_requests: anon may INSERT (a customer requesting
--     redemption) and SELECT (checking their own request status) — the
--     same trust model as `orders` — but only staff (Owner/Admin) may
--     UPDATE (decide) them.
--   • loyalty_points_ledger / customer_loyalty: publicly readable (a
--     customer's own loyalty profile is shown in the Customer Hub),
--     writes restricted to Owner/Admin — points are never customer-
--     writable directly, only earned via the app's own order-completion
--     logic or issued manually by staff.
-- Real per-admin granularity (which specific Admins can reach Rewards
-- Administration) is enforced the same place it already is everywhere
-- else in this app: the PermissionEngine / role_permissions in
-- admin.html, not a second, competing enforcement layer in Postgres.
--
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. loyalty_points_ledger — append-only points journal
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.loyalty_points_ledger (
  id                bigint generated always as identity primary key,
  phone             text not null,
  customer_name     text,
  delta_points      integer not null,                 -- positive = earn/add, negative = spend/remove/expire
  reason            text not null,                     -- e.g. 'order_completed', 'manual_add', 'manual_remove', 'redeemed', 'expired', 'referral_bonus'
  source_type       text,                               -- 'order' | 'manual_reward' | 'redemption_request' | 'campaign' | 'referral' | 'expiry'
  source_id         text,                               -- order_id / manual_rewards.id / etc, kept as text since orders.order_id is text
  actor_employee_id text,                                -- who did this (null for system/automatic earns)
  actor_role        text,
  notes             text,
  expires_at        timestamptz,                         -- null = does not expire independently (e.g. spends/removals)
  created_at        timestamptz not null default now()
);

comment on table public.loyalty_points_ledger is
  'Append-only journal of every points event per phone number. Current points = sum(delta_points) where not expired; lifetime points = sum of positive deltas. Never updated or deleted, only inserted — see admin.html Rewards Administration for the reader/writer.';

create index if not exists loyalty_points_ledger_phone_idx on public.loyalty_points_ledger (phone);
create index if not exists loyalty_points_ledger_created_at_idx on public.loyalty_points_ledger (created_at);

alter table public.loyalty_points_ledger enable row level security;

drop policy if exists "loyalty_points_ledger_public_read" on public.loyalty_points_ledger;
create policy "loyalty_points_ledger_public_read"
  on public.loyalty_points_ledger for select
  to anon, authenticated
  using (true);

drop policy if exists "loyalty_points_ledger_staff_write" on public.loyalty_points_ledger;
create policy "loyalty_points_ledger_staff_write"
  on public.loyalty_points_ledger for insert
  to authenticated
  with check (
    exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin'))
  );
-- No update/delete policy anywhere, by design — it's a journal, not a
-- balance. Corrections are made by inserting an offsetting row.


-- ───────────────────────────────────────────────────────────────────────
-- 2. customer_loyalty — the one-off, non-derivable facts about a customer
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.customer_loyalty (
  phone               text primary key,
  vip_override_key    text,                -- if set, wins over the computed level (e.g. a manually-granted VIP status)
  vip_override_reason text,
  vip_override_by     text,
  referral_code       text unique,
  referred_by_phone   text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on table public.customer_loyalty is
  'One row per customer phone number, created on first touch. Holds only what cannot be derived from orders/ledger/reviews: a manual VIP override and referral linkage. Everything else on the Loyalty Profile (points, orders, spend, reviews, rankings) is computed from v_customer_loyalty_summary below.';

create or replace function public.set_customer_loyalty_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_customer_loyalty_updated_at on public.customer_loyalty;
create trigger trg_customer_loyalty_updated_at
  before update on public.customer_loyalty
  for each row execute function public.set_customer_loyalty_updated_at();

alter table public.customer_loyalty enable row level security;

drop policy if exists "customer_loyalty_public_read" on public.customer_loyalty;
create policy "customer_loyalty_public_read"
  on public.customer_loyalty for select to anon, authenticated using (true);

drop policy if exists "customer_loyalty_staff_write" on public.customer_loyalty;
create policy "customer_loyalty_staff_write"
  on public.customer_loyalty for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 3. reward_campaigns — campaign definitions (Part 5)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.reward_campaigns (
  id               bigint generated always as identity primary key,
  name             text not null,
  description      text,
  campaign_type    text not null default 'custom',      -- 'weekend_special' | 'campus_promotion' | 'holiday' | 'vip_appreciation' | 'birthday' | 'referral' | 'custom'
  reward_type      text not null,                        -- 'coupon' | 'points' | 'free_item' | 'free_delivery'
  coupon_template  jsonb not null default '{}'::jsonb,    -- shape mirrors `coupons` columns, used to stamp out instances when the campaign issues coupons
  points_amount    integer,
  target_audience  jsonb not null default '{}'::jsonb,    -- e.g. {"vip_levels": ["gold","platinum"], "min_orders": 3}
  usage_limit      integer,                               -- total redemptions allowed across the whole campaign, null = unlimited
  usage_count      integer not null default 0,
  starts_at        timestamptz,
  ends_at          timestamptz,
  status           text not null default 'draft',         -- 'draft' | 'scheduled' | 'active' | 'ended' | 'cancelled'
  created_by       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on table public.reward_campaigns is
  'Reward campaign definitions (Part 5). A campaign that issues coupons stamps out rows in `coupons`/`customer_coupons` from coupon_template — the campaign itself never IS a coupon, so one campaign can back many coupon instances.';

create index if not exists reward_campaigns_status_idx on public.reward_campaigns (status);

create or replace function public.set_reward_campaigns_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_reward_campaigns_updated_at on public.reward_campaigns;
create trigger trg_reward_campaigns_updated_at
  before update on public.reward_campaigns
  for each row execute function public.set_reward_campaigns_updated_at();

alter table public.reward_campaigns enable row level security;

drop policy if exists "reward_campaigns_public_read" on public.reward_campaigns;
create policy "reward_campaigns_public_read"
  on public.reward_campaigns for select to anon, authenticated using (true);

drop policy if exists "reward_campaigns_staff_write" on public.reward_campaigns;
create policy "reward_campaigns_staff_write"
  on public.reward_campaigns for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 4. coupons — coupon definitions (Part 6)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.coupons (
  id                  bigint generated always as identity primary key,
  code                text not null unique,
  coupon_type         text not null,                     -- 'percentage' | 'fixed_amount' | 'free_product' | 'free_delivery' | 'bonus_points'
  value               numeric,                            -- percentage (e.g. 10) or fixed amount (KES), null for free_delivery
  free_product_name   text,
  bonus_points_amount integer,
  usage_limit         integer,                            -- total redemptions allowed across all customers, null = unlimited
  usage_count         integer not null default 0,
  per_customer_limit  integer not null default 1,
  min_spend           numeric not null default 0,
  eligible_products   text[],                              -- null/empty = all products
  eligible_vip_levels text[],                               -- null/empty = all VIP levels
  eligible_branches   text[],                               -- null/empty = all branches
  starts_at           timestamptz not null default now(),
  expires_at          timestamptz,
  status              text not null default 'active',       -- 'active' | 'disabled' | 'expired'
  campaign_id         bigint references public.reward_campaigns (id) on delete set null,
  is_bulk_generated   boolean not null default false,
  notes               text,
  created_by          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on table public.coupons is
  'Coupon definitions (Part 6). A coupon here is the template/rules; who actually has it and its per-customer redemption state lives in customer_coupons.';

create index if not exists coupons_status_idx on public.coupons (status);
create index if not exists coupons_campaign_id_idx on public.coupons (campaign_id);

create or replace function public.set_coupons_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_coupons_updated_at on public.coupons;
create trigger trg_coupons_updated_at
  before update on public.coupons
  for each row execute function public.set_coupons_updated_at();

alter table public.coupons enable row level security;

drop policy if exists "coupons_public_read" on public.coupons;
create policy "coupons_public_read"
  on public.coupons for select to anon, authenticated using (true);

drop policy if exists "coupons_staff_write" on public.coupons;
create policy "coupons_staff_write"
  on public.coupons for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 5. customer_coupons — coupon instances issued to a phone number
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.customer_coupons (
  id               bigint generated always as identity primary key,
  coupon_id        bigint not null references public.coupons (id) on delete cascade,
  phone            text not null,
  status           text not null default 'issued',        -- 'issued' | 'redeemed' | 'expired' | 'revoked'
  issued_by        text,                                    -- employee id, or 'system' for automatic issuance
  issued_reason    text,                                     -- 'manual' | 'campaign' | 'redemption_request' | 'vip_upgrade' | 'birthday' | 'referral'
  redeemed_at      timestamptz,
  redeemed_order_id text,
  created_at       timestamptz not null default now()
);

comment on table public.customer_coupons is
  'One row per coupon instance held by a customer (Part 4/6/7). Many rows can point at the same `coupons` row for bulk/campaign issuance.';

create index if not exists customer_coupons_phone_idx on public.customer_coupons (phone);
create index if not exists customer_coupons_coupon_id_idx on public.customer_coupons (coupon_id);
create index if not exists customer_coupons_status_idx on public.customer_coupons (status);

alter table public.customer_coupons enable row level security;

drop policy if exists "customer_coupons_public_read" on public.customer_coupons;
create policy "customer_coupons_public_read"
  on public.customer_coupons for select to anon, authenticated using (true);

drop policy if exists "customer_coupons_staff_write" on public.customer_coupons;
create policy "customer_coupons_staff_write"
  on public.customer_coupons for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 6. reward_redemption_requests — eligible → request → review → issue
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.reward_redemption_requests (
  id                  bigint generated always as identity primary key,
  phone               text not null,
  customer_name       text,
  reward_type         text not null,                       -- 'coupon' | 'points_redemption' | 'free_item' | 'free_delivery'
  reward_reference    jsonb not null default '{}'::jsonb,   -- what they're asking for, e.g. {"points_cost": 500, "description": "Free Mabuyu"}
  status              text not null default 'pending',      -- 'pending' | 'approved' | 'rejected' | 'fulfilled'
  requires_review     boolean not null default true,         -- mirrors business_rules.rewards.manual_approval_required at request time
  approval_id         bigint references public.approval_requests (id) on delete set null,
  fulfillment_coupon_id bigint references public.coupons (id) on delete set null,
  decided_by          text,
  decided_at          timestamptz,
  decision_notes      text,
  created_at          timestamptz not null default now()
);

comment on table public.reward_redemption_requests is
  'Customer-initiated reward redemption requests (Part 7). Kept separate from customer_coupons/loyalty_points_ledger so "customer asked" and "staff granted" stay distinguishable in analytics and audit history. When approval is required, approval_id links to the existing approval_requests workflow.';

create index if not exists reward_redemption_requests_phone_idx on public.reward_redemption_requests (phone);
create index if not exists reward_redemption_requests_status_idx on public.reward_redemption_requests (status);

alter table public.reward_redemption_requests enable row level security;

drop policy if exists "redemption_requests_public_read" on public.reward_redemption_requests;
create policy "redemption_requests_public_read"
  on public.reward_redemption_requests for select to anon, authenticated using (true);

drop policy if exists "redemption_requests_public_insert" on public.reward_redemption_requests;
create policy "redemption_requests_public_insert"
  on public.reward_redemption_requests for insert to anon, authenticated with check (true);
-- Matches the existing `orders` trust model: anyone can create a request
-- for a phone number, same as anyone can place an order for one — there
-- is no customer authentication anywhere in this app to restrict against.

drop policy if exists "redemption_requests_staff_update" on public.reward_redemption_requests;
create policy "redemption_requests_staff_update"
  on public.reward_redemption_requests for update
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 7. v_customer_loyalty_summary — one row per customer, everything the
--    Loyalty Profile (Part 2) and Rankings (Part 3) need, computed
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_customer_loyalty_summary as
select
  s.phone,
  s.customer_name,
  s.orders_count,
  s.total_spent,
  s.first_order_at,
  s.last_order_at,
  coalesce(p.current_points, 0)   as current_points,
  coalesce(p.lifetime_points, 0)  as lifetime_points,
  coalesce(r.reviews_count, 0)    as reviews_count,
  coalesce(ref.referrals_count, 0) as referrals_count,
  cl.vip_override_key,
  cl.referral_code,
  cl.referred_by_phone
from public.v_customer_stats s
left join (
  select phone,
    sum(delta_points) filter (where expires_at is null or expires_at > now()) as current_points,
    sum(delta_points) filter (where delta_points > 0) as lifetime_points
  from public.loyalty_points_ledger
  group by phone
) p on p.phone = s.phone
left join (
  select o.phone, count(*) as reviews_count
  from public.order_reviews r
  join public.orders o on o.order_id = r.order_id
  where o.phone is not null
  group by o.phone
) r on r.phone = s.phone
left join (
  select referred_by_phone as phone, count(*) as referrals_count
  from public.customer_loyalty
  where referred_by_phone is not null
  group by referred_by_phone
) ref on ref.phone = s.phone
left join public.customer_loyalty cl on cl.phone = s.phone;

comment on view public.v_customer_loyalty_summary is
  'One row per customer phone number combining orders/spend (v_customer_stats), current+lifetime points (loyalty_points_ledger), review count (order_reviews), and any VIP override/referral code (customer_loyalty). Backs the Customer Loyalty Profile (Part 2) and feeds every Rankings leaderboard (Part 3).';


-- ───────────────────────────────────────────────────────────────────────
-- 8. v_coupon_redemption_stats — Reward Analytics (Part 9)
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_coupon_redemption_stats as
select
  c.id as coupon_id,
  c.code,
  c.coupon_type,
  c.status,
  c.campaign_id,
  c.usage_limit,
  count(cc.*) as times_issued,
  count(cc.*) filter (where cc.status = 'redeemed') as times_redeemed,
  count(cc.*) filter (where cc.status = 'issued' and (c.expires_at is null or c.expires_at > now())) as times_unused,
  count(cc.*) filter (where cc.status = 'expired' or (cc.status = 'issued' and c.expires_at is not null and c.expires_at <= now())) as times_expired,
  case when count(cc.*) = 0 then 0
       else round(100.0 * count(cc.*) filter (where cc.status = 'redeemed') / count(cc.*), 1)
  end as redemption_rate_pct
from public.coupons c
left join public.customer_coupons cc on cc.coupon_id = c.id
group by c.id, c.code, c.coupon_type, c.status, c.campaign_id, c.usage_limit;

comment on view public.v_coupon_redemption_stats is
  'One row per coupon definition — issued/redeemed/unused/expired counts and redemption rate. Backs Most Redeemed Coupon, Unused Coupons, Expired Coupons, and Reward Redemption Rate on the Reward Analytics screen (Part 9).';


-- ───────────────────────────────────────────────────────────────────────
-- 9. v_reward_campaign_stats — Campaign Performance (Part 9)
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_reward_campaign_stats as
select
  rc.id as campaign_id,
  rc.name,
  rc.campaign_type,
  rc.status,
  rc.starts_at,
  rc.ends_at,
  rc.usage_limit,
  rc.usage_count,
  count(distinct c.id) as coupons_generated,
  count(cc.*) filter (where cc.status = 'redeemed') as coupons_redeemed
from public.reward_campaigns rc
left join public.coupons c on c.campaign_id = rc.id
left join public.customer_coupons cc on cc.coupon_id = c.id
group by rc.id, rc.name, rc.campaign_type, rc.status, rc.starts_at, rc.ends_at, rc.usage_limit, rc.usage_count;

comment on view public.v_reward_campaign_stats is
  'One row per campaign — coupons generated and redeemed under it. Backs Campaign Performance on the Reward Analytics screen (Part 9).';


-- ───────────────────────────────────────────────────────────────────────
-- That's the whole migration. See admin.html's new "Rewards
-- Administration" module for how these tables/views are queried,
-- combined, and kept in sync with notifications, audit_log, and
-- approval_requests.
-- ───────────────────────────────────────────────────────────────────────
