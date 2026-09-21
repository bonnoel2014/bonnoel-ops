-- =========================================================
-- 본노엘 운영 앱 (홈 + 비품 재고·발주) - Supabase 테이블 설정
-- 매뉴얼북·로그북과 같은 프로젝트(caetlljnyxsusswqhtci)에 테이블만 추가합니다.
-- 사용법: Supabase 대시보드 -> 왼쪽 메뉴 SQL Editor -> New query ->
--        이 파일 내용 전체 복사해서 붙여넣기 -> Run  (한 번만)
-- 매뉴얼북의 supabase-setup.sql, supabase-migration-branches.sql 이 먼저 실행된 상태여야 합니다.
-- =========================================================

-- 0. 직원 명단은 매뉴얼북의 manual_staff 를 그대로 같이 씁니다. 열만 추가합니다.
alter table manual_staff add column if not exists pin text;                                   -- 4자리 비밀번호 (처음 들어올 때 본인이 정함)
alter table manual_staff add column if not exists role text not null default 'staff';         -- staff / manager / owner
alter table manual_staff add column if not exists active boolean not null default true;       -- 퇴사하면 false

-- 사장님 계정이 없으면 하나 만들어 둡니다 (매장 없음 = 모든 매장에서 보임). 이름은 나중에 앱에서 바꿀 수 있어요.
insert into manual_staff (name, role)
select '사장님', 'owner'
where not exists (select 1 from manual_staff where role = 'owner');

-- 1. 비품 분류 (종이 리스트의 파란 띠)
create table if not exists ops_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

