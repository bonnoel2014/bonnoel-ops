-- =========================================================
-- 본노엘 운영 앱 5차: 카드 지출 (법인카드 영수증)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================

-- 1. 법인카드 목록 (끝 4자리로 지점을 알아냄)
create table if not exists ops_cards (
  id uuid primary key default gen_random_uuid(),
  last4 text not null,                          -- 카드번호 마지막 4자리
  name text not null,                           -- 예: 왕십리 카드, 사장님 기명카드
  branch_id uuid references manual_branches(id) on delete set null,   -- null = 공통(사장님)
  ask_branch boolean not null default false,    -- true면 올릴 때 지점을 물어봄 (사장님 카드처럼 여러 곳에서 쓰는 카드)
  active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

-- 2. 지출 내역 (영수증 한 장 = 한 줄)
create table if not exists ops_expenses (
  id uuid primary key default gen_random_uuid(),
  spent_on date not null,                       -- 결제 날짜
  merchant text,                                -- 가게 이름
  amount numeric not null default 0,            -- 결제 금액(원)
  card_id uuid references ops_cards(id) on delete set null,
  card_last4 text,                              -- 영수증에서 읽은 끝 4자리 (카드 목록에 없어도 남겨 둠)
  branch_id uuid references manual_branches(id) on delete set null,   -- null = 공통(사장님)
  category text not null default '기타',
  memo text,
  photo_path text,                              -- 저장소(receipts 버킷) 안 경로
  ocr jsonb,                                    -- 자동으로 읽은 원본 값
  source text not null default 'receipt',       -- receipt(영수증) / statement(명세서에서 등록)
  statement_key text,                           -- 카드사 명세서와 맞춰졌으면 표시
  uploaded_by uuid references manual_staff(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ops_expenses_spent_on_idx on ops_expenses (spent_on);

alter table ops_cards enable row level security;
alter table ops_expenses enable row level security;
drop policy if exists "anon full access" on ops_cards;
create policy "anon full access" on ops_cards for all using (true) with check (true);
drop policy if exists "anon full access" on ops_expenses;
create policy "anon full access" on ops_expenses for all using (true) with check (true);

-- 3. 영수증 사진 저장소 (비공개 버킷, 앱에서 서명 URL로 봄). 사진 1장 최대 5MB
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "receipts read" on storage.objects;
create policy "receipts read" on storage.objects for select using (bucket_id = 'receipts');
drop policy if exists "receipts insert" on storage.objects;
create policy "receipts insert" on storage.objects for insert with check (bucket_id = 'receipts');
drop policy if exists "receipts delete" on storage.objects;
create policy "receipts delete" on storage.objects for delete using (bucket_id = 'receipts');
