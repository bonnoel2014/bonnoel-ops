-- 출근 복장 체크 (기획/출근복장체크_설계.md)
-- 출근 기록에 복장 체크 결과·빠진 항목·매니저 지적을 남깁니다. 한 번만 실행하면 돼요.
-- 머리망 제외·예외 신청, 본 시행일은 ops_settings (key 'dress')에 저장되므로 표를 새로 만들 필요가 없어요.
alter table ops_attendance add column if not exists dress_check jsonb;    -- {"uniform":true,"apron":true,"hairnet":true|"exempt","hat":"none|company|personal","mask":true,"nametag":true}
alter table ops_attendance add column if not exists dress_missing jsonb;  -- [{"item":"nametag","reason":"분실"}] ("없어요"로 넘긴 것, 연습 기간에 빠뜨린 것)
alter table ops_attendance add column if not exists dress_flag jsonb;     -- {"memo":"이름표 안 함","by":"<직원 id>","at":"..."} 매니저·사장님 지적
