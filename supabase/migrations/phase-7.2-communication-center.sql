-- ═══════════════════════════════════════════════════════════════════════
-- Swahili Treats — Phase 7.2 Migration
-- Enterprise Communication Center
-- ═══════════════════════════════════════════════════════════════════════
--
-- HOW TO RUN THIS
-- Paste this whole file into the Supabase SQL Editor and run it once,
-- after every prior migration (this reads employees, branches,
-- announcements, notifications, customer_notifications,
-- branch_announcements — all already live). Additive only: nothing
-- existing is dropped, renamed, or has its meaning changed.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT ALREADY EXISTS (read this first — this is the "analyze before
-- building" step Phase 7.2 asks for)
-- ───────────────────────────────────────────────────────────────────────
-- Four separate, working communication paths already live in this
-- project, each built for one specific job:
--
--   1. `announcements` — id/title/message/active only. Read by
--      products.html's public ordering page (`.eq("active", true)`).
--      This is the CUSTOMER-facing banner feed. No targeting, no
--      priority, no scheduling, no audience beyond "everyone ordering".
--
--   2. `notifications` — employee_id/title/message/is_read. The STAFF
--      inbox: approval decisions (Part 7 Approval Center), branch
--      transfer notices, performance notices, low-stock alerts, etc.
--      all insert here today. No category, no pin, no archive.
--
--   3. `customer_notifications` — phone/notif_type/title/message/
--      channel_prepared/is_read. Loyalty & Rewards' customer-facing
--      inbox (reward issued, coupon available, VIP level up...).
--      channel_prepared already carries the "which channel would this
--      go out on" seam Part 10 of this phase asks for — reused as-is.
--
--   4. `branch_announcements` — title/message/priority/target_type
--      (single/multiple/all)/target_branch_ids/expires_at/created_by.
--      Built in Phase 7.0 for Branch Management's "notify a branch"
--      need. This is already 80% of what Part 3 (Broadcast Center)
--      and Part 9 (Branch Communication) ask for — it just can't
--      target roles or individual employees yet, and has no
--      scheduling or read-tracking.
--
-- Phase 7.2's job is NOT to replace these four — each is load-bearing
-- in a working screen — it's to (a) extend the two that are missing
-- fields the brief explicitly asks for, (b) add the handful of new,
-- genuinely new concepts (templates, scheduling, read receipts), and
-- (c) give the four of them one shared read-only "front door" (a view)
-- so a single Communication Center screen can list, search, and count
-- across all of them without four separate re-implementations of the
-- same table scan.
--
-- ───────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION ADDS
-- ───────────────────────────────────────────────────────────────────────
--   1. announcements: + priority, target_type, target_branch_ids,
--      target_roles, starts_at, expires_at, status, scheduled_for,
--      template_id, created_by, archived_at. Turns the customer banner
--      feed into the full Part 2 Announcement Management module
--      (company/branch/role/customer targeting, priority, schedule,
--      archive) without touching the one query products.html already
--      makes against it.
--   2. branch_announcements: + target_roles, target_employee_ids,
--      status, scheduled_for, template_id, sent_at. Completes it into
--      the Part 3 Broadcast Center / Part 9 Branch Communication
--      engine — same table Phase 7.0 already built and every existing
--      query against it keeps working (new columns are nullable/
--      defaulted).
--   3. notifications: + category, is_pinned, archived_at. Part 8's
--      "group by category / pin / archive" on the existing staff inbox.
--   4. message_templates — new. Part 4. Reusable title/message text
--      with {{placeholder}} tokens; category tags which module it's
--      for (order/reward/employee/branch/system/announcement).
--   5. scheduled_messages — new. Part 5. One row per message queued
--      for the future, regardless of which of the four tables above
--      it will eventually become. dispatch_scheduled_message() (below)
--      is the function that turns a due row into a real announcement /
--      branch_announcement / notification / customer_notification row,
--      the same execute_*() pattern Phase 7.0 already established for
--      approvals and inventory transfers.
--   6. message_read_receipts — new. Part 7. Generic per-recipient
--      delivered/read tracking for the two broadcast-style tables
--      (announcements, branch_announcements) that don't have a natural
--      one-row-per-recipient shape the way notifications/
--      customer_notifications already do (those two keep using their
--      own is_read column — no receipt rows needed there).
--   7. v_communication_history — new. Part 1 + Part 6. A read-only
--      UNION ALL view normalizing all five sources (announcements,
--      branch_announcements, notifications, customer_notifications,
--      scheduled_messages) into one shape the Communication Center's
--      dashboard totals, search, and Message History list all query
--      against. Nothing writes to this view — every INSERT still goes
--      to the underlying table it always did.
--   8. dispatch_scheduled_message(p_id) — new function. Executes one
--      due scheduled_messages row.
--
-- No RLS policy changes on the four existing tables (their trust model
-- doesn't change). New tables get the same "open to anon+authenticated,
-- enforced by the app's Permission Engine" policy the rest of this
-- project already uses (see customer_notifications' migration for the
-- precedent) — this app has no per-row Postgres-level auth model today,
-- so a stricter policy here would be inconsistent with every other
-- table, not more secure. dispatch_scheduled_message() is
-- SECURITY DEFINER with its own role check, matching
-- execute_inventory_transfer()/execute_branch_approval_request().
-- ═══════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────
-- 1. announcements — Part 2 Announcement Management
-- ───────────────────────────────────────────────────────────────────────
alter table public.announcements
  add column if not exists priority         text not null default 'normal'
    check (priority in ('low','normal','high','critical')),
  add column if not exists target_type       text not null default 'customers'
    check (target_type in ('company','branches','owners','admins','managers','employees','customers')),
  add column if not exists target_branch_ids bigint[] not null default '{}',
  add column if not exists target_roles      text[] not null default '{}',
  add column if not exists starts_at         timestamptz,
  add column if not exists expires_at        timestamptz,
  add column if not exists status            text not null default 'sent'
    check (status in ('draft','scheduled','sent','archived')),
  add column if not exists scheduled_for     timestamptz,
  add column if not exists template_id       bigint,
  add column if not exists created_by        text,
  add column if not exists archived_at       timestamptz;

comment on column public.announcements.target_type is
  'Phase 7.2. Default ''customers'' preserves every existing row''s real meaning (products.html''s public banner feed) — nothing already in this table gets re-targeted by this migration.';

-- products.html filters `.eq("active", true)` only — for that page to
-- keep showing exactly what it used to, "active" customer announcements
-- must also mean target_type = 'customers'. This index supports both
-- the old query and the new Communication Center filter.
create index if not exists announcements_target_type_idx on public.announcements (target_type);
create index if not exists announcements_status_idx       on public.announcements (status);

-- ───────────────────────────────────────────────────────────────────────
-- 2. branch_announcements — Part 3 Broadcast Center / Part 9 Branch
--    Communication
-- ───────────────────────────────────────────────────────────────────────
alter table public.branch_announcements
  add column if not exists target_roles      text[] not null default '{}',
  add column if not exists target_employee_ids bigint[] not null default '{}',
  add column if not exists status            text not null default 'sent'
    check (status in ('draft','scheduled','sending','sent','cancelled','failed')),
  add column if not exists scheduled_for     timestamptz,
  add column if not exists template_id       bigint,
  add column if not exists sent_at           timestamptz not null default now();

comment on table public.branch_announcements is
  'Phase 7.0''s branch broadcast table, extended in Phase 7.2 to also target specific roles or specific employees (target_type gains no new values here on purpose — target_roles/target_employee_ids are additive filters read alongside the existing single/multiple/all + target_branch_ids, exactly like Part 3''s "Owner may broadcast to Entire Organization / Selected Branches / Selected Roles / Selected Employees" list).';

create index if not exists branch_announcements_status_idx on public.branch_announcements (status);

-- ───────────────────────────────────────────────────────────────────────
-- 3. notifications — Part 8 Notification Center improvements
-- ───────────────────────────────────────────────────────────────────────
alter table public.notifications
  add column if not exists category    text not null default 'general'
    check (category in ('general','order','approval','branch','inventory','performance','system','announcement')),
  add column if not exists is_pinned   boolean not null default false,
  add column if not exists archived_at timestamptz;

create index if not exists notifications_category_idx on public.notifications (category);
create index if not exists notifications_pinned_idx    on public.notifications (is_pinned) where is_pinned = true;

-- ───────────────────────────────────────────────────────────────────────
-- 4. message_templates — Part 4
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.message_templates (
  id               bigint generated always as identity primary key,
  name             text not null,
  category         text not null
    check (category in ('order','reward','employee','branch','inventory','system','announcement','approval')),
  title_template   text not null,
  message_template text not null,
  placeholders     text[] not null default '{}',
  active           boolean not null default true,
  created_by       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on table public.message_templates is
  'Phase 7.2 Part 4. title_template/message_template hold literal {{placeholder}} tokens (e.g. "Hi {{customer_name}}, your order {{order_number}} is on its way"); placeholders lists the token names the UI should render as fill-in fields. Rendering (token substitution) happens client-side in renderTemplate() — this table only stores the pattern.';

alter table public.announcements         add constraint announcements_template_id_fkey
  foreign key (template_id) references public.message_templates(id) not valid;
alter table public.branch_announcements  add constraint branch_announcements_template_id_fkey
  foreign key (template_id) references public.message_templates(id) not valid;

-- Seed the templates the brief names explicitly (Part 4), so the
-- Communication Center isn't empty on first load. Safe to re-run.
insert into public.message_templates (name, category, title_template, message_template, placeholders)
select * from (values
  ('Order Accepted',      'order',        'Your order is confirmed!',        'Hi {{customer_name}}, your order {{order_number}} has been accepted and is being prepared. 🍬', array['customer_name','order_number']),
  ('Order Delivered',     'order',        'Order delivered ✅',              'Hi {{customer_name}}, your order {{order_number}} has been delivered. Enjoy!', array['customer_name','order_number']),
  ('Reward Earned',       'reward',       'You just earned a reward! 🎁',    'Hi {{customer_name}}, you''ve earned a new reward on your last order. Check your Loyalty tab!', array['customer_name']),
  ('Coupon Issued',       'reward',       'A coupon is waiting for you 🏷️',  'Hi {{customer_name}}, a new coupon has been added to your account.', array['customer_name']),
  ('Employee Promotion',  'employee',     'Congratulations, {{employee_name}}!', '{{employee_name}} has been promoted. Please welcome them in their new role.', array['employee_name']),
  ('Branch Approved',     'branch',       'Branch approved: {{branch_name}}', 'The request to open {{branch_name}} has been approved.', array['branch_name']),
  ('Inventory Alert',     'inventory',    'Inventory alert',                 'Stock levels for one or more products need attention at {{branch_name}}.', array['branch_name']),
  ('Low Stock',           'inventory',    'Low stock warning ⚠️',            '{{product_name}} is running low at {{branch_name}}.', array['product_name','branch_name']),
  ('Announcement',        'announcement', '{{title}}',                       '{{message}}', array['title','message']),
  ('System Maintenance',  'system',       'Scheduled maintenance',           'Swahili Treats will be briefly unavailable for maintenance. We''ll be back shortly.', array[]::text[]),
  ('Approval Request',    'approval',     'Approval needed',                 'A new {{request_type}} request needs your review.', array['request_type'])
) as seed(name, category, title_template, message_template, placeholders)
where not exists (select 1 from public.message_templates where message_templates.name = seed.name);

-- ───────────────────────────────────────────────────────────────────────
-- 5. scheduled_messages — Part 5
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.scheduled_messages (
  id              bigint generated always as identity primary key,
  message_type    text not null
    check (message_type in ('announcement','branch_broadcast','employee_notification','customer_notification')),
  template_id     bigint references public.message_templates(id),
  title           text not null,
  message         text not null,
  target          jsonb not null default '{}',   -- shape mirrors whichever table it targets, e.g. {"target_type":"branches","target_branch_ids":[3,4]}
  priority        text not null default 'normal' check (priority in ('low','normal','high','critical')),
  status          text not null default 'draft'
    check (status in ('draft','scheduled','sending','sent','cancelled','failed')),
  scheduled_for   timestamptz,
  sent_at         timestamptz,
  failed_reason   text,
  result_table    text,     -- which table dispatch_scheduled_message() inserted into
  result_id       bigint,   -- the id of the row it created there
  created_by      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table public.scheduled_messages is
  'Phase 7.2 Part 5. One row per queued future message, independent of which of the four delivery tables it becomes. dispatch_scheduled_message(id) executes a due row: inserts the real announcement/branch_announcement/notification(s)/customer_notification(s) row(s), records result_table/result_id, and marks this row sent. Editable freely while status=''draft''/''scheduled''; once ''sending''/''sent'' it is history, matching Part 5''s "allow editing before sending" requirement.';

create index if not exists scheduled_messages_due_idx on public.scheduled_messages (status, scheduled_for);

create or replace function public.set_scheduled_messages_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_scheduled_messages_updated_at on public.scheduled_messages;
create trigger trg_scheduled_messages_updated_at
  before update on public.scheduled_messages
  for each row execute function public.set_scheduled_messages_updated_at();

-- ───────────────────────────────────────────────────────────────────────
-- 6. message_read_receipts — Part 7
-- ───────────────────────────────────────────────────────────────────────
create table if not exists public.message_read_receipts (
  id             bigint generated always as identity primary key,
  message_type   text not null check (message_type in ('announcement','branch_broadcast')),
  message_id     bigint not null,
  recipient_type text not null check (recipient_type in ('employee','customer')),
  recipient_id   text not null,   -- employees.id as text, or a phone number
  status         text not null default 'pending' check (status in ('pending','delivered','read')),
  delivered_at   timestamptz,
  read_at        timestamptz,
  created_at     timestamptz not null default now(),
  unique (message_type, message_id, recipient_type, recipient_id)
);

comment on table public.message_read_receipts is
  'Phase 7.2 Part 7. Only for the two broadcast-shaped tables (announcements, branch_announcements) which have no natural per-recipient row. notifications and customer_notifications already carry their own is_read column and do not need receipt rows.';

create index if not exists message_read_receipts_lookup_idx
  on public.message_read_receipts (message_type, message_id);

-- ───────────────────────────────────────────────────────────────────────
-- 7. v_communication_history — Part 1 dashboard + Part 6 Message History
-- ───────────────────────────────────────────────────────────────────────
create or replace view public.v_communication_history as
  select
    'announcement'::text                                   as message_type,
    a.id,
    a.title,
    a.message,
    a.priority,
    a.target_type,
    a.status,
    a.created_by                                            as sender,
    a.scheduled_for,
    a.created_at,
    a.created_at                                             as sent_at,
    null::boolean                                             as is_read
  from public.announcements a
  union all
  select
    'branch_broadcast',
    b.id,
    b.title,
    b.message,
    b.priority,
    b.target_type,
    b.status,
    b.created_by,
    b.scheduled_for,
    b.created_at,
    b.sent_at,
    null::boolean
  from public.branch_announcements b
  union all
  select
    'employee_notification',
    n.id,
    n.title,
    n.message,
    'normal',
    'employees',
    case when n.archived_at is not null then 'archived' else 'sent' end,
    null,
    null,
    n.created_at,
    n.created_at,
    n.is_read
  from public.notifications n
  union all
  select
    'customer_notification',
    c.id,
    c.title,
    c.message,
    'normal',
    'customers',
    'sent',
    null,
    null,
    c.created_at,
    c.created_at,
    c.is_read
  from public.customer_notifications c
  union all
  select
    'scheduled_' || s.message_type,
    s.id,
    s.title,
    s.message,
    s.priority,
    coalesce(s.target->>'target_type', s.message_type),
    s.status,
    s.created_by,
    s.scheduled_for,
    s.created_at,
    s.sent_at,
    null::boolean
  from public.scheduled_messages s
  where s.status in ('draft','scheduled','sending','failed','cancelled'); -- once sent, the dispatched row above already represents it

comment on view public.v_communication_history is
  'Phase 7.2. Read-only unified feed across all five communication sources for the Communication Center''s dashboard totals, search, and Message History list. Never insert here — insert into the underlying table (or scheduled_messages for future sends) as every existing screen already does.';

-- ───────────────────────────────────────────────────────────────────────
-- 8. dispatch_scheduled_message() — executes one due scheduled row
-- ───────────────────────────────────────────────────────────────────────
create or replace function public.dispatch_scheduled_message(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_s        public.scheduled_messages%rowtype;
  v_is_staff boolean;
  v_new_id   bigint;
begin
  -- Same pattern as execute_inventory_transfer()/execute_branch_approval_
  -- request(): SECURITY DEFINER means the permission check must live in
  -- here, not just in the calling JS.
  select (e.is_owner = true or e.role in ('admin','manager')) into v_is_staff
    from public.employees e where e.user_id = auth.uid();
  if v_is_staff is not true then
    raise exception 'Only Owner, Admin, or Manager may dispatch scheduled messages';
  end if;

  select * into v_s from public.scheduled_messages where id = p_id for update;
  if not found then
    raise exception 'Scheduled message % not found', p_id;
  end if;
  if v_s.status not in ('draft','scheduled') then
    raise exception 'Scheduled message % is not in a dispatchable state (status=%)', p_id, v_s.status;
  end if;

  if v_s.message_type = 'announcement' then
    insert into public.announcements (title, message, active, priority, target_type, target_branch_ids, target_roles, status, template_id, created_by)
      values (v_s.title, v_s.message, true, v_s.priority,
              coalesce(v_s.target->>'target_type', 'customers'),
              coalesce((select array_agg(x::bigint) from jsonb_array_elements_text(v_s.target->'target_branch_ids') x), '{}'),
              coalesce((select array_agg(x) from jsonb_array_elements_text(v_s.target->'target_roles') x), '{}'),
              'sent', v_s.template_id, v_s.created_by)
      returning id into v_new_id;

  elsif v_s.message_type = 'branch_broadcast' then
    insert into public.branch_announcements (title, message, priority, target_type, target_branch_ids, target_roles, target_employee_ids, status, template_id, created_by, sent_at)
      values (v_s.title, v_s.message, v_s.priority,
              coalesce(v_s.target->>'target_type', 'all'),
              coalesce((select array_agg(x::bigint) from jsonb_array_elements_text(v_s.target->'target_branch_ids') x), '{}'),
              coalesce((select array_agg(x) from jsonb_array_elements_text(v_s.target->'target_roles') x), '{}'),
              coalesce((select array_agg(x::bigint) from jsonb_array_elements_text(v_s.target->'target_employee_ids') x), '{}'),
              'sent', v_s.template_id, v_s.created_by, now())
      returning id into v_new_id;

  elsif v_s.message_type = 'employee_notification' then
    insert into public.notifications (employee_id, title, message, category)
      select (x->>'employee_id')::bigint, v_s.title, v_s.message, coalesce(v_s.target->>'category', 'general')
      from jsonb_array_elements(coalesce(v_s.target->'employee_ids', '[]'::jsonb)) x
      returning id into v_new_id; -- last inserted id when multiple; result_id records one representative row, full set is queryable by created_at+title

  elsif v_s.message_type = 'customer_notification' then
    insert into public.customer_notifications (phone, notif_type, title, message)
      select (x->>'phone')::text, coalesce(v_s.target->>'notif_type', 'promotion'), v_s.title, v_s.message
      from jsonb_array_elements(coalesce(v_s.target->'phones', '[]'::jsonb)) x
      returning id into v_new_id;

  else
    raise exception 'Unknown message_type %', v_s.message_type;
  end if;

  update public.scheduled_messages
    set status = 'sent', sent_at = now(), result_table = v_s.message_type, result_id = v_new_id
    where id = p_id;
exception when others then
  update public.scheduled_messages
    set status = 'failed', failed_reason = sqlerrm
    where id = p_id;
  raise;
end;
$$;

comment on function public.dispatch_scheduled_message(bigint) is
  'Phase 7.2 Part 5. Turns one due scheduled_messages row into a real row in whichever table its message_type points at, and records the result. Called from admin.html''s scheduler poll (checkDueScheduledMessages(), every 60s while the Communication Center or dashboard is open) via db.rpc() — there is no pg_cron in this project, so "the future" is enforced client-side by only calling this once scheduled_for has passed, exactly like every other time-gated action in this app.';

revoke all on function public.dispatch_scheduled_message(bigint) from public, anon, authenticated;
grant execute on function public.dispatch_scheduled_message(bigint) to authenticated;

-- ───────────────────────────────────────────────────────────────────────
-- 9. RLS for the new tables — same open/app-enforced model as the rest
--    of this project (see phase-6.6.1's customer_notifications policy)
-- ───────────────────────────────────────────────────────────────────────
alter table public.message_templates      enable row level security;
alter table public.scheduled_messages     enable row level security;
alter table public.message_read_receipts  enable row level security;

drop policy if exists "message_templates_open" on public.message_templates;
create policy "message_templates_open" on public.message_templates
  for all to anon, authenticated using (true) with check (true);

drop policy if exists "scheduled_messages_open" on public.scheduled_messages;
create policy "scheduled_messages_open" on public.scheduled_messages
  for all to anon, authenticated using (true) with check (true);

drop policy if exists "message_read_receipts_open" on public.message_read_receipts;
create policy "message_read_receipts_open" on public.message_read_receipts
  for all to anon, authenticated using (true) with check (true);
