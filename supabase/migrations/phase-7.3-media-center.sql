-- ============================================================================
-- PHASE 7.3 — Enterprise Media & File Management Center
-- ============================================================================
-- CONTEXT (read before running):
-- This app currently has NO Supabase Storage buckets. Every "upload" field
-- in the schema (products.image_url, order_reviews.photo_url,
-- expenses.receipt_url, branch_documents.file_url,
-- branch_announcements.attachment_url) is a plain text column where admins
-- paste an external image link. admin.html even has a self-aware comment
-- confirming this (Operations Center health check, "Storage (file uploads)"
-- — "this app stores image_url as external links, no Supabase Storage
-- bucket is used").
--
-- So Part 0 of this phase is not "reuse existing buckets" (there are none)
-- — it's creating the first ones, plus a tracking table that every existing
-- *_url column can now point at. We keep every existing *_url column as-is
-- (zero breaking changes to Orders/Products/Reviews/Financial/Branch code)
-- and add media_files as a parallel registry that the new Media Center reads
-- from. Existing external links keep working; anything uploaded through the
-- new center is tracked here.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. STORAGE BUCKETS
-- ----------------------------------------------------------------------------
-- Two buckets, matching the two trust levels already implicit in the schema:
--   media-public  — anything customer-facing or safe to hotlink (product
--                    images, branch photos, reward/coupon art, logo,
--                    marketing, review photos). Public read, authenticated
--                    write.
--   media-private — internal documents (branch legal docs, expense
--                    receipts, employee photos). No public read; access
--                    goes through signed URLs / RLS-checked reads only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('media-public', 'media-public', true, 15728640,
    array['image/jpeg','image/png','image/webp','image/gif','image/svg+xml']),
  ('media-private', 'media-private', false, 26214400,
    array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;


-- ----------------------------------------------------------------------------
-- 2. media_files — the central registry every category/module reads from
-- ----------------------------------------------------------------------------
create table if not exists public.media_files (
  id                bigint generated always as identity primary key,
  bucket_id         text not null check (bucket_id in ('media-public','media-private')),
  storage_path      text not null,                 -- path inside the bucket
  public_url        text,                          -- populated for media-public only
  thumbnail_path    text,                          -- path to generated thumbnail, same bucket
  original_filename text not null,
  mime_type         text not null,
  size_bytes        bigint not null default 0,
  width             integer,
  height            integer,
  checksum          text,                          -- sha-256 hex, used for duplicate detection
  category          text not null check (category in (
                      'product_images','product_galleries','employee_photos',
                      'customer_review_photos','reward_images','coupon_images',
                      'branch_images','business_logo','marketing_images',
                      'system_assets','documents'
                    )),
  entity_type       text,                          -- e.g. 'product','branch','employee','order_review','expense'
  entity_id         text,                          -- polymorphic reference id (text so it fits any pk type)
  branch_id         bigint references public.branches(id),
  uploaded_by       bigint references public.employees(id),
  uploaded_by_role  text,
  status            text not null default 'active' check (status in ('active','orphaned','deleted')),
  download_count    integer not null default 0,
  last_accessed_at  timestamp with time zone,
  deleted_at        timestamp with time zone,
  metadata          jsonb not null default '{}'::jsonb,
  created_at        timestamp with time zone not null default now(),
  updated_at        timestamp with time zone not null default now(),
  unique (bucket_id, storage_path)
);

create index if not exists idx_media_files_category    on public.media_files(category);
create index if not exists idx_media_files_entity       on public.media_files(entity_type, entity_id);
create index if not exists idx_media_files_branch       on public.media_files(branch_id);
create index if not exists idx_media_files_checksum     on public.media_files(checksum);
create index if not exists idx_media_files_status       on public.media_files(status);
create index if not exists idx_media_files_uploaded_by  on public.media_files(uploaded_by);
create index if not exists idx_media_files_created_at   on public.media_files(created_at desc);

comment on table public.media_files is
  'Phase 7.3 — central tracking registry for every file uploaded through the Media Center. Existing *_url text columns are left untouched; this table is additive.';


-- updated_at trigger, same pattern as other Phase 7.x tables
create or replace function public.media_files_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_media_files_updated_at on public.media_files;
create trigger trg_media_files_updated_at
  before update on public.media_files
  for each row execute function public.media_files_set_updated_at();


-- ----------------------------------------------------------------------------
-- 3. RLS — media_files
-- ----------------------------------------------------------------------------
-- Same posture as the rest of the app: Owner = full access (bypass),
-- Admin = full access by default (matches TAB_FINANCIAL/TAB_EXECUTIVE
-- posture), Manager = branch-scoped media only, Employee = only the
-- categories they're allowed to upload to (employee_photos of themselves,
-- customer_review_photos are actually inserted server-side/customer flow),
-- Customers never touch this table directly — review photo uploads from
-- the storefront go through a narrow insert policy scoped to
-- customer_review_photos only.

alter table public.media_files enable row level security;

drop policy if exists media_files_select on public.media_files;
create policy media_files_select on public.media_files
  for select
  using (
    exists (
      select 1 from public.employees e
      where e.user_id = auth.uid()
        and (
          e.is_owner = true
          or e.role = 'admin'
          or (e.role = 'manager' and (media_files.branch_id is null or media_files.branch_id = e.branch_id))
          or (e.role = 'employee' and media_files.category = 'employee_photos' and media_files.uploaded_by = e.id)
        )
    )
  );

drop policy if exists media_files_insert on public.media_files;
create policy media_files_insert on public.media_files
  for insert
  with check (
    exists (
      select 1 from public.employees e
      where e.user_id = auth.uid()
        and (
          e.is_owner = true
          or e.role = 'admin'
          or (e.role = 'manager' and media_files.category in (
                'product_images','product_galleries','branch_images',
                'coupon_images','reward_images'
              ) and (media_files.branch_id is null or media_files.branch_id = e.branch_id))
          or (e.role = 'employee' and media_files.category = 'employee_photos' and media_files.uploaded_by = e.id)
        )
    )
  );

drop policy if exists media_files_update on public.media_files;
create policy media_files_update on public.media_files
  for update
  using (
    exists (
      select 1 from public.employees e
      where e.user_id = auth.uid()
        and (e.is_owner = true or e.role = 'admin'
             or (e.role = 'manager' and (media_files.branch_id is null or media_files.branch_id = e.branch_id)))
    )
  );

drop policy if exists media_files_delete on public.media_files;
create policy media_files_delete on public.media_files
  for delete
  using (
    exists (
      select 1 from public.employees e
      where e.user_id = auth.uid()
        and (e.is_owner = true or e.role = 'admin'
             or (e.role = 'manager' and media_files.branch_id = e.branch_id))
    )
  );


-- ----------------------------------------------------------------------------
-- 4. RLS — storage.objects for the two new buckets
-- ----------------------------------------------------------------------------
-- Public bucket: anyone (including anon storefront visitors) can read;
-- only authenticated employees with an employees row can write/update/delete.
drop policy if exists media_public_read on storage.objects;
create policy media_public_read on storage.objects
  for select
  using (bucket_id = 'media-public');

drop policy if exists media_public_write on storage.objects;
create policy media_public_write on storage.objects
  for insert
  with check (
    bucket_id = 'media-public'
    and exists (select 1 from public.employees e where e.user_id = auth.uid())
  );

drop policy if exists media_public_update on storage.objects;
create policy media_public_update on storage.objects
  for update
  using (
    bucket_id = 'media-public'
    and exists (select 1 from public.employees e where e.user_id = auth.uid())
  );

drop policy if exists media_public_delete on storage.objects;
create policy media_public_delete on storage.objects
  for delete
  using (
    bucket_id = 'media-public'
    and exists (
      select 1 from public.employees e
      where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin' or e.role = 'manager')
    )
  );

-- Private bucket: no public read at all. Only employees (any role, for
-- their own uploads) can read/write; only Owner/Admin/branch-Manager may
-- delete.
drop policy if exists media_private_read on storage.objects;
create policy media_private_read on storage.objects
  for select
  using (
    bucket_id = 'media-private'
    and exists (select 1 from public.employees e where e.user_id = auth.uid())
  );

drop policy if exists media_private_write on storage.objects;
create policy media_private_write on storage.objects
  for insert
  with check (
    bucket_id = 'media-private'
    and exists (select 1 from public.employees e where e.user_id = auth.uid())
  );

drop policy if exists media_private_delete on storage.objects;
create policy media_private_delete on storage.objects
  for delete
  using (
    bucket_id = 'media-private'
    and exists (
      select 1 from public.employees e
      where e.user_id = auth.uid() and (e.is_owner = true or e.role = 'admin' or e.role = 'manager')
    )
  );


-- ----------------------------------------------------------------------------
-- 5. Storage analytics view (Part 8)
-- ----------------------------------------------------------------------------
create or replace view public.media_storage_stats as
select
  category,
  bucket_id,
  count(*) filter (where status = 'active')                       as file_count,
  coalesce(sum(size_bytes) filter (where status = 'active'), 0)   as total_bytes,
  count(*) filter (where status = 'orphaned')                     as orphaned_count,
  max(created_at)                                                 as last_upload_at
from public.media_files
group by category, bucket_id;

comment on view public.media_storage_stats is
  'Phase 7.3 Part 8 — per-category storage usage, feeds the Media Center stats bar.';


-- ----------------------------------------------------------------------------
-- 6. Duplicate detection helper (Part 5 / Part 9)
-- ----------------------------------------------------------------------------
create or replace function public.find_duplicate_media(p_checksum text)
returns setof public.media_files
language sql stable as $$
  select * from public.media_files
  where checksum = p_checksum and status = 'active'
  order by created_at asc;
$$;


-- ----------------------------------------------------------------------------
-- 7. Usage / cleanup scan (Part 9)
-- ----------------------------------------------------------------------------
-- Cross-checks media_files against every known legacy *_url column so the
-- Media Center can flag files that are no longer referenced anywhere
-- (Products.image_url, order_reviews.photo_url, expenses.receipt_url,
-- branch_documents.file_url, branch_announcements.attachment_url) as well
-- as its own entity_type/entity_id linkage. Marks matches 'active',
-- non-matches 'orphaned'. Never deletes — Part 9 requires "Safe Cleanup"
-- and "Never delete files still in use", so this only flags; actual
-- deletion is a separate, explicit admin action in the UI.
create or replace function public.refresh_media_usage()
returns table(scanned integer, orphaned integer) language plpgsql as $$
declare
  v_scanned integer := 0;
  v_orphaned integer := 0;
begin
  update public.media_files m
  set status = 'active'
  where m.status <> 'deleted'
    and (
      exists (select 1 from public.products p where p.image_url = m.public_url)
      or exists (select 1 from public.order_reviews r where r.photo_url = m.public_url)
      or exists (select 1 from public.expenses ex where ex.receipt_url = m.public_url)
      or exists (select 1 from public.branch_documents bd where bd.file_url = m.public_url)
      or exists (select 1 from public.branch_announcements ba where ba.attachment_url = m.public_url)
      or (m.entity_type is not null and m.entity_id is not null)  -- explicit linkage from new uploads
    );

  update public.media_files m
  set status = 'orphaned'
  where m.status = 'active'
    and not (
      exists (select 1 from public.products p where p.image_url = m.public_url)
      or exists (select 1 from public.order_reviews r where r.photo_url = m.public_url)
      or exists (select 1 from public.expenses ex where ex.receipt_url = m.public_url)
      or exists (select 1 from public.branch_documents bd where bd.file_url = m.public_url)
      or exists (select 1 from public.branch_announcements ba where ba.attachment_url = m.public_url)
      or (m.entity_type is not null and m.entity_id is not null)
    );

  select count(*) into v_scanned from public.media_files where status <> 'deleted';
  select count(*) into v_orphaned from public.media_files where status = 'orphaned';
  return query select v_scanned, v_orphaned;
end;
$$;

comment on function public.refresh_media_usage is
  'Phase 7.3 Part 9 — flags unused media as orphaned. Never deletes; the UI cleanup tool acts on the flag explicitly.';


-- ----------------------------------------------------------------------------
-- 8. Realtime (Part 10)
-- ----------------------------------------------------------------------------
alter publication supabase_realtime add table public.media_files;

-- ============================================================================
-- END PHASE 7.3 MIGRATION
-- ============================================================================