-- 2. 비품 품목
create table if not exists ops_items (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references ops_categories(id) on delete set null,
  name text not null,
  unit text not null default '개',       -- 묶음 / box / 포대 / 줄 / 봉 / 개 / 병
  note text,                              -- 예: 실장님께 요청, 지하에 요청
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- 3. 매장별 적정재고 (없으면 그 매장에선 안 씀)
create table if not exists ops_item_branch (
  item_id uuid not null references ops_items(id) on delete cascade,
  branch_id uuid not null references manual_branches(id) on delete cascade,
  target_qty numeric not null default 0,
  active boolean not null default true,
  primary key (item_id, branch_id)
);

-- 4. 재고 체크 기록 (주 1회, 품목마다 한 줄)
create table if not exists ops_stock_checks (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references manual_branches(id) on delete cascade,
  item_id uuid not null references ops_items(id) on delete cascade,
  qty numeric not null,
  staff_id uuid references manual_staff(id) on delete set null,
  checked_at timestamptz not null default now()
);
create index if not exists ops_stock_checks_branch_item_idx on ops_stock_checks (branch_id, item_id, checked_at desc);

-- 5. 주문 (사장님이 "주문함" 누른 것 → 도착 확인까지)
create table if not exists ops_orders (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references manual_branches(id) on delete cascade,
  item_id uuid not null references ops_items(id) on delete cascade,
  qty numeric not null,
  status text not null default 'ordered',   -- ordered / received / cancelled
  eta_date date,
  ordered_by uuid references manual_staff(id) on delete set null,
  ordered_at timestamptz not null default now(),
  received_qty numeric,
  received_by uuid references manual_staff(id) on delete set null,
  received_at timestamptz,
  mismatch boolean not null default false,  -- 수량이 틀리게 옴
  resolved boolean not null default false,  -- 사장님이 확인함
  memo text
);
create index if not exists ops_orders_branch_status_idx on ops_orders (branch_id, status);

-- 6. 점간 이동
create table if not exists ops_transfers (
  id uuid primary key default gen_random_uuid(),
  from_branch uuid not null references manual_branches(id) on delete cascade,
  to_branch uuid not null references manual_branches(id) on delete cascade,
  item_id uuid not null references ops_items(id) on delete cascade,
  qty numeric not null,
  created_by uuid references manual_staff(id) on delete set null,
  created_at timestamptz not null default now(),
  received_qty numeric,
  received_by uuid references manual_staff(id) on delete set null,
  received_at timestamptz,
  memo text
);

-- RLS: 매뉴얼북·로그북과 같은 수준 (anon 키로 읽기/쓰기 허용)
alter table ops_categories enable row level security;
alter table ops_items enable row level security;
alter table ops_item_branch enable row level security;
alter table ops_stock_checks enable row level security;
alter table ops_orders enable row level security;
alter table ops_transfers enable row level security;

drop policy if exists "anon full access" on ops_categories;
create policy "anon full access" on ops_categories for all using (true) with check (true);
drop policy if exists "anon full access" on ops_items;
create policy "anon full access" on ops_items for all using (true) with check (true);
drop policy if exists "anon full access" on ops_item_branch;
create policy "anon full access" on ops_item_branch for all using (true) with check (true);
drop policy if exists "anon full access" on ops_stock_checks;
create policy "anon full access" on ops_stock_checks for all using (true) with check (true);
drop policy if exists "anon full access" on ops_orders;
create policy "anon full access" on ops_orders for all using (true) with check (true);
drop policy if exists "anon full access" on ops_transfers;
create policy "anon full access" on ops_transfers for all using (true) with check (true);

-- =========================================================
-- 7. 품목 씨앗 — 왕십리점 종이 비품리스트(26.4.2) 순서 그대로. 처음 한 번만 들어갑니다.
--    적정재고는 앱의 "비품 설정"에서 매장별로 넣으세요.
-- =========================================================
do $$
declare
  c uuid;
begin
  if (select count(*) from ops_items) > 0 then
    return;   -- 이미 품목이 있으면 건너뜀
  end if;

  insert into ops_categories (name, sort_order) values ('식빵', 1) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '식빵 대(접착)', '묶음', 1), (c, '식빵 중', '묶음', 2);

  insert into ops_categories (name, sort_order) values ('손잡이', 2) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '손잡이 대', '포대', 1), (c, '손잡이 중', '포대', 2), (c, '손잡이 소', '묶음', 3);

  insert into ops_categories (name, sort_order) values ('빵봉투', 3) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '단과자 봉투', '묶음', 1), (c, '파운드 봉투', '묶음', 2), (c, '소금빵 봉투', '묶음', 3),
    (c, '깜빠뉴·초코머핀류 봉투', '묶음', 4), (c, '치아바타 봉투', '묶음', 5), (c, '마늘바게트 비닐', '묶음', 6);

  insert into ops_categories (name, sort_order) values ('마들렌 (스마일)', 4) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values (c, '마들렌 봉투', '묶음', 1);

  insert into ops_categories (name, sort_order) values ('크라프트 종이 빵봉투', 5) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '바게트 종이봉투', '묶음', 1), (c, '종이봉투 소 (소금빵 2개)', '묶음', 2),
    (c, '종이봉투 중 (소금빵 5개 정도)', '묶음', 3), (c, '종이봉투 대 (소금빵 8개 정도)', '묶음', 4);

  insert into ops_categories (name, sort_order) values ('몰드 케이스', 6) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '은박 몰드 (마늘·산딸기)', '묶음', 1), (c, '호두파이 몰드', '묶음', 2);

  insert into ops_categories (name, sort_order) values ('러스크 봉투 / 제습제', 7) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '러스크 봉투', '개', 1), (c, '제습제', '개', 2);

  insert into ops_categories (name, sort_order) values ('리뷰 스티커', 8) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '동그라미 리뷰', '줄', 1), (c, '네모 리뷰', '줄', 2);

  insert into ops_categories (name, sort_order) values ('유산지', 9) returning id into c;
  insert into ops_items (category_id, name, unit, note, sort_order) values
    (c, '스마일 유산지', '묶음', '실장님께 요청', 1), (c, '앙버터 유산지 (흰색)', '묶음', '지하에 요청', 2);

  insert into ops_categories (name, sort_order) values ('철판 싸는 대형 비닐', 10) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '투명 대비닐', '묶음', 1), (c, '파랑 대비닐', '묶음', 2), (c, '검정 대비닐', '묶음', 3);

  insert into ops_categories (name, sort_order) values ('영수증 롤지 / 빵끈', 11) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '영수증 롤지', '개', 1), (c, '빵끈', '묶음', 2);

  insert into ops_categories (name, sort_order) values ('커피', 12) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '원두', '봉', 1), (c, '1구 캐리어', '개', 2), (c, '2구 캐리어', '개', 3),
    (c, 'ICE 컵', '줄', 4), (c, 'ICE 뚜껑', '줄', 5), (c, 'HOT 컵', '줄', 6), (c, 'HOT 뚜껑', '줄', 7),
    (c, 'ICE 빨대', '봉', 8), (c, '종이 페이퍼 (아아용)', '개', 9), (c, '매직랩 (뜨아용)', '개', 10);

  insert into ops_categories (name, sort_order) values ('케이크', 13) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '케이크 픽', '개', 1), (c, '1살 초 (짧은거)', '개', 2), (c, '10살 초 (긴거)', '개', 3),
    (c, '빵칼', '봉', 4), (c, '성냥', '개', 5);

  insert into ops_categories (name, sort_order) values ('스티커', 14) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '쌀 스티커', '묶음', 1), (c, '분홍 스티커', '줄', 2), (c, '하트 스티커', '줄', 3), (c, '냉장보관 (소)', '묶음', 4);

  insert into ops_categories (name, sort_order) values ('테이프', 15) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '신선배송 (택배)', '개', 1), (c, '돌돌이 테이프', '개', 2);

  insert into ops_categories (name, sort_order) values ('포크 / 생크림 스푼', 16) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '포크(대) / 미니포크', '봉', 1), (c, '생크림 스푼', '봉', 2);

  insert into ops_categories (name, sort_order) values ('위생 장갑 / 물티슈 / 소독', 17) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '위생장갑 (뽀송이)', 'box', 1), (c, '물티슈', '개', 2), (c, '소독 알코올', '개', 3);

  insert into ops_categories (name, sort_order) values ('종이 몰드 + 뚜껑', 18) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '카스텔라 바닥', '줄', 1), (c, '카스텔라 뚜껑', '줄', 2), (c, '화이트롤 바닥', '줄', 3), (c, '화이트롤 뚜껑', '줄', 4);

  insert into ops_categories (name, sort_order) values ('쿠키 케이스 / 버터링 몰드', 19) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '쿠키 하드케이스', '묶음', 1), (c, '버터링 몰드', '묶음', 2);

  insert into ops_categories (name, sort_order) values ('소비기한 / 빵 이름표', 20) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '소비기한 스티커', '묶음', 1), (c, '빵 이름표 (흰색)', 'box', 2);

  insert into ops_categories (name, sort_order) values ('볼펜류 / 냉판 유산지 / 휴지 / 크린콜', 21) returning id into c;
  insert into ops_items (category_id, name, unit, sort_order) values
    (c, '볼펜', 'box', 1), (c, '네임펜', 'box', 2), (c, '냉판 유산지', '묶음', 3),
    (c, '두루마리 휴지 (대)', '개', 4), (c, '크린콜', '병', 5);

  -- 모든 매장에서 모든 품목을 켬 (적정재고 0 = 아직 안 정함)
  insert into ops_item_branch (item_id, branch_id, target_qty, active)
  select i.id, b.id, 0, true from ops_items i cross join manual_branches b
  on conflict do nothing;
end $$;
