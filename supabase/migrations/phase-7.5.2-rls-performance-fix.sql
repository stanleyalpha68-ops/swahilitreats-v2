-- Phase 7.5.2 — RLS performance fix.
--
-- Phase 7.5.1B introduced public.current_employee_id() /
-- current_employee_role() / current_employee_is_owner() (SECURITY DEFINER,
-- STABLE) specifically to stop the employees table's own RLS policies from
-- re-querying employees from within a policy ON employees.
--
-- That fix was only ever applied to the `employees` table itself. Every
-- other policy phase-7.5-security-hardening.sql created — on orders,
-- order_items, approval_requests, approval_history, approval_comments,
-- approval_chain_progress, workflow_definitions, audit_log, notifications,
-- products, announcements, employee_inventory, inventory_transactions,
-- inventory, product_variants, discounts, employee_activity, and
-- push_subscriptions — still runs its own uncached
--   exists (select 1 from public.employees e where e.user_id = auth.uid())
-- subquery, against a table that is itself RLS-protected. That's evaluated
-- on every row check, for every request, on nearly every table in the app —
-- which is exactly the ~1000ms response time System Status reports on
-- almost every module. This migration swaps all of it over to the fast
-- STABLE helper functions, the same way employees' own policies were fixed.
--
-- Safe to re-run: every policy is dropped and recreated.

-- ── employee_inventory ──────────────────────────────────────────────────
drop policy if exists "ei_staff_read" on public.employee_inventory;
create policy "ei_staff_read" on public.employee_inventory for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "ei_staff_write" on public.employee_inventory;
create policy "ei_staff_write" on public.employee_inventory for all to authenticated
  using (public.current_employee_id() is not null)
  with check (public.current_employee_id() is not null);

-- ── inventory_transactions ──────────────────────────────────────────────
drop policy if exists "invtx_staff_read" on public.inventory_transactions;
create policy "invtx_staff_read" on public.inventory_transactions for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "invtx_staff_write" on public.inventory_transactions;
create policy "invtx_staff_write" on public.inventory_transactions for insert to authenticated
  with check (public.current_employee_id() is not null);

-- ── inventory ────────────────────────────────────────────────────────────
drop policy if exists "inv_staff_all" on public.inventory;
create policy "inv_staff_all" on public.inventory for all to authenticated
  using (public.current_employee_id() is not null)
  with check (public.current_employee_id() is not null);

-- ── product_variants ────────────────────────────────────────────────────
drop policy if exists "pv_staff_write" on public.product_variants;
create policy "pv_staff_write" on public.product_variants for all to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin')
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');

-- ── discounts ────────────────────────────────────────────────────────────
drop policy if exists "disc_staff_all" on public.discounts;
create policy "disc_staff_all" on public.discounts for all to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin')
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');

-- ── order_items ──────────────────────────────────────────────────────────
drop policy if exists "oi_staff_all" on public.order_items;
create policy "oi_staff_all" on public.order_items for all to authenticated
  using (public.current_employee_id() is not null)
  with check (public.current_employee_id() is not null);

-- Phase 7.5.2 — missing piece: order_items previously had no policy at
-- all for the `anon` role, only `authenticated` staff. Customers checking
-- out on products.html/customer-hub.html insert with the anon key, so
-- their order_items rows (the ones this migration's products.html fix now
-- writes) were being silently blocked by RLS with zero policy match.
-- Same trust boundary as "orders_anon_checkout": quantity/prices must be
-- non-negative, and order_id must reference a real order (enforced by the
-- existing FK) — there is nothing sensitive an anon insert here can forge.
drop policy if exists "oi_anon_checkout" on public.order_items;
create policy "oi_anon_checkout" on public.order_items for insert to anon
  with check (quantity > 0 and unit_price >= 0 and total_price >= 0);

-- ── employee_activity ────────────────────────────────────────────────────
drop policy if exists "ea_staff_read" on public.employee_activity;
create policy "ea_staff_read" on public.employee_activity for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "ea_staff_write" on public.employee_activity;
create policy "ea_staff_write" on public.employee_activity for insert to authenticated
  with check (public.current_employee_id() is not null);

