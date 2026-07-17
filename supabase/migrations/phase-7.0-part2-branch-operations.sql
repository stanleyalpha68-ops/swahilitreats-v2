-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 7.0 (Part 2/4) Migration
-- Enterprise Branch Operations
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once,
-- AFTER phase-7.0-branch-management-foundation.sql (Part 1) — this
-- migration references `branches` and `employees.branch_id`, both
-- created there. Additive only.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT PART 1 ALREADY BUILT (read this first)
-- ───────────────────────────────────────────────────────────────────────
-- `branches` (status lifecycle, manager_employee_id, hours, delivery
-- radius, etc.) and `employees.branch_id` (a plain FK, no history) both
-- already exist. Part 1's own scope note explicitly deferred Branch
-- Employee Management, Branch Inventory, and Branch Analytics/Financials
-- to later — this migration is Part 2 of that plan (Branch
-- Analytics/Financials stay deferred to Part 3, per this phase's own
-- closing instruction).
--
-- ───────────────────────────────────────────────────────────────────────
-- THE ONE DECISION WORTH EXPLAINING: branch_inventory is a NEW table,
-- not a branch_id column on the existing `inventory` table
-- ───────────────────────────────────────────────────────────────────────
-- `inventory` today is exactly one row per product — the Admin Inventory
-- tab, the employee stock-assignment flow, and low-stock alerts across
-- Analytics/Financial/Operations Centers all assume that. Adding a
-- nullable branch_id to that same table would let a product have
-- multiple rows (one per branch), which silently breaks every one of
-- those existing `.select()` calls that don't already filter by
-- branch — they'd start summing or double-counting stock across
-- locations without any error, the worst kind of regression because
-- nothing would look wrong until the numbers were already trusted.
--
-- So branch-level stock is a parallel table, `branch_inventory`, and the
-- original `inventory` table keeps meaning exactly what it always
-- meant — the shared/main stock pool — untouched. A branch that hasn't
-- been given its own inventory yet simply has no rows here, which is a
-- correct, honest state (not an error), matching the Wizard's `empty`
-- inventory-plan option from Part 1.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION ADDS
-- ───────────────────────────────────────────────────────────────────────
--   1. branch_employee_transfers — Part 1's "record previous branch, new
--      branch, reason, date" for every employee move, including
--      temporary assignments (Part 1's own explicit ask). employees.
--      branch_id is still the source of truth for "where is this person
--      right now" — this table is the history of how they got there.
--   2. branch_inventory — Part 3, explained above.
--   3. inventory_transfers — Part 3's transfer/approval/history. Moving
--      stock between two branches, or between "main" (null branch) and
--      a branch, is one row each way; execute_inventory_transfer()
--      (below) is the transactional function that actually moves the
--      numbers once a transfer is approved (or immediately, if the
--      configured threshold doesn't require approval — see the
--      function's own comment).
--   4. orders.branch_id — nullable FK, Part 4's "every order must belong
--      to a branch." Existing orders keep working with branch_id=null;
--      a best-effort one-time backfill below matches historical orders
--      to a branch by campus, wherever a branch's `campus` column
--      already matches (Part 1's branches.campus was added for exactly
--      this reason). New orders get branch_id from checkout going
--      forward — see the application code for exactly where that's set.
--   5. business_rules('branches') — the two explicitly-configurable
--      rules this phase asks for: allow_multi_branch_employees (default
--      false) and single_manager_per_branch (default true), plus an
--      inventory_transfer_approval_threshold used by
--      execute_inventory_transfer().
--   6. execute_inventory_transfer(p_transfer_id) — a real Postgres
--      transaction (same reasoning as Part 1's branch-creation
--      function): decrementing the source and incrementing the
--      destination must both happen or neither does.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. branch_employee_transfers (Part 1)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.branch_employee_transfers (
  id              bigint generated always as identity primary key,
  employee_id     bigint not null references public.employees (id) on delete cascade,
  from_branch_id  bigint references public.branches (id) on delete set null,   -- null = was unassigned
  to_branch_id    bigint references public.branches (id) on delete set null,   -- null = made unassigned
  transfer_type   text not null default 'permanent' check (transfer_type = any (array['permanent','temporary'])),
  reason          text,
  effective_date  date not null default current_date,
  ends_at         date,                -- only meaningful for temporary transfers
  transferred_by  text,
  created_at      timestamptz not null default now()
);

comment on table public.branch_employee_transfers is
  'Phase 7.0 Part 2 — history of every employee branch assignment/transfer. employees.branch_id (Part 1) always reflects the current assignment; this table is the audit trail of how it changed, written by transferEmployee()/assignEmployeeToBranch() in admin.html alongside the employees.branch_id update itself.';

create index if not exists branch_employee_transfers_employee_idx on public.branch_employee_transfers (employee_id);
create index if not exists branch_employee_transfers_created_at_idx on public.branch_employee_transfers (created_at);

alter table public.branch_employee_transfers enable row level security;

drop policy if exists "branch_employee_transfers_read" on public.branch_employee_transfers;
create policy "branch_employee_transfers_read"
  on public.branch_employee_transfers for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin' or e.role = 'manager')));

drop policy if exists "branch_employee_transfers_write" on public.branch_employee_transfers;
create policy "branch_employee_transfers_write"
  on public.branch_employee_transfers for insert
  to authenticated
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin')));


-- ───────────────────────────────────────────────────────────────────────
-- 2. branch_inventory (Part 3) — see the header for why this is a new
--    table rather than a column on `inventory`
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.branch_inventory (
  id                   bigint generated always as identity primary key,
  branch_id            bigint not null references public.branches (id) on delete cascade,
  product_id           bigint not null references public.products (id) on delete cascade,
  stock                integer not null default 0 check (stock >= 0),
  reserved_stock       integer not null default 0 check (reserved_stock >= 0),
  low_stock_threshold  integer not null default 10,
  updated_at           timestamptz not null default now(),
  unique (branch_id, product_id)
);

comment on table public.branch_inventory is
  'Phase 7.0 Part 3 — independent per-branch stock, parallel to (not replacing) the original `inventory` table. reserved_stock is stock committed to an in-progress order/transfer but not yet deducted — "available to sell" is stock - reserved_stock, computed at read time, not stored.';

create index if not exists branch_inventory_branch_idx on public.branch_inventory (branch_id);
create index if not exists branch_inventory_product_idx on public.branch_inventory (product_id);

create or replace function public.set_branch_inventory_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_branch_inventory_updated_at on public.branch_inventory;
create trigger trg_branch_inventory_updated_at
  before update on public.branch_inventory
  for each row execute function public.set_branch_inventory_updated_at();

alter table public.branch_inventory enable row level security;

drop policy if exists "branch_inventory_read" on public.branch_inventory;
create policy "branch_inventory_read"
  on public.branch_inventory for select to authenticated using (true);   -- branch-scoped visibility is enforced in the app (Part 9) same as every other per-branch screen this phase adds

drop policy if exists "branch_inventory_write" on public.branch_inventory;
create policy "branch_inventory_write"
  on public.branch_inventory for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin' or e.role = 'manager')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin' or e.role = 'manager')));


