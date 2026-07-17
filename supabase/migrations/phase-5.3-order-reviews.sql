-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 5.3 Migration
-- Customer Hub: Order History, Reorder, Reviews & Loyalty
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor for this project
-- and run it once. It only adds new, independent objects — it does not
-- alter, rename, or drop anything that already exists, so none of the
-- existing app (Customer Ordering, Admin Dashboard, Employee Portal,
-- Inventory, Order Tracking, Notifications) is affected.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHY THIS IS THE *ONLY* SCHEMA CHANGE THIS PHASE NEEDS
-- ───────────────────────────────────────────────────────────────────────
-- Phase 5.3 asks for a lot (statistics, order history, reorder, reviews,
-- loyalty points, VIP levels, rewards, referrals, favorites, savings).
-- Going through them one by one against the schema that already exists
-- (orders, order_items, products, discounts, announcements, settings):
--
--   • Order History / Details / Reorder / Statistics / Favorite Products
--     — fully derivable from the existing `orders` (+ `order_items`,
--     `products`, `discounts`) tables. No new storage needed; the app
--     code just queries and aggregates them (see customer-hub.html).
--
--   • Loyalty Points / VIP Level — the brief's own earning rule ("every
--     KES 100 spent = 10 points") is a pure function of a customer's
--     total spend on delivered orders, which is already in `orders`.
--     There is no redemption flow in this phase (Part 9 explicitly says
--     "only implement the reward architecture… prepare placeholders for
--     future redemption"), so there is nothing that needs to be *written*
--     yet — points/VIP level are computed on read. When real redemption
--     is built later, that's the point to introduce a ledger table; doing
--     it now would be exactly the "unnecessary table" this phase's brief
--     warns against.
--
--   • Referral Code — deterministically derived from the phone number
--     (see generateReferralCode() in customer-hub.html), so the same
--     customer always sees the same code with no storage at all. Actual
--     referral *tracking* ("Friends Invited", "Successful Referrals") is
--     explicitly out of scope this phase ("Only prepare the
--     architecture. Do not implement referral reward processing yet.") —
--     the natural home for that later is a small `referrals` table
--     (referrer_phone, referred_phone, order_id, created_at); left as a
--     documented future step rather than built speculatively now.
--
--   • Rewards / Vouchers — same story: display-only placeholders this
--     phase (Part 9), backed by the VIP_LEVELS config in the app rather
--     than a database table, since nothing is redeemable yet.
--
--   • Reviews & Ratings (Part 6) — this is the one genuinely new piece of
--     data in this phase. Nothing in the existing schema records a star
--     rating or review text anywhere, so a new table is unavoidable —
--     `order_reviews` below.
--
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. order_reviews
-- ───────────────────────────────────────────────────────────────────────
-- One row per delivered order (enforced by the UNIQUE constraint on
-- order_id below, which is what actually prevents duplicate reviews for
-- the same order — Part 6). Combines the product rating/review and the
-- delivery rating/comment in a single row, since the brief frames both
-- as parts of "reviewing an order" rather than separate flows.
--
-- order_id is stored as plain text (matching orders.order_id) rather
-- than a foreign key, because this migration deliberately avoids
-- assuming a UNIQUE/PK constraint already exists on orders.order_id —
-- that would make this migration fail to apply if it doesn't. Referential
-- integrity for order_id is instead enforced where it actually matters —
-- at write time, by the RLS policy below, which checks the order really
-- exists, is delivered, and belongs to the phone number submitting the
-- review.
--
-- product_id *is* a real foreign key, since products.id is already used
-- as an FK target elsewhere in this schema (discounts.product_id, etc.).
-- ON DELETE SET NULL so a review survives a product later being removed.
create table if not exists public.order_reviews (
  id                bigint generated always as identity primary key,
  order_id          text not null,
  phone_number      text not null,
  product_id        bigint references public.products(id) on delete set null,
  product_rating    smallint not null check (product_rating between 1 and 5),
  product_review    text,
  delivery_rating   smallint not null check (delivery_rating between 1 and 5),
  delivery_comment  text,
  -- Placeholder for future product-photo uploads (Part 6: "Prepare the
  -- architecture" — no upload UI is implemented yet, so this stays null
  -- until a future phase wires up Supabase Storage and starts writing
  -- a public URL here. No schema change will be needed when that happens.
  photo_url         text,
  created_at        timestamptz not null default now()
);

-- Enforces "prevent duplicate reviews for the same delivered order"
-- at the database level, not just in the UI.
create unique index if not exists order_reviews_order_id_key
  on public.order_reviews (order_id);

-- Supports "Average Product Rating" / "Total Reviews" / "Recent Reviews"
-- lookups by product (Part 6), and "my reviews" lookups by phone number
-- for the customer statistics' "Average Rating Given" (Part 2).
create index if not exists order_reviews_product_id_idx
  on public.order_reviews (product_id);
create index if not exists order_reviews_phone_number_idx
  on public.order_reviews (phone_number);
create index if not exists order_reviews_created_at_idx
  on public.order_reviews (created_at desc);


-- ───────────────────────────────────────────────────────────────────────
-- 2. Row Level Security
-- ───────────────────────────────────────────────────────────────────────
-- This project has no Supabase Auth / customer accounts (Part 15) — every
-- page, including the existing ones, talks to Supabase with the public
-- anon key and scopes reads with plain query filters (e.g. Order Tracking
-- already reads `orders` this way). RLS here follows that same existing
-- security model rather than inventing a stricter one this app has no
-- mechanism to actually enforce (there's no verified identity to check
-- against on SELECT).
--
-- Reads are public, matching how announcements/products already behave —
-- reviews are ordinary social-proof content, not sensitive data on their
-- own (no phone numbers or order internals are ever rendered from them
-- in the UI). Writes ARE meaningfully restricted: an insert is only
-- allowed when it can be proven, server-side, that the order it claims to
-- review really exists, was delivered, and belongs to the phone number
-- attached to the review. This is the one place in this table where real
-- enforcement is possible without an auth system, so it's where the
-- security effort goes (Part 15).
alter table public.order_reviews enable row level security;

drop policy if exists "order_reviews_public_read" on public.order_reviews;
create policy "order_reviews_public_read"
  on public.order_reviews
  for select
  to anon, authenticated
  using (true);

drop policy if exists "order_reviews_insert_own_delivered_order" on public.order_reviews;
create policy "order_reviews_insert_own_delivered_order"
  on public.order_reviews
  for insert
  to anon, authenticated
  with check (
    exists (
      select 1 from public.orders o
      where o.order_id = order_reviews.order_id
        and o.phone    = order_reviews.phone_number
        and o.status   = 'delivered'
    )
  );

-- No update/delete policy is created — RLS with no matching policy means
-- reviews can be created and read, but not edited or removed by anyone
-- through the anon key. Editing reviews isn't part of this phase's brief;
-- add an owner-scoped update policy later if that becomes a requirement.


-- ───────────────────────────────────────────────────────────────────────
-- That's the whole migration. Nothing else in this phase needs schema
-- changes — see customer-hub.html for how loyalty points, VIP levels,
-- referral codes, rewards, favorites, and savings are all computed from
-- data that already exists.
-- ───────────────────────────────────────────────────────────────────────
