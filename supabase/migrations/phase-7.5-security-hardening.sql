-- ============================================================================
-- PHASE 7.5 — Security Audit: closing RLS gaps
-- ============================================================================
-- METHOD / CAVEAT (read first): this was found by grepping every migration
-- file in supabase/migrations/ for "enable row level security" and diffing
-- against every table in the schema. 30 tables had a matching migration;
-- the 19 below did not. That does NOT prove these tables are unprotected
-- in the live project today — RLS may have been switched on by hand in the
-- Supabase dashboard for some of the earliest (pre-migrations-folder)
-- tables and simply never captured in a checked-in file. Either way, the
-- fix is the same: verify live state, then run this (every statement below
-- is idempotent — enabling RLS that's already on, or dropping-then-creating
-- a policy that already exists, is a safe no-op).
--
-- To verify current live state before running, execute in the SQL editor:
--   select relname, relrowsecurity
--   from pg_class
--   where relname in (
--     'employees','orders','products','announcements','inventory','discounts',
--     'product_variants','push_subscriptions','employee_inventory',
--     'inventory_transactions','order_items','employee_activity',
--     'approval_requests','approval_history','approval_comments',
--     'workflow_definitions','approval_chain_progress','audit_log','notifications'
--   );
-- relrowsecurity = false means the table is genuinely open right now.
--
-- SEVERITY NOTE — public.orders: this is the one finding that matters most.
-- track.html and customer-hub.html need anon (no-login) reads of orders by
-- order_id or phone for order tracking, and products.html needs anon INSERT
-- for checkout. But RLS cannot restrict a SELECT to "only the row the
-- client happened to filter for" — a USING clause that allows anon to read
-- orders at all lets anon read EVERY order (every customer's name, phone,
-- and address) via a direct REST call, regardless of what filter the
-- client-side code sends. The only correct fix is to stop giving anon
-- table access at all and instead expose narrow SECURITY DEFINER functions
-- that take an order_id or phone as a parameter and return only matching
-- rows. That's what Part 2 of this migration does; track.html/customer-hub.html
-- are updated in the same phase to call them instead of querying the table
-- directly.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Internal-only tables — no anon access at all, staff-only by default
-- ----------------------------------------------------------------------------
-- These are never read by index.html/products.html/track.html/customer-hub.html
-- (verified by grep), so the safe default is: any authenticated user with a
-- row in public.employees can read; only Owner/Admin can write. Where the
-- app's existing UI already implies a narrower posture (e.g. audit_log is
-- append-only), that's tightened further below.

alter table public.employee_inventory enable row level security;
drop policy if exists "ei_staff_read" on public.employee_inventory;
create policy "ei_staff_read" on public.employee_inventory for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "ei_staff_write" on public.employee_inventory;
create policy "ei_staff_write" on public.employee_inventory for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

alter table public.inventory_transactions enable row level security;
drop policy if exists "invtx_staff_read" on public.inventory_transactions;
create policy "invtx_staff_read" on public.inventory_transactions for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "invtx_staff_write" on public.inventory_transactions;
create policy "invtx_staff_write" on public.inventory_transactions for insert to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

alter table public.inventory enable row level security;
drop policy if exists "inv_staff_all" on public.inventory;
create policy "inv_staff_all" on public.inventory for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

alter table public.product_variants enable row level security;
drop policy if exists "pv_public_read" on public.product_variants;
create policy "pv_public_read" on public.product_variants for select to anon, authenticated using (active = true);
drop policy if exists "pv_staff_write" on public.product_variants;
create policy "pv_staff_write" on public.product_variants for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));

alter table public.discounts enable row level security;
drop policy if exists "disc_staff_all" on public.discounts;
create policy "disc_staff_all" on public.discounts for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));

alter table public.order_items enable row level security;
drop policy if exists "oi_staff_all" on public.order_items;
create policy "oi_staff_all" on public.order_items for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

alter table public.employee_activity enable row level security;
drop policy if exists "ea_staff_read" on public.employee_activity;
create policy "ea_staff_read" on public.employee_activity for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "ea_staff_write" on public.employee_activity;
create policy "ea_staff_write" on public.employee_activity for insert to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

alter table public.push_subscriptions enable row level security;
drop policy if exists "ps_staff_all" on public.push_subscriptions;
create policy "ps_staff_all" on public.push_subscriptions for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

