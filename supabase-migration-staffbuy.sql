-- =========================================================
-- 본노엘 운영 앱 7차: 직원 구매 (직원 할인으로 산 빵 기록)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================

-- 1. 직원 구매 (영수증 한 장 = 한 줄)
create table if not exists ops_staff_purchases (
  id uuid primary key default gen_random_uuid(),
  bought_on date not null,                      -- 산 날짜
  staff_id uuid references manual_staff(id) on delete set null,       -- 산 사람
  branch_id uuid references manual_branches(id) on delete set null,   -- 어느 매장에서 샀나
  pay_method text not null default 'card',      -- cash / transfer / kakaopay (30%) · cash_receipt / card / seoulpay / onnuri (20%)
  discount_rate int not null default 20,        -- 그때 적용한 할인율(%). 규칙이 바뀌어도 옛 기록은 그대로
  list_total numeric not null default 0,        -- 정가 합계(할인 전)
  discount numeric not null default 0,          -- 할인 금액
  paid numeric not null default 0,              -- 실제 낸 금액
  items text,                                   -- 산 것 요약 (예: 버터프레첼 1개)
  memo text,
  photo_path text,                              -- 저장소(receipts 버킷) 안 경로 (staff/매장/월/파일)
  ocr jsonb,                                    -- 자동으로 읽은 원본 값
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ops_staff_purchases_bought_on_idx on ops_staff_purchases (bought_on);
create index if not exists ops_staff_purchases_staff_idx on ops_staff_purchases (staff_id);

alter table ops_staff_purchases enable row level security;
drop policy if exists "anon full access" on ops_staff_purchases;
create policy "anon full access" on ops_staff_purchases for all using (true) with check (true);

-- 2. 영수증 사진 저장소 (카드 지출과 같은 receipts 버킷을 씀. 카드 지출 SQL을 이미 실행했으면 아무 일도 안 함)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "receipts read" on storage.objects;
create policy "receipts read" on storage.objects for select using (bucket_id = 'receipts');
drop policy if exists "receipts insert" on storage.objects;
create policy "receipts insert" on storage.objects for insert with check (bucket_id = 'receipts');
drop policy if exists "receipts delete" on storage.objects;
create policy "receipts delete" on storage.objects for delete using (bucket_id = 'receipts');
