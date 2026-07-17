-- Phase 7.5.2 — run in the Supabase SQL editor to confirm the checkout
-- fix is correctly in place.

-- 1. Confirm orders has an anon INSERT policy but (by design) no anon
--    SELECT policy — this is expected and correct, not a bug to "fix"
--    further; the RPC below is what replaces the need for it.
select policyname, cmd, roles
from pg_policies
where schemaname = 'public' and tablename = 'orders'
order by cmd, policyname;

-- 2. Confirm order_items has an anon INSERT policy (oi_anon_checkout).
--    If this row is missing, order_items will still silently fail after
--    the orders-insert issue is fixed — apply phase-7.5.2-rls-performance-fix.sql
--    (renamed with a timestamp prefix, same as before) if so.
select policyname, cmd, roles
from pg_policies
where schemaname = 'public' and tablename = 'order_items'
order by cmd, policyname;

-- 3. Confirm the new lookup function exists and only anon/authenticated
--    can call it (never public/no grants beyond that).
select p.proname, r.rolname, has_function_privilege(r.oid, p.oid, 'EXECUTE') as can_execute
from pg_proc p
join pg_roles r on r.rolname in ('anon','authenticated','service_role')
where p.proname = 'get_order_numeric_id'
order by r.rolname;

-- 4. Sanity check: no orphaned orders (pending, no matching order_items)
--    created during earlier failed-checkout attempts. Safe to review/clean
--    up manually — these were customers whose "Could not place orders"
--    error masked an order that actually landed in the table.
select o.id, o.order_id, o.customer_name, o.phone, o.product, o.created_at
from public.orders o
left join public.order_items oi on oi.order_id = o.id
where oi.id is null
  and o.status = 'pending'
order by o.created_at desc
limit 50;
