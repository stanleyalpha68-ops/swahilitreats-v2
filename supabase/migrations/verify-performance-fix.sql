-- Phase 7.5.3 — run BEFORE applying the migration to capture a baseline,
-- then again AFTER to confirm the plans changed from Seq Scan to Index Scan.
-- (Numbers will vary with table size; the important thing is the plan
-- shape and the row estimates, not the absolute milliseconds on a small
-- dev dataset.)

-- 1. order_items lookup by order_id (every order detail view / delivery step)
explain analyze
select * from public.order_items where order_id = 1;

-- 2. notifications for one employee (every dashboard load)
explain analyze
select * from public.notifications where employee_id = 1 order by created_at desc limit 20;

-- 3. approval_requests pending queue (Approval Center default view)
explain analyze
select * from public.approval_requests where status = 'pending' order by created_at desc;

-- 4. audit_log filtered by actor (audit viewer)
explain analyze
select * from public.audit_log where actor_employee_id = 1 order by created_at desc limit 50;

-- 5. Confirm all new indexes exist
select tablename, indexname
from pg_indexes
where schemaname = 'public'
  and indexname in (
    'order_items_order_id_idx','order_items_product_id_idx',
    'notifications_employee_id_idx',
    'approval_requests_status_idx','approval_requests_requester_id_idx','approval_requests_decided_by_idx',
    'approval_history_approval_id_idx','approval_comments_approval_id_idx','approval_chain_progress_approval_id_idx',
    'audit_log_actor_employee_id_idx','audit_log_created_at_idx','audit_log_entity_idx',
    'inventory_product_id_idx','employee_inventory_employee_id_idx','employee_inventory_product_id_idx',
    'inventory_transactions_employee_id_idx','inventory_transactions_product_id_idx','inventory_transactions_order_id_idx',
    'product_variants_product_id_idx','discounts_active_idx','products_active_idx'
  )
order by tablename;

-- 6. Confirm branches_staff_write now uses the fast helper functions
select policyname, qual, with_check
from pg_policies
where schemaname = 'public' and tablename = 'branches' and policyname = 'branches_staff_write';

-- 7. Spot-check: no policy anywhere still re-queries employees directly
--    from inside a policy (the exact pattern that was slow). This should
--    return zero rows once phase-7.5.2-rls-performance-fix.sql AND this
--    migration are both applied.
select schemaname, tablename, policyname
from pg_policies
where schemaname = 'public'
  and (qual ilike '%from public.employees%' or with_check ilike '%from public.employees%');
