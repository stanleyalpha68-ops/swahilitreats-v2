-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 6.2 Migration
-- Business Rules Center
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Everything here is new and additive — nothing existing is altered,
-- renamed, or dropped.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHY ONE NEW TABLE, SHAPED THIS WAY
-- ───────────────────────────────────────────────────────────────────────
-- Part 12 is explicit: business rules must live in the database, not in
-- code. The existing `settings` table already does this for a handful of
-- flat, simple values (business name, WhatsApp number, message
-- templates) — but this phase asks for ten-plus categories covering
-- dozens of individual rules, several of them naturally *structured*
-- (five VIP tiers, each with four of their own fields; a list of reward
-- categories; etc). Forcing that into `settings`' flat text-value shape
-- would mean dozens of new ad-hoc keys with no grouping, and structured
-- data (like the VIP ladder) awkwardly serialized by hand. That's not
-- "reusing existing architecture," it's overloading a table designed for
-- a different, simpler job.
--
-- So this migration adds one new table, `business_rules`, with ONE ROW
-- PER CATEGORY (loyalty, vip, coupons, rewards, referrals, delivery,
-- notifications, branches, security, system, future) and a `rules` jsonb
-- column holding that category's whole configuration. This is a
-- deliberate, idiomatic use of jsonb for a config/settings bag — not a
-- normalization shortcut: every row is still a genuine, cohesive entity
-- (one business concern), and every field within it is always read and
-- saved together as a unit (see loadRuleCategory()/saveBusinessRules()
-- in admin.html), which is exactly the access pattern jsonb is good for.
-- It also means adding a brand-new rule *inside* an existing category
-- later needs zero migration — just a new key in that row's JSON — which
-- is precisely the "no major refactoring" future-proofing Part 17 asks
-- for.
--
-- The table is seeded below with sensible defaults for every single rule
-- listed in Parts 2–11, so the Owner sees real values on first load
-- rather than a blank form.
--
-- ───────────────────────────────────────────────────────────────────────
-- SECURITY (Part 14) — real enforcement, not just an app-layer hint
-- ───────────────────────────────────────────────────────────────────────
-- Unlike the customer-facing pages (which have no login and only ever use
-- the anon key), staff authentication in this project IS real Supabase
-- Auth — login.html calls auth.signInWithPassword(), and every employees
-- row carries a user_id linking it to that auth user, plus the existing
-- is_owner flag (see admin.html's bootstrapAuth()). That means RLS here
-- can check the actual authenticated caller, not just hope the UI hides
-- a button — this is the first phase where "Owner-only" can be a genuine
-- database guarantee rather than a documented limitation.
--
--   • SELECT is open to any authenticated *or* anonymous caller. This is
--     intentional, not an oversight: Part 12 requires the rest of the
--     application — including fully anonymous, no-login customer pages
--     like products.html and customer-hub.html — to be able to read
--     configuration dynamically (e.g. a future checkout reading the
--     configured delivery fee). Part 14's "only the Owner may view
--     rules" is about the Business Rules Center *module* itself, which
--     is an application-layer concern — the same way the existing
--     Settings tab is hidden from non-admins by admin.html's PERMISSIONS
--     system rather than by locking down the `settings` table.
--
--   • INSERT/UPDATE/DELETE are restricted, for real, to authenticated
--     users whose employees row has is_owner = true. An Admin, Manager,
--     or Employee account — even with a valid, logged-in session — gets
--     rejected by Postgres itself, not just by a hidden tab.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. business_rules
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.business_rules (
  id          bigint generated always as identity primary key,
  category    text not null unique,
  label       text not null,
  icon        text,
  sort_order  integer not null default 0,
  rules       jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now(),
  updated_by  text
);

comment on table public.business_rules is
  'One row per business-rule category (loyalty, vip, coupons, rewards, referrals, delivery, notifications, branches, security, system, future). The `rules` jsonb column holds that category''s full configuration — see admin.html''s Business Rules Center for the reader/writer.';

create index if not exists business_rules_category_idx on public.business_rules (category);

-- Keeps updated_at honest on every save without the app having to
-- remember to set it.
create or replace function public.set_business_rules_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_business_rules_updated_at on public.business_rules;
create trigger trg_business_rules_updated_at
  before update on public.business_rules
  for each row
  execute function public.set_business_rules_updated_at();


-- ───────────────────────────────────────────────────────────────────────
-- 2. Row Level Security
-- ───────────────────────────────────────────────────────────────────────
alter table public.business_rules enable row level security;

drop policy if exists "business_rules_public_read" on public.business_rules;
create policy "business_rules_public_read"
  on public.business_rules
  for select
  to anon, authenticated
  using (true);

drop policy if exists "business_rules_owner_write" on public.business_rules;
create policy "business_rules_owner_write"
  on public.business_rules
  for all
  to authenticated
  using (
    exists (
      select 1 from public.employees e
      where e.user_id = auth.uid()
        and e.is_owner = true
    )
  )
  with check (
    exists (
      select 1 from public.employees e
      where e.user_id = auth.uid()
        and e.is_owner = true
    )
  );

-- Note: `for all` covers insert/update/delete once combined with the
-- read-only policy above already granting select — Postgres evaluates
-- every applicable policy per command, and a row need only satisfy one
-- permissive policy for the relevant action, so anon/authenticated
-- SELECT stays open while every write still requires the owner check.


-- ───────────────────────────────────────────────────────────────────────
-- 3. Seed defaults — one row per category, matching Parts 2–11 exactly.
-- ON CONFLICT DO NOTHING so re-running this migration is always safe and
-- never clobbers rules the Owner has already customized.
-- ───────────────────────────────────────────────────────────────────────
insert into public.business_rules (category, label, icon, sort_order, rules) values
(
  'loyalty', 'Loyalty', '💛', 1,
  '{
    "enabled": true,
    "points_per_currency_unit": 10,
    "currency_unit_amount": 100,
    "minimum_purchase_to_earn": 0,
    "max_points_per_order": 1000,
    "cancelled_orders_earn_points": false,
    "refunded_orders_remove_points": true,
    "points_expiration_days": 365
  }'::jsonb
),
(
  'vip', 'VIP Levels', '👑', 2,
  '{
    "levels": [
      { "key": "bronze",   "label": "Bronze",   "min_points": 0,    "badge_color": "#a97142", "priority": 1, "future_benefits": "" },
      { "key": "silver",   "label": "Silver",   "min_points": 500,  "badge_color": "#9aa3ad", "priority": 2, "future_benefits": "" },
      { "key": "gold",     "label": "Gold",     "min_points": 1500, "badge_color": "#e0a940", "priority": 3, "future_benefits": "" },
      { "key": "platinum", "label": "Platinum", "min_points": 3500, "badge_color": "#7fb3d5", "priority": 4, "future_benefits": "" },
      { "key": "diamond",  "label": "Diamond",  "min_points": 7000, "badge_color": "#b39ddb", "priority": 5, "future_benefits": "" }
    ]
  }'::jsonb
),
(
  'coupons', 'Coupons', '🏷️', 3,
  '{
    "default_expiry_days": 30,
    "max_uses_per_coupon": 100,
    "minimum_spend": 0,
    "maximum_discount_amount": 1000,
    "allow_stacking": false,
    "allow_vip_only_coupons": true,
    "auto_deactivate_expired": true,
    "default_prefix": "SWA"
  }'::jsonb
),
(
  'rewards', 'Rewards', '🎁', 4,
  '{
    "minimum_points_required": 500,
    "eligibility": "vip_silver_plus",
    "manual_approval_required": true,
    "max_active_rewards": 5,
    "reward_expiry_days": 60,
    "categories": ["discount", "free_item", "free_delivery"]
  }'::jsonb
),
(
  'referrals', 'Referrals', '🤝', 5,
  '{
    "enabled": true,
    "inviter_reward_points": 200,
    "invited_reward_points": 100,
    "max_referrals_per_customer": 20,
    "referral_expiry_days": 90,
    "code_format": "SWA-XXXXX"
  }'::jsonb
),
(
  'delivery', 'Delivery', '🚚', 6,
  '{
    "delivery_radius_km": 5,
    "delivery_fee": 0,
    "free_delivery_threshold": 1000,
    "estimated_preparation_minutes": 15,
    "estimated_delivery_minutes": 20,
    "max_concurrent_deliveries_per_employee": 3,
    "auto_cancel_timeout_minutes": 60
  }'::jsonb
),
(
  'notifications', 'Notifications', '🔔', 7,
  '{
    "sms_enabled": false,
    "whatsapp_enabled": true,
    "email_enabled": false,
    "push_enabled": false,
    "order_reminders": true,
    "review_reminders": true,
    "promotional_notifications": false
  }'::jsonb
),
(
  'branches', 'Branches', '🏬', 8,
  '{
    "default_branch_name": "Main Branch",
    "branch_naming_format": "{city} - {area}",
    "branch_code_prefix": "BR",
    "branch_approval_workflow_enabled": false
  }'::jsonb
),
(
  'security', 'Security', '🔐', 9,
  '{
    "max_login_attempts": 5,
    "session_timeout_minutes": 60,
    "password_reset_expiry_minutes": 30,
    "mfa_enabled": false,
    "remember_device_enabled": false
  }'::jsonb
),
(
  'system', 'General Business', '⚙️', 10,
  '{
    "default_currency": "KES",
    "timezone": "Africa/Nairobi",
    "business_hours_open": "08:00",
    "business_hours_close": "20:00",
    "default_order_status": "pending",
    "tax_percentage": 0
  }'::jsonb
),
(
  'future', 'Future Features', '🚧', 11,
  '{
    "notes": "Reserved for upcoming configuration (Approval Center, Audit Trail, Branch Management, AI Recommendations, Dynamic Pricing, Marketing Campaigns, Promotions, Holiday/Seasonal Rules, etc). Add new keys here as those features are built — no migration required."
  }'::jsonb
)
on conflict (category) do nothing;


-- ───────────────────────────────────────────────────────────────────────
-- That's the whole migration. See admin.html's new "🧭 Business Rules"
-- tab for the reader/writer (loadBusinessRules() / saveBusinessRules()).
-- ───────────────────────────────────────────────────────────────────────
