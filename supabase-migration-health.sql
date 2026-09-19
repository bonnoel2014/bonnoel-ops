-- =========================================================
-- 본노엘 운영 앱 8차: 보건증 만료 관리
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

-- 1. 보건증 기록 한 장 = 한 줄 (옛 기록도 남겨서 위생 점검 때 증빙으로 씀)
create table if not exists ops_health_certs (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references manual_staff(id) on delete cascade,
  expires_on date,                                                   -- 만료일 (제출 상태에서는 비어 있을 수 있음)
  status text not null default 'confirmed',                          -- submitted(제출·확인 대기) / confirmed(완료)
  photo_path text,                                                   -- 저장소 documents 안의 보건증 사진 (health/...)
  source text not null default 'app',                                -- sheet(시트 붙여넣기) / app(직원이 사진 올림) / manual(매니저가 날짜 입력)
  submitted_by uuid references manual_staff(id) on delete set null,
  confirmed_by uuid references manual_staff(id) on delete set null,
  confirmed_at timestamptz,
  memo text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ops_health_certs_staff_idx on ops_health_certs(staff_id);

alter table ops_health_certs enable row level security;
drop policy if exists "anon full access" on ops_health_certs;
create policy "anon full access" on ops_health_certs for all using (true) with check (true);

-- 2. 사진 저장소: 입사 서류(6차)에서 만든 documents 버킷을 같이 씀. 보건증은 JPEG라서 허용 형식만 넓힘.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 15728640, array['application/pdf', 'image/png', 'image/jpeg'])
on conflict (id) do update set allowed_mime_types = array['application/pdf', 'image/png', 'image/jpeg'];

drop policy if exists "documents read" on storage.objects;
create policy "documents read" on storage.objects for select using (bucket_id = 'documents');
drop policy if exists "documents insert" on storage.objects;
create policy "documents insert" on storage.objects for insert with check (bucket_id = 'documents');
drop policy if exists "documents delete" on storage.objects;
create policy "documents delete" on storage.objects for delete using (bucket_id = 'documents');

-- 3. 만료일 넣기는 앱에서: 홈 → 보건증 관리 → 맨 아래 "구글 시트에서 가져오기"에 시트 줄을 붙여넣기.
--    (직원 실명은 공개 저장소에 두지 않으려고 SQL에는 씨앗을 넣지 않습니다)

-- 확인: 들어간 줄 보기
select s.name, h.expires_on, h.status, h.source from ops_health_certs h join manual_staff s on s.id = h.staff_id order by h.expires_on;
