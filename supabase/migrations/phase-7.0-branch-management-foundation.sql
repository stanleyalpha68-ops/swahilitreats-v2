-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 7.0 (Part 1/4) Migration
-- Enterprise Branch Management Foundation
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once.
-- Additive only — nothing existing is altered destructively, nothing
-- dropped. One existing table (`branches`) gets new columns; one
-- existing table (`employees`) gets one new nullable column.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ALREADY EXISTS (checked before writing this — read this first)
-- ───────────────────────────────────────────────────────────────────────
-- A `branches` table already exists — Phase 6.8 created it as
-- architecture-only for Branch Analytics, with an explicit note in its
-- own comment that building out real Branch Management "is not part of
-- this phase." That phase has now arrived. Rather than create a second
-- table, this migration ALTERs the existing one, so Phase 6.8's Branch
-- Analytics screen (which already queries `branches` and falls back to
-- `orders.campus` when it's empty) starts working against real data the
-- moment rows exist, with zero changes to that screen's own code.
--
-- The Approval Center, Workflow Engine, and Audit Trail (approval_requests,
-- approval_history, approval_chain_progress, workflow_definitions,
-- audit_log) are all already fully built and generic — request_type is
-- free text and new_values/original_values are jsonb, so branch requests
-- need ZERO new tables for the approval side. Part 3's "submitting this
-- form should create an Approval Request only" falls directly out of the
-- existing schema — a branch request is just an approval_requests row
-- with request_type in ('new_branch','branch_modification',
-- 'branch_relocation','branch_closure','branch_reopening') and the
-- proposed fields in new_values.
--
-- Per this phase's own explicit instruction, Branch Inventory
-- Management, Branch Employee Management (as a full module), Branch
-- Analytics, and Branch Financials are NOT built here — see the
-- application code's own comments on exactly where that line is drawn
-- for the Initialization Wizard's Employees/Inventory steps.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION ADDS
-- ───────────────────────────────────────────────────────────────────────
--   1. branches — new columns for everything Part 2 asks a branch to
--      have that the Phase 6.8 version didn't (branch_code was already
--      `code`; adding city, region, phone, email, manager, a real
--      status lifecycle, opening_date, delivery radius, operating
--      hours, ordering/delivery toggles, notes, GPS placeholders, and a
--      link back to the approval request that created it).
--      `active` (boolean) is KEPT and now trigger-maintained from
--      `status`, so Phase 6.8's Branch Analytics query
--      (`.eq("active", true)`) keeps working unmodified — this migration
--      adds a richer lifecycle without breaking the simpler one that
--      already shipped.
--   2. employees.branch_id — one nullable FK, foundation-level only
--      (lets the Initialization Wizard assign a manager/employees to a
--      new branch). This is NOT "Branch Employee Management" — no
--      transfer history, no per-branch roster screen, no per-branch
--      scheduling. Just the column a wizard needs to say "this person
--      is here now," same way `assigned_employee_id` on `orders`
--      already works.
--   3. execute_branch_approval_request(p_approval_id) — a real Postgres
--      function, not sequential JS calls, so Part 4's "execution must be
--      transactional" is actually true: branch creation/update and the
--      approval_requests execution-status flip happen inside one
--      database transaction — if either half fails, both roll back.
--      Notifications and audit-trail writes happen from the application
--      after this function returns successfully, the same established
--      pattern as every other module in this app (see Phase 6.6's own
--      note on why audit writes are explicit app calls, not triggers).
--   4. Seeds the 5 branch request types into business_rules('approvals')
--      with auto_execute=true, merging into whatever config already
--      exists rather than overwriting it — otherwise Part 4's automatic
--      creation wouldn't fire until an Owner manually configured 5
--      obscure type keys in the Business Rules Center first.
--
-- Indexes for the new status/manager-lookup columns are inline within
-- sections 1 and 2 above, not a separate section.
-- ═══════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────
-- 1. branches — extend the Phase 6.8 table
-- ───────────────────────────────────────────────────────────────────────
alter table public.branches add column if not exists city text;
alter table public.branches add column if not exists region text;
alter table public.branches add column if not exists phone text;
alter table public.branches add column if not exists email text;
alter table public.branches add column if not exists manager_employee_id bigint references public.employees (id) on delete set null;
alter table public.branches add column if not exists status text not null default 'under_setup' check (status = any (array[
  'pending','under_setup','opening_soon','active','temporarily_closed','closed','archived'
]));
alter table public.branches add column if not exists opening_date date;
alter table public.branches add column if not exists delivery_radius_km numeric;
alter table public.branches add column if not exists operating_hours jsonb not null default '{}'::jsonb;  -- { "mon": {"open":"08:00","close":"20:00"}, ..., "closed_days": ["sun"] }
alter table public.branches add column if not exists delivery_enabled boolean not null default false;
alter table public.branches add column if not exists ordering_enabled boolean not null default false;
alter table public.branches add column if not exists notes text;
alter table public.branches add column if not exists gps_lat numeric;    -- Part 2 "prepare architecture for GPS coordinates" — nullable, unused until a map view exists
alter table public.branches add column if not exists gps_lng numeric;
alter table public.branches add column if not exists initial_inventory_plan jsonb;  -- records the Wizard's chosen approach ('transfer'|'empty'|'starter' + notes) — see the header on why this doesn't touch `inventory` itself yet
alter table public.branches add column if not exists approval_id bigint references public.approval_requests (id) on delete set null;
alter table public.branches add column if not exists created_by text;

