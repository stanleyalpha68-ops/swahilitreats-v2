-- ============================================================================
-- PHASE 7.4 — Enterprise Settings & Configuration Center
-- ============================================================================
-- ANALYSIS FINDINGS (read before running):
--
-- 1. SECURITY GAP — public.settings has NEVER had Row Level Security.
--    Every migration file in this project was grepped; none touches it.
--    That means the anon key can currently read AND write business_name,
--    WhatsApp numbers, and every notification toggle. products.html and
--    track.html do rely on anon SELECT (customer-facing WhatsApp button),
--    so read access must stay public — but write access has no gate at
--    all today. This migration closes that.
--
-- 2. DUPLICATE / SCATTERED CONFIGURATION — this app already has FOUR
--    separate places that are each, in effect, "settings":
--      - public.settings           → business_name, contact numbers, message
--                                     templates, notification toggles (Phase 1)
--      - public.business_rules     → loyalty/vip/coupons/rewards/branches/
--                                     approvals/notifications rule JSON
--                                     (Phase 6.2, already has its own tab)
--      - public.role_permissions   → the Permission Engine (Phase 6.3)
--      - public.branches (columns) → operating_hours, inventory_thresholds,
--                                     manager_permissions,
--                                     announcement_preferences, theme
--                                     (Phase 7.0, per-branch)
--      - public.message_templates  → Communication Center's reusable
--                                     templates (Phase 7.2)
--    None of these should be merged into one physical table — that would
--    mean rewriting Business Rules Center, Branch Management, the
--    Permission Engine and Communication Center (explicitly forbidden:
--    "Do NOT redesign completed functionality"). Instead, Part 1's
--    "centralized Settings Center" is built as a single navigation +
--    search surface over all of them: simple flat settings are edited
--    inline (still stored in public.settings, since it's already a
--    generic key/value table — no new columns needed), and anything that
--    already has a dedicated rich editor deep-links to that existing tab
--    instead of duplicating its UI.
--
-- 3. GENUINELY NEW CONFIGURATION — Business (address/currency/timezone/
--    tax/invoice), Appearance (logo/brand colors), Security (password
--    policy/session timeout/login attempts/audit retention), and Backup
--    (frequency preference, architecture-only) have no home anywhere in
--    the schema yet. These are added as new rows in the existing
--    public.settings table — zero schema changes to that table.
--
-- 4. CONFIGURATION HISTORY — Part 11 says reuse the Audit Trail. This app
--    already has a shared createAuditRecord() JS helper writing to
--    public.audit_log. No new history table is created; the Settings
--    Center calls that same helper on every save.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Close the RLS gap on public.settings
-- ----------------------------------------------------------------------------
-- Public read stays open — products.html / track.html depend on it for
-- customer-facing WhatsApp contact info. Writes become Owner/Admin only,
-- the same posture as TAB_FINANCIAL/TAB_EXECUTIVE (Manager gets no settings
-- surface today, matching every other "if permitted" gap already in RBAC).
alter table public.settings enable row level security;

drop policy if exists "settings_public_read" on public.settings;
create policy "settings_public_read"
  on public.settings
  for select
  to anon, authenticated
  using (true);

drop policy if exists "settings_staff_write" on public.settings;
create policy "settings_staff_write"
  on public.settings
  for all
  to authenticated
  using (
    exists (
      select 1 from public.employees e
      where e.user_id = auth.uid()
        and (e.is_owner = true or e.role = 'admin')
    )
  )
  with check (
    exists (
      select 1 from public.employees e
      where e.user_id = auth.uid()
        and (e.is_owner = true or e.role = 'admin')
    )
  );


-- ----------------------------------------------------------------------------
-- 2. Favorites / Quick Access (Part 12)
-- ----------------------------------------------------------------------------
-- Small, additive, per-employee — doesn't touch any existing table.
create table if not exists public.settings_favorites (
  id bigint generated always as identity primary key,
  employee_id bigint not null references public.employees(id) on delete cascade,
  setting_key text not null,
  created_at timestamp with time zone not null default now(),
  unique (employee_id, setting_key)
);

alter table public.settings_favorites enable row level security;

drop policy if exists "settings_favorites_own" on public.settings_favorites;
create policy "settings_favorites_own"
  on public.settings_favorites
  for all
  to authenticated
  using (
    exists (select 1 from public.employees e where e.user_id = auth.uid() and e.id = settings_favorites.employee_id)
  )
  with check (
    exists (select 1 from public.employees e where e.user_id = auth.uid() and e.id = settings_favorites.employee_id)
  );


-- ----------------------------------------------------------------------------
-- 3. Seed genuinely-new settings (Business / Appearance / Security / Backup)
-- ----------------------------------------------------------------------------
-- Stored the same way every other setting already is — a flat key with a
-- text value (structured values like working_days/business_hours are
-- stored as a JSON string, same convention products.html already parses
-- for other keys). Uses on-conflict-do-nothing so re-running this
-- migration never clobbers values an Owner has already changed.
insert into public.settings (setting_key, setting_value) values
  -- Business (Part 2)
  ('business_address',        ''),
  ('business_currency',       'KES'),
  ('business_timezone',       'Africa/Nairobi'),
  ('business_date_format',    'DD/MM/YYYY'),
  ('business_working_days',   '["mon","tue","wed","thu","fri","sat"]'),
  ('business_hours',          '{"open":"08:00","close":"20:00"}'),
  ('tax_rate_percent',        '0'),
  ('tax_inclusive',           'true'),
  ('invoice_prefix',          'ST-'),
  ('invoice_footer_note',     'Asante kwa kutuamini! Thank you for your order.'),

  -- Appearance (Part 8) — logo_url is populated via the Media Center browser
  ('business_logo_url',       ''),
  ('brand_primary_color',     '#ffb703'),
  ('brand_secondary_color',   '#22223b'),
  ('dashboard_density',       'comfortable'),

  -- Security (Part 9) — architecture only; nothing in Auth enforces these
  -- yet, they exist so the Owner has one place to define policy while the
  -- enforcement work is scoped separately.
  ('password_min_length',              '8'),
  ('login_max_attempts',                '5'),
  ('session_timeout_minutes',           '60'),
  ('audit_log_retention_days',          '365'),

  -- Backup (Part 10) — preference only. Operations Center already has a
  -- client-side backup export (Phase 6.10); this just records the Owner's
  -- stated frequency intent. No scheduler, no external provider.
  ('backup_frequency_preference',       'manual'),
  ('backup_last_export_at',             '')
on conflict (setting_key) do nothing;


-- ----------------------------------------------------------------------------
-- 4. Realtime (Part 13)
-- ----------------------------------------------------------------------------
alter publication supabase_realtime add table public.settings;
alter publication supabase_realtime add table public.settings_favorites;

-- ============================================================================
-- END PHASE 7.4 MIGRATION
-- ============================================================================