-- Approval Center (Phases 6.x). Requester needs to see their own requests;
-- deciding (update) stays Owner/Admin, matching the existing Approval
-- Center UI posture. No anon access — this workflow is 100% internal.
alter table public.approval_requests enable row level security;
drop policy if exists "ar_staff_read" on public.approval_requests;
create policy "ar_staff_read" on public.approval_requests for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "ar_staff_insert" on public.approval_requests;
create policy "ar_staff_insert" on public.approval_requests for insert to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "ar_admin_decide" on public.approval_requests;
create policy "ar_admin_decide" on public.approval_requests for update to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));

alter table public.approval_history enable row level security;
drop policy if exists "ah_staff_read" on public.approval_history;
create policy "ah_staff_read" on public.approval_history for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "ah_staff_insert" on public.approval_history;
create policy "ah_staff_insert" on public.approval_history for insert to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

alter table public.approval_comments enable row level security;
drop policy if exists "ac_staff_all" on public.approval_comments;
create policy "ac_staff_all" on public.approval_comments for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

alter table public.approval_chain_progress enable row level security;
drop policy if exists "acp_staff_read" on public.approval_chain_progress;
create policy "acp_staff_read" on public.approval_chain_progress for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "acp_admin_write" on public.approval_chain_progress;
create policy "acp_admin_write" on public.approval_chain_progress for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));

alter table public.workflow_definitions enable row level security;
drop policy if exists "wd_staff_read" on public.workflow_definitions;
create policy "wd_staff_read" on public.workflow_definitions for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "wd_admin_write" on public.workflow_definitions;
create policy "wd_admin_write" on public.workflow_definitions for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));

-- Audit Trail — append-only by every module already (createAuditRecord()).
-- No update/delete policy is created at all, which means Postgres denies
-- those actions outright: history that "must never be editable" (the same
-- rule Settings Center's Configuration History already follows) is now
-- enforced by the database, not just by the UI never offering an edit button.
alter table public.audit_log enable row level security;
drop policy if exists "audit_staff_read" on public.audit_log;
create policy "audit_staff_read" on public.audit_log for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));
drop policy if exists "audit_staff_insert" on public.audit_log;
create policy "audit_staff_insert" on public.audit_log for insert to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

-- Employee-facing notifications — each employee sees only their own;
-- any authenticated staff member can create one (system/admin-triggered).
alter table public.notifications enable row level security;
drop policy if exists "notif_own_read" on public.notifications;
create policy "notif_own_read" on public.notifications for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.id = notifications.employee_id));
drop policy if exists "notif_own_update" on public.notifications;
create policy "notif_own_update" on public.notifications for update to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and e.id = notifications.employee_id));
drop policy if exists "notif_staff_insert" on public.notifications;
create policy "notif_staff_insert" on public.notifications for insert to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid()));

-- employees — every staff member can see the directory (needed for
-- assignment pickers, branch rosters, etc. throughout admin.html/employee
-- portal); only Owner/Admin can create/deactivate/change roles. Employees
-- may update their own row (status, last_seen) but not their own role or
-- is_owner flag — enforced by checking those two columns are unchanged.
alter table public.employees enable row level security;
drop policy if exists "emp_staff_read" on public.employees;
create policy "emp_staff_read" on public.employees for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "emp_admin_write" on public.employees;
create policy "emp_admin_write" on public.employees for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));
drop policy if exists "emp_self_update" on public.employees;
create policy "emp_self_update" on public.employees for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and role = (select role from public.employees where user_id = auth.uid())
              and is_owner = (select is_owner from public.employees where user_id = auth.uid()));

-- products / announcements — genuinely public marketing data, no PII.
-- Anon read of active rows only; writes stay staff-only.
alter table public.products enable row level security;
drop policy if exists "prod_public_read" on public.products;
create policy "prod_public_read" on public.products for select to anon, authenticated using (active = true);
drop policy if exists "prod_staff_full_read" on public.products;
create policy "prod_staff_full_read" on public.products for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "prod_staff_write" on public.products;
create policy "prod_staff_write" on public.products for insert to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));
drop policy if exists "prod_staff_update" on public.products;
create policy "prod_staff_update" on public.products for update to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));
drop policy if exists "prod_staff_delete" on public.products;
create policy "prod_staff_delete" on public.products for delete to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));