comment on column public.branches.status is
  'Real lifecycle (Part 2/5): pending (awaiting wizard config) → under_setup / opening_soon → active, or temporarily_closed / closed / archived. The boolean `active` column from Phase 6.8 is kept in sync automatically (see trg_branches_sync_active) so existing Branch Analytics code keeps working unmodified.';
comment on column public.branches.initial_inventory_plan is
  'Records the Owner''s chosen approach from the Initialization Wizard (Part 5) — does not move real stock. Real per-branch inventory tracking is Phase 7.0 Part 2, explicitly out of scope for this migration.';

create index if not exists branches_status_idx on public.branches (status);
create index if not exists branches_manager_idx on public.branches (manager_employee_id);

-- Keep the old `active` boolean in sync with the new `status` lifecycle,
-- so nothing built in Phase 6.8 needs to change.
create or replace function public.sync_branches_active()
returns trigger language plpgsql as $$
begin
  new.active := (new.status in ('active', 'opening_soon'));
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_branches_sync_active on public.branches;
create trigger trg_branches_sync_active
  before insert or update on public.branches
  for each row execute function public.sync_branches_active();


-- ───────────────────────────────────────────────────────────────────────
-- 2. employees.branch_id — foundation-level only (see header)
-- ───────────────────────────────────────────────────────────────────────
alter table public.employees add column if not exists branch_id bigint references public.branches (id) on delete set null;
comment on column public.employees.branch_id is
  'Phase 7.0 Part 1 foundation column — which branch this employee is currently at, settable from the Branch Initialization Wizard. Deliberately minimal: no transfer history, no per-branch roster screen. Full Branch Employee Management is Phase 7.0 Part 2/3.';

create index if not exists employees_branch_id_idx on public.employees (branch_id);


-- ───────────────────────────────────────────────────────────────────────
-- 3. execute_branch_approval_request() — the transactional core of
--    Part 4's "Automatic Branch Creation"
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.execute_branch_approval_request(p_approval_id bigint)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req      public.approval_requests%rowtype;
  v_branch_id bigint;
  v_nv       jsonb;
  v_is_owner boolean;