-- ───────────────────────────────────────────────────────────────────────
-- 3. inventory_transfers (Part 3)
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.inventory_transfers (
  id               bigint generated always as identity primary key,
  product_id       bigint not null references public.products (id) on delete cascade,
  quantity         integer not null check (quantity > 0),
  from_branch_id   bigint references public.branches (id) on delete set null,   -- null = from main/unassigned inventory
  to_branch_id     bigint references public.branches (id) on delete set null,   -- null = to main/unassigned inventory
  status           text not null default 'pending' check (status = any (array['pending','approved','completed','rejected','cancelled'])),
  requires_approval boolean not null default false,
  approval_id      bigint references public.approval_requests (id) on delete set null,
  reason           text,
  requested_by     text,
  approved_by      text,
  requested_at     timestamptz not null default now(),
  completed_at     timestamptz
);

comment on table public.inventory_transfers is
  'Phase 7.0 Part 3. A transfer with from_branch_id/to_branch_id both null is meaningless and rejected at the application layer — one side must be a real branch. requires_approval is decided at request time from business_rules(''branches'').inventory_transfer_approval_threshold; execute_inventory_transfer() below is what actually moves stock once a transfer reaches ''approved'' (or immediately, for transfers under the threshold).';

create index if not exists inventory_transfers_status_idx on public.inventory_transfers (status);
create index if not exists inventory_transfers_product_idx on public.inventory_transfers (product_id);

alter table public.inventory_transfers enable row level security;

drop policy if exists "inventory_transfers_read" on public.inventory_transfers;
create policy "inventory_transfers_read"
  on public.inventory_transfers for select
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid()));