-- ── push_subscriptions ───────────────────────────────────────────────────
drop policy if exists "ps_staff_all" on public.push_subscriptions;
create policy "ps_staff_all" on public.push_subscriptions for all to authenticated
  using (public.current_employee_id() is not null)
  with check (public.current_employee_id() is not null);

-- ── approval_requests ────────────────────────────────────────────────────
drop policy if exists "ar_staff_read" on public.approval_requests;
create policy "ar_staff_read" on public.approval_requests for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "ar_staff_insert" on public.approval_requests;
create policy "ar_staff_insert" on public.approval_requests for insert to authenticated
  with check (public.current_employee_id() is not null);
drop policy if exists "ar_admin_decide" on public.approval_requests;
create policy "ar_admin_decide" on public.approval_requests for update to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin');

-- ── approval_history ─────────────────────────────────────────────────────
drop policy if exists "ah_staff_read" on public.approval_history;
create policy "ah_staff_read" on public.approval_history for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "ah_staff_insert" on public.approval_history;
create policy "ah_staff_insert" on public.approval_history for insert to authenticated
  with check (public.current_employee_id() is not null);

-- ── approval_comments ─────────────────────────────────────────────────────
drop policy if exists "ac_staff_all" on public.approval_comments;
create policy "ac_staff_all" on public.approval_comments for all to authenticated
  using (public.current_employee_id() is not null)
  with check (public.current_employee_id() is not null);

-- ── approval_chain_progress ──────────────────────────────────────────────
drop policy if exists "acp_staff_read" on public.approval_chain_progress;
create policy "acp_staff_read" on public.approval_chain_progress for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "acp_admin_write" on public.approval_chain_progress;
create policy "acp_admin_write" on public.approval_chain_progress for all to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin')
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');

-- ── workflow_definitions ─────────────────────────────────────────────────
drop policy if exists "wd_staff_read" on public.workflow_definitions;
create policy "wd_staff_read" on public.workflow_definitions for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "wd_admin_write" on public.workflow_definitions;
create policy "wd_admin_write" on public.workflow_definitions for all to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin')
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');

-- ── audit_log ─────────────────────────────────────────────────────────────
drop policy if exists "audit_staff_read" on public.audit_log;
create policy "audit_staff_read" on public.audit_log for select to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin');
drop policy if exists "audit_staff_insert" on public.audit_log;
create policy "audit_staff_insert" on public.audit_log for insert to authenticated
  with check (public.current_employee_id() is not null);

-- ── notifications ─────────────────────────────────────────────────────────
drop policy if exists "notif_own_read" on public.notifications;
create policy "notif_own_read" on public.notifications for select to authenticated
  using (notifications.employee_id = public.current_employee_id());
drop policy if exists "notif_own_update" on public.notifications;
create policy "notif_own_update" on public.notifications for update to authenticated
  using (notifications.employee_id = public.current_employee_id());
drop policy if exists "notif_staff_insert" on public.notifications;
create policy "notif_staff_insert" on public.notifications for insert to authenticated
  with check (public.current_employee_id() is not null);

-- ── products ─────────────────────────────────────────────────────────────
drop policy if exists "prod_staff_full_read" on public.products;
create policy "prod_staff_full_read" on public.products for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "prod_staff_write" on public.products;
create policy "prod_staff_write" on public.products for insert to authenticated
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');
drop policy if exists "prod_staff_update" on public.products;
create policy "prod_staff_update" on public.products for update to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin');
drop policy if exists "prod_staff_delete" on public.products;
create policy "prod_staff_delete" on public.products for delete to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin');

-- ── announcements ────────────────────────────────────────────────────────
drop policy if exists "ann_staff_full_read" on public.announcements;
create policy "ann_staff_full_read" on public.announcements for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "ann_staff_write" on public.announcements;
create policy "ann_staff_write" on public.announcements for all to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin')
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');

-- ── orders ───────────────────────────────────────────────────────────────
drop policy if exists "orders_staff_read" on public.orders;
create policy "orders_staff_read" on public.orders for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "orders_staff_write" on public.orders;
create policy "orders_staff_write" on public.orders for update to authenticated
  using (public.current_employee_id() is not null);

-- Note: emp_staff_read / emp_admin_write / emp_self_update on
-- public.employees itself are intentionally left untouched — phase-7.5.1b
-- already fixed those, and they're the source of the helper functions
-- used above.
