-- Phase 7.5.2 — Production Regression Testing: fix customer checkout
-- ("⚠️ Could not place orders. Please try again.")
--
-- ROOT CAUSE
-- `orders_anon_checkout` (phase-7.5-security-hardening.sql) grants the
-- anon role INSERT on public.orders — but no matching SELECT policy.
-- products.html's checkout does:
--     db.from("orders").insert([...]).select("id").single()
-- which asks PostgREST for `INSERT ... RETURNING id`. Postgres RLS filters
-- RETURNING rows through the SELECT policies too, not just the INSERT
-- policy's WITH CHECK — with zero SELECT policy for anon, RETURNING comes
-- back with 0 rows. supabase-js's `.single()` then reports that as an
-- error, even though the row was in fact inserted successfully.
--
-- Net effect: every checkout attempt silently created a real, orphaned
-- "pending" order (no matching order_items row, since the code never
-- reaches that step) while showing the customer a hard failure — and every
-- retry created another orphaned order for the same cart.
--
-- FIX
-- Do not add a blanket anon SELECT policy on orders — that would expose
-- every customer's name/phone/room to anyone (exactly what the original
-- hardening migration was written to prevent). Instead add one more
-- narrow, single-value SECURITY DEFINER lookup, the same pattern already
-- used for get_order_for_tracking / get_orders_by_phone / get_orders_by_ids
-- / get_order_notifications. This one returns only the numeric id, keyed
-- by the order_id the client itself just generated, so the checkout flow
-- can insert the matching order_items row without ever reading the orders
-- table directly.

create or replace function public.get_order_numeric_id(p_order_id text)
returns bigint
language sql
security definer
set search_path = public
stable
as $$
  select id from public.orders where order_id = p_order_id limit 1;
$$;

revoke all on function public.get_order_numeric_id(text) from public, authenticated, anon;
grant execute on function public.get_order_numeric_id(text) to anon, authenticated;