drop policy if exists "inventory_transfers_write" on public.inventory_transfers;
create policy "inventory_transfers_write"
  on public.inventory_transfers for all
  to authenticated
  using (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin' or e.role = 'manager')))
  with check (exists (select 1 from public.employees e where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin' or e.role = 'manager')));


-- ───────────────────────────────────────────────────────────────────────
-- 4. orders.branch_id (Part 4)
-- ───────────────────────────────────────────────────────────────────────
alter table public.orders add column if not exists branch_id bigint references public.branches (id) on delete set null;
create index if not exists orders_branch_id_idx on public.orders (branch_id);

comment on column public.orders.branch_id is
  'Phase 7.0 Part 2. Null for historical orders and any order placed before a branch existed for its campus — see the one-time backfill below and the application''s checkout code for how new orders get this set going forward.';

-- Best-effort, one-time backfill: match historical orders to a branch
-- purely by campus text equality, only where that's unambiguous (a
-- campus value that matches exactly one active branch). Anything
-- ambiguous or unmatched is left null rather than guessed at.
update public.orders o
set branch_id = b.id
from public.branches b
where o.branch_id is null
  and o.campus is not null
  and o.campus = b.campus
  and (select count(*) from public.branches b2 where b2.campus = o.campus) = 1;


-- ───────────────────────────────────────────────────────────────────────
-- 5. business_rules('branches') — Part 1's "configurable through the
--    Business Rules Center" and Part 3's transfer-approval threshold
-- ───────────────────────────────────────────────────────────────────────
insert into public.business_rules (category, label, icon, sort_order, rules)
values (
  'branches', 'Branch Operations', '🏬', 95,
  jsonb_build_object(
    'allow_multi_branch_employees', false,
    'single_manager_per_branch', true,
    'inventory_transfer_approval_threshold', 50
  )
)
on conflict (category) do nothing;

-- Also seed the 'inventory_transfer' approval type (same mechanism as
-- Part 1's branch types — see that migration's section 4 for the full
-- explanation) so a transfer that crosses the approval threshold
-- auto-executes via execute_inventory_transfer() the moment the Owner
-- approves it, instead of silently sitting there with no executor
-- configured.
update public.business_rules
set rules = jsonb_set(
  coalesce(rules, '{}'::jsonb),
  '{types}',
  coalesce(rules->'types', '{}'::jsonb) || jsonb_build_object(
    'inventory_transfer', jsonb_build_object(
      'label', 'Inventory Transfer', 'roles_allowed_to_submit', jsonb_build_array('admin','manager'), 'auto_execute', true)
  ),
  true
)
where category = 'approvals'
  and not (rules->'types' ? 'inventory_transfer');


-- ───────────────────────────────────────────────────────────────────────
-- 6. execute_inventory_transfer() — the transactional core of Part 3
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.execute_inventory_transfer(p_transfer_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_t        public.inventory_transfers%rowtype;
  v_is_staff boolean;
  v_from_stock integer;
begin
  -- Same reasoning as Part 1's execute_branch_approval_request(): this
  -- runs SECURITY DEFINER, so the permission check has to be real and
  -- inside the function, not just a comment.
  select (e.is_owner = true or e.role in ('admin','manager')) into v_is_staff
    from public.employees e where e.user_id = auth.uid();
  if v_is_staff is not true then
    raise exception 'Only Owner, Admin, or Manager may execute inventory transfers';
  end if;

  select * into v_t from public.inventory_transfers where id = p_transfer_id for update;
  if not found then
    raise exception 'Transfer % not found', p_transfer_id;
  end if;
  if v_t.status not in ('pending', 'approved') then
    raise exception 'Transfer % is not in a executable state (status=%)', p_transfer_id, v_t.status;
  end if;
  if v_t.requires_approval and v_t.status <> 'approved' then
    raise exception 'Transfer % requires approval before it can execute', p_transfer_id;
  end if;

  -- Deduct from source (main `inventory` if from_branch_id is null, else branch_inventory)
  if v_t.from_branch_id is null then
    select stock into v_from_stock from public.inventory where product_id = v_t.product_id for update;
    if v_from_stock is null or v_from_stock < v_t.quantity then
      raise exception 'Insufficient main stock for product % (have %, need %)', v_t.product_id, coalesce(v_from_stock, 0), v_t.quantity;
    end if;
    update public.inventory set stock = stock - v_t.quantity, updated_at = now() where product_id = v_t.product_id;
  else
    select stock into v_from_stock from public.branch_inventory where branch_id = v_t.from_branch_id and product_id = v_t.product_id for update;
    if v_from_stock is null or v_from_stock < v_t.quantity then
      raise exception 'Insufficient branch stock for product % at branch % (have %, need %)', v_t.product_id, v_t.from_branch_id, coalesce(v_from_stock, 0), v_t.quantity;
    end if;
    update public.branch_inventory set stock = stock - v_t.quantity where branch_id = v_t.from_branch_id and product_id = v_t.product_id;
  end if;

  -- Add to destination
  if v_t.to_branch_id is null then
    update public.inventory set stock = stock + v_t.quantity, updated_at = now() where product_id = v_t.product_id;
  else
    insert into public.branch_inventory (branch_id, product_id, stock)
      values (v_t.to_branch_id, v_t.product_id, v_t.quantity)
      on conflict (branch_id, product_id) do update set stock = public.branch_inventory.stock + excluded.stock;
  end if;

  update public.inventory_transfers set status = 'completed', completed_at = now() where id = p_transfer_id;
end;
$$;

comment on function public.execute_inventory_transfer(bigint) is
  'Phase 7.0 Part 3. One transaction: deduct source, credit destination, mark the transfer completed. Raises (rolling back everything) on insufficient stock, wrong status, or missing approval. Called from admin.html''s transferInventory() via db.rpc().';

revoke all on function public.execute_inventory_transfer(bigint) from public, anon, authenticated;
grant execute on function public.execute_inventory_transfer(bigint) to authenticated;