begin
  -- SECURITY DEFINER means this function runs with elevated privileges —
  -- an explicit check here is not optional. Without it, any authenticated
  -- employee granted EXECUTE could create/modify branches directly,
  -- bypassing the Approval Center this whole part of the brief exists to
  -- enforce ("Branch creation must NEVER happen directly from the Admin
  -- Workspace").
  select e.is_owner into v_is_owner from public.employees e where e.user_id = auth.uid();
  if v_is_owner is not true then
    raise exception 'Only the Owner may execute branch approval requests';
  end if;

  select * into v_req from public.approval_requests where id = p_approval_id for update;
  if not found then
    raise exception 'Approval request % not found', p_approval_id;
  end if;
  if v_req.status <> 'approved' then
    raise exception 'Approval request % is not approved (status=%)', p_approval_id, v_req.status;
  end if;
  if v_req.execution_status = 'executed' then
    raise exception 'Approval request % was already executed', p_approval_id;
  end if;

  v_nv := coalesce(v_req.new_values, '{}'::jsonb);

  if v_req.request_type = 'new_branch' then
    insert into public.branches (
      name, code, campus, address, city, region, phone, email,
      manager_employee_id, status, opening_date, delivery_radius_km,
      operating_hours, notes, created_by, approval_id
    ) values (
      v_nv->>'name',
      v_nv->>'code',
      v_nv->>'campus',
      v_nv->>'address',
      v_nv->>'city',
      v_nv->>'region',
      v_nv->>'phone',
      v_nv->>'email',
      nullif(v_nv->>'manager_employee_id','')::bigint,
      coalesce(v_nv->>'status', 'under_setup'),
      nullif(v_nv->>'opening_date','')::date,
      nullif(v_nv->>'delivery_radius_km','')::numeric,
      coalesce(v_nv->'operating_hours', '{}'::jsonb),
      v_nv->>'notes',
      v_req.requester_id::text,
      v_req.id
    )
    returning id into v_branch_id;

  elsif v_req.request_type in ('branch_modification', 'branch_relocation') then
    v_branch_id := nullif(v_nv->>'branch_id','')::bigint;
    if v_branch_id is null then
      raise exception 'branch_modification/relocation request % has no target branch_id in new_values', p_approval_id;
    end if;
    update public.branches set
      name                = coalesce(v_nv->>'name', name),
      address             = coalesce(v_nv->>'address', address),
      city                = coalesce(v_nv->>'city', city),
      region              = coalesce(v_nv->>'region', region),
      phone               = coalesce(v_nv->>'phone', phone),
      email               = coalesce(v_nv->>'email', email),
      delivery_radius_km  = coalesce(nullif(v_nv->>'delivery_radius_km','')::numeric, delivery_radius_km),
      operating_hours     = coalesce(v_nv->'operating_hours', operating_hours),
      notes               = coalesce(v_nv->>'notes', notes)
    where id = v_branch_id;

  elsif v_req.request_type = 'branch_closure' then
    v_branch_id := nullif(v_nv->>'branch_id','')::bigint;
    if v_branch_id is null then
      raise exception 'branch_closure request % has no target branch_id in new_values', p_approval_id;
    end if;
    update public.branches set status = 'closed', ordering_enabled = false, delivery_enabled = false where id = v_branch_id;

  elsif v_req.request_type = 'branch_reopening' then
    v_branch_id := nullif(v_nv->>'branch_id','')::bigint;
    if v_branch_id is null then
      raise exception 'branch_reopening request % has no target branch_id in new_values', p_approval_id;
    end if;
    update public.branches set status = 'opening_soon' where id = v_branch_id;

  else
    raise exception 'Unknown branch request_type: %', v_req.request_type;
  end if;

  update public.approval_requests
    set execution_status = 'executed', executed_at = now()
    where id = p_approval_id;

  return v_branch_id;
end;
$$;

-- ───────────────────────────────────────────────────────────────────────
-- 4. Seed the 5 branch request types into business_rules('approvals')
-- ───────────────────────────────────────────────────────────────────────
-- The Approval Center's request "types" are entirely Owner-configurable
-- (business_rules.category='approvals'.rules.types — never hardcoded,
-- per admin.html's own comment on ensureApprovalRulesConfig()). Without
-- an entry here, a branch request would still create an approval_requests
-- row fine, but auto_execute would default to false and nothing would
-- automatically create the branch on approval — Part 4 asks for
-- automatic creation, so these 5 types are seeded with auto_execute=true
-- out of the box. This MERGES into whatever 'approvals' config already
-- exists (creating the row only if it's missing entirely) rather than
-- overwriting any types an Owner has already configured.
insert into public.business_rules (category, label, icon, sort_order, rules)
values ('approvals', 'Approval Center', '✅', 40, jsonb_build_object('types', '{}'::jsonb))
on conflict (category) do nothing;

update public.business_rules
set rules = jsonb_set(
  coalesce(rules, '{}'::jsonb),
  '{types}',
  coalesce(rules->'types', '{}'::jsonb) || jsonb_build_object(
    'new_branch', jsonb_build_object(
      'label', 'New Branch', 'roles_allowed_to_submit', jsonb_build_array('admin'), 'auto_execute', true),
    'branch_modification', jsonb_build_object(
      'label', 'Branch Modification', 'roles_allowed_to_submit', jsonb_build_array('admin'), 'auto_execute', true),
    'branch_relocation', jsonb_build_object(
      'label', 'Branch Relocation', 'roles_allowed_to_submit', jsonb_build_array('admin'), 'auto_execute', true),
    'branch_closure', jsonb_build_object(
      'label', 'Branch Closure', 'roles_allowed_to_submit', jsonb_build_array('admin'), 'auto_execute', true),
    'branch_reopening', jsonb_build_object(
      'label', 'Branch Reopening', 'roles_allowed_to_submit', jsonb_build_array('admin'), 'auto_execute', true)
  ),
  true
)
where category = 'approvals'
  and not (rules->'types' ? 'new_branch');  -- only seed once — never clobber an Owner's own edits to these types on a re-run

comment on function public.execute_branch_approval_request(bigint) is
  'Phase 7.0 Part 1/4. Single transaction: reads the approved request, creates/updates the branch, flips execution_status to executed. Raises (rolling back everything) if the request is missing, not approved, or already executed. Called from admin.html''s approveBranchRequest() via db.rpc(); audit/notification writes happen afterward from the application, same pattern as every other module.';

-- SECURITY DEFINER above runs with the function owner's privileges so it
-- can write both approval_requests and branches in one statement even
-- though a caller's RLS might only directly permit one of them. EXECUTE
-- is granted broadly to `authenticated` because Postgres has no
-- "authenticated but only if is_owner" grant target — the actual
-- enforcement is the explicit is_owner check inside the function body
-- above, which raises (and rolls back) for anyone else.
revoke all on function public.execute_branch_approval_request(bigint) from public, anon, authenticated;
grant execute on function public.execute_branch_approval_request(bigint) to authenticated;
