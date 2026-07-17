-- Phase 7.5.3 — Performance Optimization (Task 1: DB Query & RLS)
--
-- Pure performance work: no schema/behavior change, no new features, no
-- workflow change. Every statement below either (a) adds an index that
-- lets Postgres avoid a sequential scan it was otherwise doing on a hot
-- path, or (b) swaps a per-row re-query in an RLS policy for the existing
-- cached SECURITY DEFINER helper functions (public.current_employee_id() /
-- current_employee_role() / current_employee_is_owner(), introduced in
-- phase-7.5.1b and already used everywhere else). Results returned to the
-- application are identical before and after.

-- ── order_items ────────────────────────────────────────────────────────
-- Previously had NO indexes at all beyond the primary key. Every order
-- detail view, delivery-completion check, and per-product sales rollup
-- joins on order_id or product_id — both were full table scans.
create index if not exists order_items_order_id_idx on public.order_items (order_id);
create index if not exists order_items_product_id_idx on public.order_items (product_id);

-- ── notifications ─────────────────────────────────────────────────────
-- Indexed on category and is_pinned, but not on employee_id — the actual
-- filter used by every employee's notification bell/dropdown on every
-- page load (`where employee_id = ...`).
create index if not exists notifications_employee_id_idx on public.notifications (employee_id);

-- ── approval_requests ────────────────────────────────────────────────
-- Zero indexes previously. Approval Center's default view filters by
-- status = 'pending' constantly, and history/detail views filter by
-- requester_id and decided_by.
create index if not exists approval_requests_status_idx on public.approval_requests (status);
create index if not exists approval_requests_requester_id_idx on public.approval_requests (requester_id);
create index if not exists approval_requests_decided_by_idx on public.approval_requests (decided_by);

-- ── approval_history / approval_comments / approval_chain_progress ────
-- Each is looked up by approval_id every time a single approval's detail
-- panel is opened — none had an index on that column.
create index if not exists approval_history_approval_id_idx on public.approval_history (approval_id);
create index if not exists approval_comments_approval_id_idx on public.approval_comments (approval_id);
create index if not exists approval_chain_progress_approval_id_idx on public.approval_chain_progress (approval_id);

-- ── audit_log ────────────────────────────────────────────────────────
-- Zero indexes previously on a table that only grows. Audit viewers
-- filter by actor, by entity, and sort by recency.
create index if not exists audit_log_actor_employee_id_idx on public.audit_log (actor_employee_id);
create index if not exists audit_log_created_at_idx on public.audit_log (created_at desc);
create index if not exists audit_log_entity_idx on public.audit_log (entity_type, entity_id);

-- ── inventory / employee_inventory / inventory_transactions ───────────
-- FK columns joined on every stock view and every delivery/restock action;
-- none were indexed beyond the primary key.
create index if not exists inventory_product_id_idx on public.inventory (product_id);
create index if not exists employee_inventory_employee_id_idx on public.employee_inventory (employee_id);
create index if not exists employee_inventory_product_id_idx on public.employee_inventory (product_id);
create index if not exists inventory_transactions_employee_id_idx on public.inventory_transactions (employee_id);
create index if not exists inventory_transactions_product_id_idx on public.inventory_transactions (product_id);
create index if not exists inventory_transactions_order_id_idx on public.inventory_transactions (order_id);

-- ── product_variants / discounts / products ────────────────────────────
-- product_variants.product_id: joined once per product render.
-- discounts.active: fetchActiveDiscounts() runs this exact filter on
-- every checkout and every product page load (products.html,
-- customer-hub.html) — small table today, but an unindexed boolean scan
-- that runs on effectively every storefront request.
-- products.active: the single most frequent anon query in the app
-- (every visitor, every page load).
create index if not exists product_variants_product_id_idx on public.product_variants (product_id);
create index if not exists discounts_active_idx on public.discounts (active) where active = true;
create index if not exists products_active_idx on public.products (active) where active = true;

-- ── branches — leftover unoptimized RLS policy ─────────────────────────
-- phase-7.5.2-rls-performance-fix.sql swept every table's staff-check
-- policies over to the cached current_employee_*() helpers except this
-- one, which was introduced earlier (phase-6.8-analytics-center.sql) and
-- missed in that sweep. It still re-queries public.employees — itself
-- RLS-protected — from inside a policy on every branch write, on every
-- request. Same fix, same helper functions, no behavior change.
drop policy if exists "branches_staff_write" on public.branches;
create policy "branches_staff_write" on public.branches for all to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin')
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');