alter table public.announcements enable row level security;
drop policy if exists "ann_public_read" on public.announcements;
create policy "ann_public_read" on public.announcements for select to anon, authenticated using (active = true);
drop policy if exists "ann_staff_full_read" on public.announcements;
create policy "ann_staff_full_read" on public.announcements for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));
drop policy if exists "ann_staff_write" on public.announcements;
create policy "ann_staff_write" on public.announcements for all to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner or e.role = 'admin')));


-- ----------------------------------------------------------------------------
-- 2. public.orders — deny anon table access; expose narrow RPCs instead
-- ----------------------------------------------------------------------------
alter table public.orders enable row level security;

drop policy if exists "orders_staff_read" on public.orders;
create policy "orders_staff_read" on public.orders for select to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));

drop policy if exists "orders_staff_write" on public.orders;
create policy "orders_staff_write" on public.orders for update to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));

-- Anon checkout insert — locked to the exact "fresh pending order" shape
-- products.html already sends, so a spoofed insert can't claim a delivered
-- status, assign itself to an employee, or attach to a branch/order-lock.
drop policy if exists "orders_anon_checkout" on public.orders;
create policy "orders_anon_checkout" on public.orders for insert to anon, authenticated
  with check (
    status = 'pending'
    and assigned_employee_id is null
    and accepted_at is null
    and preparation_started_at is null
    and delivery_started_at is null
    and delivered_at is null
    and completed_at is null
    and locked_until is null
  );

-- Narrow, read-only lookups for the customer-facing tracking pages —
-- SECURITY DEFINER so they can read the table on the caller's behalf, but
-- each only returns the columns track.html/customer-hub.html already
-- display and only rows matching the parameter (never a full-table scan).
create or replace function public.get_order_for_tracking(p_order_id text)
returns table (
  order_id text, customer_name text, phone text, campus text, hostel text, room text,
  product text, quantity smallint, unit_price integer, total_price integer, status text,
  created_at timestamp, accepted_at timestamp, preparation_started_at timestamp,
  delivery_started_at timestamp, delivered_at timestamp, completed_at timestamp
)
language sql security definer set search_path = public stable as $$
  select order_id, customer_name, phone, campus, hostel, room, product, quantity,
         unit_price, total_price, status, created_at, accepted_at,
         preparation_started_at, delivery_started_at, delivered_at, completed_at
  from public.orders
  where order_id = p_order_id;
$$;

create or replace function public.get_orders_by_phone(p_phone text, p_limit integer default 20)
returns table (
  order_id text, product text, quantity smallint, total_price integer, status text,
  created_at timestamp, unit_price integer, accepted_at timestamp,
  preparation_started_at timestamp, delivery_started_at timestamp,
  delivered_at timestamp, customer_name text
)
language sql security definer set search_path = public stable as $$
  select order_id, product, quantity, total_price, status, created_at, unit_price,
         accepted_at, preparation_started_at, delivery_started_at, delivered_at, customer_name
  from public.orders
  where phone = p_phone
  order by created_at desc
  limit least(p_limit, 500);
$$;

create or replace function public.get_orders_by_ids(p_order_ids text[])
returns table (order_id text, product text, quantity smallint, total_price integer, status text, created_at timestamp, phone text)
language sql security definer set search_path = public stable as $$
  select order_id, product, quantity, total_price, status, created_at, phone
  from public.orders
  where order_id = any(p_order_ids)
  limit 50;
$$;

create or replace function public.get_order_notifications(p_phone text, p_limit integer default 30)
returns table (
  order_id text, status text, created_at timestamp, accepted_at timestamp,
  preparation_started_at timestamp, delivery_started_at timestamp, delivered_at timestamp
)
language sql security definer set search_path = public stable as $$
  select order_id, status, created_at, accepted_at, preparation_started_at,
         delivery_started_at, delivered_at
  from public.orders
  where phone = p_phone
  order by created_at desc
  limit least(p_limit, 50);
$$;

-- anon/authenticated may call these four; they can never touch the table
-- directly beyond the checkout insert above.
grant execute on function public.get_order_for_tracking(text) to anon, authenticated;
grant execute on function public.get_orders_by_phone(text, integer) to anon, authenticated;
grant execute on function public.get_orders_by_ids(text[]) to anon, authenticated;
grant execute on function public.get_order_notifications(text, integer) to anon, authenticated;

-- ============================================================================
-- END PHASE 7.5 SECURITY MIGRATION
-- ============================================================================
