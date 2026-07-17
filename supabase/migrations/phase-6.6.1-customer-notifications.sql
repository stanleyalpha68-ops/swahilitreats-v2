-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 6.6 Migration (addendum)
-- Customer Notifications — required by Part 10, not covered by 6.6 main
-- ═══════════════════════════════════════════════════════════════════════
--
-- WHY THIS IS SEPARATE FROM PHASE 6.6's MAIN FILE
-- Checking the live `notifications` table's actual shape (from how
-- admin.html and employee/index.html call it): every existing row is
-- keyed by employee_id — it's a staff inbox (approval decisions, employee
-- app pushes), not something a phone-number-keyed customer notification
-- can fit into without either making employee_id nullable and dual-
-- purposing a live, working table, or adding a recipient-type branch to
-- every existing query against it. Both are exactly the kind of
-- retrofit-a-live-table risk the rest of this project has consistently
-- avoided (see Phase 6.3's and 6.1's own notes on the same tradeoff).
--
-- So Part 10 gets its own small table instead — additive, nothing about
-- the existing employee notifications changes.
--
-- Part 10 also asks this be architected for SMS/WhatsApp/Email/Push
-- "without implementing external providers." channel_prepared jsonb
-- is that seam: it records which channels a notification *would* go out
-- on, so a future phase can wire a real SMS/WhatsApp/email provider by
-- reading this column and dispatching, without any schema change or
-- touching any of the code that writes these rows today.
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists public.customer_notifications (
  id               bigint generated always as identity primary key,
  phone            text not null,
  notif_type       text not null,      -- 'reward_issued' | 'coupon_available' | 'coupon_expiring' | 'vip_level_up' | 'campaign_started' | 'reward_redeemed'
  title            text not null,
  message          text not null,
  channel_prepared jsonb not null default '{"sms": false, "whatsapp": false, "email": false, "push": false}'::jsonb,
  is_read          boolean not null default false,
  related_type     text,               -- 'coupon' | 'campaign' | 'redemption_request' | 'loyalty_points_ledger'
  related_id       text,
  created_at       timestamptz not null default now()
);

comment on table public.customer_notifications is
  'Customer-facing notification log for the Loyalty & Rewards system (Part 10). channel_prepared records which delivery channels this notification is queued for without any provider actually being wired up yet — see the migration header.';

create index if not exists customer_notifications_phone_idx on public.customer_notifications (phone);
create index if not exists customer_notifications_created_at_idx on public.customer_notifications (created_at);

alter table public.customer_notifications enable row level security;

-- Same open, no-customer-auth trust model as `orders`/`notifications` for
-- staff — anyone can read/write, because there is nothing in this app to
-- authenticate a customer against a phone number yet.
drop policy if exists "customer_notifications_open" on public.customer_notifications;
create policy "customer_notifications_open"
  on public.customer_notifications for all
  to anon, authenticated
  using (true) with check (true);
