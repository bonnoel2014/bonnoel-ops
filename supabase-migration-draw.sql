-- 리뷰 뽑기판 (디지털 뽑기) — Supabase SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 먼저 돼 있어야 하는 것: supabase-migration-prepay.sql (취소할 때 매장 코드 확인에 prepay__auth 사용)
--                      사장님 앱 저장소의 supabase/owner.sql (사장님만 보기 owner__is 사용)
-- 기획: 기획/리뷰뽑기/v1/PRD.md
--
-- 원칙: 남은 알·등수별 집계·다음 등수는 전부 서버 함수 안에서만 다룬다.
--       매장폰(anon)은 "뽑기 결과" "뽑힌 칸 목록" "상품표"만 받고, 숫자 표는 로그인한 사장님만 읽는다.

-- ===== 표 =====
-- 매장별 1~5등 상품 문구
create table if not exists draw_prizes (
  branch_id uuid primary key references manual_branches(id) on delete cascade,
  labels jsonb not null default '{}'::jsonb,       -- {"1":"식빵(대)+파운드+마들렌", ... "5":"마들렌"}
  updated_at timestamptz not null default now(),
  updated_by text
);

-- 판: 매장마다 520알 한 판. remaining[1..5] = 등수별 남은 알, taken = 뽑힌 칸 번호(0~519)
create table if not exists draw_boards (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references manual_branches(id) on delete cascade,
  seq int not null default 1,
  remaining int[] not null default '{1,3,16,100,400}',
  taken int[] not null default '{}',
  started_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by text                                   -- 'auto'(다 뽑힘) / 'owner'(사장님이 새 판)
);
create index if not exists draw_boards_open on draw_boards(branch_id) where closed_at is null;

-- 뽑기 기록
create table if not exists draw_logs (
  id uuid primary key default gen_random_uuid(),
  board_id uuid not null references draw_boards(id) on delete cascade,
  branch_id uuid not null references manual_branches(id) on delete cascade,
  cell int not null,
  rank int not null check (rank between 1 and 5),
  prize_label text,
  status text not null default 'pending' check (status in ('pending', 'given', 'substituted', 'cancelled')),
  substitute text,                                 -- 다른 걸로 드렸을 때 뭐 줬는지
  staff_id uuid references manual_staff(id) on delete set null,   -- 매장폰(또는 매니저) 계정
  drawn_at timestamptz not null default now(),
  done_at timestamptz,
  cancelled_at timestamptz,
  returned boolean not null default false          -- 취소 때 알이 판으로 돌아갔는지
);
create index if not exists draw_logs_branch_time on draw_logs(branch_id, drawn_at);

-- ===== 잠금: anon(매장폰)은 표를 직접 못 읽음, 로그인한 사장님만 =====
alter table draw_prizes enable row level security;
alter table draw_boards enable row level security;
alter table draw_logs enable row level security;
revoke all on draw_prizes, draw_boards, draw_logs from anon;
grant select, insert, update, delete on draw_prizes, draw_boards, draw_logs to authenticated;
drop policy if exists owner_only on draw_prizes;
create policy owner_only on draw_prizes for all to authenticated using (owner__is()) with check (owner__is());
drop policy if exists owner_only on draw_boards;
create policy owner_only on draw_boards for all to authenticated using (owner__is()) with check (owner__is());
drop policy if exists owner_only on draw_logs;
create policy owner_only on draw_logs for all to authenticated using (owner__is()) with check (owner__is());

-- ===== 내부 도우미 =====
-- 지금 열려 있는 판 (없으면 새로 만듦). 호출하는 쪽에서 for update 잠금 뒤 다시 읽는다.
create or replace function draw__open_board(p_branch uuid) returns draw_boards
language plpgsql security definer set search_path = public as $$
declare b draw_boards; n int;
begin
  select * into b from draw_boards where branch_id = p_branch and closed_at is null order by started_at desc limit 1;
  if b.id is null then
    select coalesce(max(seq), 0) + 1 into n from draw_boards where branch_id = p_branch;
    insert into draw_boards (branch_id, seq) values (p_branch, n) returning * into b;
  end if;
  return b;
end $$;

-- 매장폰 계정 확인: 활성 직원이고 매장폰/매니저/사장님이며, 그 매장 소속(사장님은 매장 무관)
create or replace function draw__staff_ok(p_staff uuid, p_branch uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from manual_staff s
    where s.id = p_staff and coalesce(s.active, true)
      and s.role in ('kiosk', 'manager', 'owner')
      and (s.role = 'owner' or s.branch_id is null or s.branch_id = p_branch))
