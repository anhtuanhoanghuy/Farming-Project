-- APK releases checked by the app on launch. The app forces an update when the
-- newest active row has a version_code greater than the installed build number
-- (the number after '+' in pubspec.yaml).

create table if not exists public.app_releases (
  id uuid primary key default gen_random_uuid(),
  version_code integer not null unique,
  version_name text not null,
  apk_url text not null,
  sha256 text not null check (sha256 ~ '^[0-9a-fA-F]{64}$'),
  release_notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.app_releases enable row level security;

-- Readable before sign-in (the update check runs on the splash screen).
drop policy if exists "app_releases readable by everyone" on public.app_releases;
create policy "app_releases readable by everyone"
  on public.app_releases for select
  to anon, authenticated
  using (is_active);

-- No insert/update/delete policies: only the dashboard / service role can change rows.

-- Publishing a release:
--   1. Build:   flutter build apk --release   (pubspec version must be e.g. 1.2.0+5)
--   2. Upload build\app\outputs\flutter-apk\app-release.apk to Google Drive,
--      share as "Anyone with the link".
--   3. Hash:    Get-FileHash app-release.apk -Algorithm SHA256
--   4. Insert:
--
-- insert into public.app_releases (version_code, version_name, apk_url, sha256, release_notes)
-- values (5, '1.2.0',
--         'https://drive.google.com/file/d/FILE_ID/view?usp=sharing',
--         'PASTE_SHA256_HERE',
--         'Nội dung thay đổi');
