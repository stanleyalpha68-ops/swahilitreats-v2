-- Phase 7.5.1B — Correct the employees RLS policy used by authentication.
-- The earlier policy queried public.employees from a policy on that same
-- table, which PostgreSQL can reject as recursive during the profile lookup.

create or replace function public.current_employee_id()
returns bigint language sql stable security definer set search_path = public as $$
  select id from public.employees where user_id = auth.uid() limit 1;
$$;
create or replace function public.current_employee_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.employees where user_id = auth.uid() limit 1;
$$;
create or replace function public.current_employee_is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(is_owner, false) from public.employees where user_id = auth.uid() limit 1;
$$;
grant execute on function public.current_employee_id() to authenticated;
grant execute on function public.current_employee_role() to authenticated;
grant execute on function public.current_employee_is_owner() to authenticated;

drop policy if exists "emp_staff_read" on public.employees;
create policy "emp_staff_read" on public.employees for select to authenticated
  using (public.current_employee_id() is not null);
drop policy if exists "emp_admin_write" on public.employees;
create policy "emp_admin_write" on public.employees for all to authenticated
  using (public.current_employee_is_owner() or public.current_employee_role() = 'admin')
  with check (public.current_employee_is_owner() or public.current_employee_role() = 'admin');
drop policy if exists "emp_self_update" on public.employees;
create policy "emp_self_update" on public.employees for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and role = public.current_employee_role()
              and is_owner = public.current_employee_is_owner());
