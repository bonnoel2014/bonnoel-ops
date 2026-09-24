-- =========================================================
-- 본노엘 운영 앱: 알바 로그북 (근무자 업무일지 · 손님 요청 · 특이사항)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================

-- 근무자 한 명이 하루 한 근무조(오픈/미들/마감)에 쓰는 일지 한 장 = 한 줄
create table if not exists ops_shift_logs (
  id uuid primary key default gen_random_uuid(),
  log_date date not null,                                            -- 근무한 날
  branch_id uuid references manual_branches(id) on delete set null,  -- 매장
  staff_id uuid references manual_staff(id) on delete set null,      -- 쓴 사람
  shift text not null default 'open',                                -- open(오픈) / middle(미들) / close(마감)
  nothing boolean not null default false,                            -- "특이사항 없음"으로 제출
  items jsonb not null default '[]'::jsonb,                          -- [{cat, text, photo_path, done_at, done_by, done_note}]
  mgr_checked_by uuid references manual_staff(id) on delete set null,  -- 매니저 확인
  mgr_checked_at timestamptz,
  owner_checked_at timestamptz,                                      -- 사장님 확인
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists ops_shift_logs_one_idx on ops_shift_logs (log_date, staff_id, shift);
create index if not exists ops_shift_logs_date_idx on ops_shift_logs (log_date);
create index if not exists ops_shift_logs_branch_idx on ops_shift_logs (branch_id);

alter table ops_shift_logs enable row level security;
drop policy if exists "anon full access" on ops_shift_logs;
create policy "anon full access" on ops_shift_logs for all using (true) with check (true);

-- 사진은 영수증과 같은 receipts 버킷의 alog/ 경로에 저장 (카드 지출 SQL을 이미 실행했으면 아무 일도 안 함)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