$$;

create or replace function draw__err(p_msg text) returns jsonb language sql immutable as $$
  select jsonb_build_object('ok', false, 'error', p_msg)
$$;

-- ===== 매장폰에서 쓰는 함수 (anon 허용) =====
-- 상품표 읽기
create or replace function draw_prizes_get(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ok', true,
    'labels', coalesce((select labels from draw_prizes where branch_id = p_branch), '{}'::jsonb))
$$;

-- 상품표 쓰기: 매니저·사장님이 자기 이름·비밀번호(4자리)로
create or replace function draw_prizes_set(p_branch uuid, p_staff uuid, p_pin text, p_labels jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s manual_staff; k text;
begin
  select * into s from manual_staff where id = p_staff and coalesce(active, true);
  if s.id is null or s.role not in ('manager', 'owner') then return draw__err('매니저나 사장님만 바꿀 수 있어요'); end if;
  if s.role <> 'owner' and s.branch_id is not null and s.branch_id <> p_branch then return draw__err('우리 매장 상품표만 바꿀 수 있어요'); end if;
  if s.pin is null or s.pin <> coalesce(p_pin, '') then return draw__err('비밀번호가 틀려요'); end if;
  for k in select unnest(array['1','2','3','4','5']) loop
    if coalesce(trim(p_labels ->> k), '') = '' then return draw__err(k || '등 상품이 비어 있어요'); end if;
  end loop;
  insert into draw_prizes (branch_id, labels, updated_at, updated_by)
  values (p_branch, p_labels, now(), s.name)
  on conflict (branch_id) do update set labels = excluded.labels, updated_at = now(), updated_by = excluded.updated_by;
  return jsonb_build_object('ok', true);
end $$;

-- 뽑힌 칸 목록 (화면에 빈 자국을 그리려고). 남은 알 숫자는 주지 않는다.
create or replace function draw_board_cells(p_branch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards;
begin
  b := draw__open_board(p_branch);
  return jsonb_build_object('ok', true, 'board_id', b.id, 'taken', to_jsonb(b.taken), 'total', 520);
end $$;

-- 뽑기: 손님이 누른 칸(p_cell 0~519)을 받아 서버가 남은 알 비율로 등수를 정한다. 결과는 저장된 뒤에만 돌려준다.
create or replace function draw_pick(p_branch uuid, p_staff uuid, p_cell int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards; lb jsonb; total int; pick int; acc int; r int; lg draw_logs; k text;
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  if p_cell is null or p_cell < 0 or p_cell > 519 then return draw__err('칸 번호가 이상해요'); end if;
  select labels into lb from draw_prizes where branch_id = p_branch;
  for k in select unnest(array['1','2','3','4','5']) loop
    if coalesce(trim(lb ->> k), '') = '' then return draw__err('상품표를 먼저 채워 주세요 (뽑기 상품표 메뉴)'); end if;
  end loop;

  b := draw__open_board(p_branch);
  select * into b from draw_boards where id = b.id for update;
  if b.closed_at is not null then b := draw__open_board(p_branch); select * into b from draw_boards where id = b.id for update; end if;
  if p_cell = any(b.taken) then return draw__err('이미 뽑힌 칸이에요. 다른 칸을 눌러 주세요'); end if;

  total := b.remaining[1] + b.remaining[2] + b.remaining[3] + b.remaining[4] + b.remaining[5];
  if total <= 0 then return draw__err('판이 비어 있어요. 잠시 뒤 다시 해 주세요'); end if;
  pick := floor(random() * total)::int + 1;   -- 1..total 중 하나 = 남은 알 중 하나
  acc := 0; r := 5;
  for i in 1..5 loop
    acc := acc + b.remaining[i];
    if pick <= acc then r := i; exit; end if;
  end loop;

  b.remaining[r] := b.remaining[r] - 1;
  update draw_boards set remaining = b.remaining, taken = array_append(taken, p_cell) where id = b.id;
  insert into draw_logs (board_id, branch_id, cell, rank, prize_label, staff_id)
  values (b.id, p_branch, p_cell, r, lb ->> r::text, p_staff) returning * into lg;

  -- 520알 다 뽑히면 판을 닫고 새 판은 다음 뽑기 때 자동으로 생김
  if total - 1 <= 0 then update draw_boards set closed_at = now(), closed_by = 'auto' where id = b.id; end if;

  return jsonb_build_object('ok', true, 'log_id', lg.id, 'rank', r, 'prize', lg.prize_label, 'cell', p_cell);
end $$;

-- 지급 완료 / 다른 걸로 드림
create or replace function draw_done(p_log uuid, p_status text, p_substitute text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lg draw_logs;
begin
  if p_status not in ('given', 'substituted') then return draw__err('상태가 이상해요'); end if;
  if p_status = 'substituted' and coalesce(trim(p_substitute), '') = '' then return draw__err('뭘 드렸는지 적어 주세요'); end if;
  select * into lg from draw_logs where id = p_log for update;
  if lg.id is null then return draw__err('뽑기 기록을 못 찾았어요'); end if;
  if lg.status = 'cancelled' then return draw__err('이미 취소된 뽑기예요'); end if;
  update draw_logs set status = p_status, substitute = case when p_status = 'substituted' then trim(p_substitute) else null end, done_at = now() where id = p_log;
  return jsonb_build_object('ok', true);
end $$;

-- 취소: 선결제 매장 코드(또는 사장님 코드)로. 알은 판으로 돌아간다(판이 아직 열려 있을 때).
create or replace function draw_cancel(p_log uuid, p_branch uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare lg draw_logs; b draw_boards; role text; back boolean := false;
begin
  role := prepay__auth(p_branch, p_code);
  if role is null or role = 'locked' then return prepay__err(role); end if;
  select * into lg from draw_logs where id = p_log for update;
  if lg.id is null then return draw__err('뽑기 기록을 못 찾았어요'); end if;
  if lg.branch_id <> p_branch and role <> 'owner' then return draw__err('우리 매장 뽑기만 취소할 수 있어요'); end if;
  if lg.status = 'cancelled' then return draw__err('이미 취소된 뽑기예요'); end if;
  select * into b from draw_boards where id = lg.board_id for update;
  if b.closed_at is null then
    b.remaining[lg.rank] := b.remaining[lg.rank] + 1;
    update draw_boards set remaining = b.remaining, taken = array_remove(taken, lg.cell) where id = b.id;
    back := true;
  end if;
  update draw_logs set status = 'cancelled', cancelled_at = now(), returned = back where id = p_log;
  return jsonb_build_object('ok', true, 'returned', back);
end $$;

-- ===== 사장님 앱에서 쓰는 함수 (로그인한 사장님만) =====
-- 지금 판을 닫고 새 판 시작 (남은 알이 있어도)
create or replace function draw_owner_new_board(p_branch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards;
begin
  if not owner__is() then return draw__err('사장님만 할 수 있어요'); end if;
  update draw_boards set closed_at = now(), closed_by = 'owner' where branch_id = p_branch and closed_at is null;
  b := draw__open_board(p_branch);
  return jsonb_build_object('ok', true, 'seq', b.seq);
end $$;

-- ===== 권한 =====
revoke all on function draw__open_board(uuid), draw__staff_ok(uuid, uuid), draw__err(text) from public, anon, authenticated;
grant execute on function draw_prizes_get(uuid), draw_prizes_set(uuid, uuid, text, jsonb), draw_board_cells(uuid),
  draw_pick(uuid, uuid, int), draw_done(uuid, text, text), draw_cancel(uuid, uuid, text) to anon, authenticated;
revoke all on function draw_owner_new_board(uuid) from public, anon;
grant execute on function draw_owner_new_board(uuid) to authenticated;

-- ===== 씨앗: 매장별 상품표 (2026-10-03 사진 기준. 성수점 2등은 확인 뒤 앱에서 고치면 됨) =====
insert into draw_prizes (branch_id, labels, updated_by)
select b.id, v.labels, '씨앗'
from (values
  ('왕십리점', '{"1":"식빵(대) + 파운드 + 마들렌","2":"식빵(대)","3":"파운드","4":"휘낭시에","5":"마들렌"}'::jsonb),
  ('성수점',   '{"1":"선결제 충전금 30,000원","2":"러스크 1봉","3":"휘낭시에 1개","4":"파운드 1개","5":"마들렌 1개"}'::jsonb),
  ('중계점',   '{"1":"선결제 충전금 30,000원","2":"러스크 1봉","3":"파운드 1개","4":"휘낭시에 1개","5":"마들렌 1개"}'::jsonb),
  ('답십리점', '{"1":"선결제 충전금 30,000원","2":"러스크 1봉","3":"휘낭시에 1개 + 마들렌 1개","4":"파운드 1개","5":"마들렌 1개"}'::jsonb)
) as v(name, labels)
join manual_branches b on b.name = v.name
on conflict (branch_id) do nothing;
