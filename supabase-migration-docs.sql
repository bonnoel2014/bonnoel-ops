-- =========================================================
-- 본노엘 운영 앱 6차: 입사 서류 (근로계약서 전자 서명·자동 교부)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

-- 1. 서류 한 장 = 한 줄
create table if not exists ops_documents (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null,                                            -- 한 번에 준비한 서류 묶음
  staff_id uuid not null references manual_staff(id) on delete cascade,
  branch_id uuid references manual_branches(id) on delete set null,   -- 주된 근무지
  doc_key text not null,                                             -- contract / privacy / pledge / cctv / uniform / guardian
  doc_title text not null,
  template_version text not null,                                    -- 양식 버전 (문구가 바뀌면 올림)
  data jsonb not null default '{}',                                  -- 계약 조건 + 본인 입력 정보 + 체크 항목
  status text not null default 'prepared',                           -- prepared(서명 대기) / signed(서명됨) / sent(발송 완료) / failed(발송 실패)
  signature_path text,                                               -- 저장소 documents 안의 서명 이미지
  pdf_path text,                                                     -- 저장소 documents 안의 PDF
  pdf_sha256 text,                                                   -- PDF 지문 (파일이 안 바뀌었다는 증거)
  signed_at timestamptz,
  signed_ua text,                                                    -- 서명한 기기 정보
  signed_ip text,                                                    -- 접속 IP (서버 함수가 기록)
  email_to text,
  email_cc text,
  email_sent_at timestamptz,
  email_error text,
  prepared_by uuid references manual_staff(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ops_documents_staff_idx on ops_documents(staff_id);
create index if not exists ops_documents_batch_idx on ops_documents(batch_id);

alter table ops_documents enable row level security;
drop policy if exists "anon full access" on ops_documents;
create policy "anon full access" on ops_documents for all using (true) with check (true);

-- 2. 설정 표 (급여 4차에서 이미 만들었으면 건너뜀)
create table if not exists ops_settings (
  key text primary key,
  value jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table ops_settings enable row level security;
drop policy if exists "anon full access" on ops_settings;
create policy "anon full access" on ops_settings for all using (true) with check (true);

-- 3. 서명·PDF 저장소 (비공개, 앱에서는 서명 URL로만 봄)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 15728640, array['application/pdf', 'image/png'])
on conflict (id) do nothing;

drop policy if exists "documents read" on storage.objects;
create policy "documents read" on storage.objects for select using (bucket_id = 'documents');
drop policy if exists "documents insert" on storage.objects;
create policy "documents insert" on storage.objects for insert with check (bucket_id = 'documents');
drop policy if exists "documents delete" on storage.objects;
create policy "documents delete" on storage.objects for delete using (bucket_id = 'documents');
