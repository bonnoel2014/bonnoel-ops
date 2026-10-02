// 영수증 사진을 Claude에게 보여 주고 값을 JSON으로 받아오는 함수.
//  - kind = "expense" (기본): 법인카드 영수증 → 가게명·날짜·금액·카드 끝자리
//  - kind = "staff_purchase": 우리 매장 POS 영수증(직원 구매) → 날짜·정가 합계·할인·낸 금액·결제 방식·매장·산 것
// 배포: Supabase 대시보드 -> Edge Functions -> Deploy a new function -> Via Editor -> 이름 read-receipt -> 이 파일 내용 붙여넣기 -> Deploy
//       (이미 배포돼 있으면 함수 열기 -> Code -> 내용 바꿔 넣고 Deploy 한 번 더)
// 비밀값(Secrets): ANTHROPIC_API_KEY (필수), APP_KEY (선택: 앱의 publishable 키를 넣으면 그 키를 가진 앱만 호출 가능)
// 설정: 함수 상세 -> "Verify JWT" 끄기 (앱이 publishable 키를 쓰기 때문)
import Anthropic from "npm:@anthropic-ai/sdk";

const MODEL = Deno.env.get("CLAUDE_MODEL") || "claude-haiku-4-5";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const PROMPT_EXPENSE = [
  "이 사진은 한국의 법인카드 영수증(또는 카드 결제 승인 문자·결제 화면)입니다.",
  "아래 형식의 JSON 하나만 출력하세요. 설명이나 코드 표시는 붙이지 마세요.",
  "{",
  '  "merchant": "가게 이름(상호). 모르면 null",',
  '  "spent_on": "결제 날짜 YYYY-MM-DD. 모르면 null",',
  '  "amount": 최종 결제(합계) 금액을 정수(원)로. 부가세 포함 총액. 모르면 null,',
  '  "card_last4": "카드번호 마지막 4자리(숫자 4개 문자열). 카드번호가 안 보이면 null",',
  '  "summary": "무엇을 샀는지 20자 이내 요약. 모르면 null",',
  '  "confidence": 0에서 1 사이 숫자. 사진이 흐리거나 값이 애매하면 낮게',
  "}",
].join("\n");
const PROMPT_STAFF = [
  "이 사진은 한국 빵집(본노엘) 매장 POS에서 나온 영수증입니다. 직원이 직원 할인을 받아 산 것입니다.",
  "영수증에는 보통 '합계'(할인 전 정가 합), '할인금액', '받을금액'/'받은금액'(실제 낸 돈), '결제수단별 결제내역'(신용카드/현금 등) 줄이 있습니다.",
  "손글씨로 적힌 매장명·이름은 무시하세요. 아래 형식의 JSON 하나만 출력하세요. 설명이나 코드 표시는 붙이지 마세요.",
  "{",
  '  "bought_on": "영수증 날짜 YYYY-MM-DD. 모르면 null",',
  '  "list_total": 할인 전 정가 합계(\'합계\' 줄)를 정수(원)로. 모르면 null,',
  '  "discount": 할인 금액(\'할인금액\' 줄)을 정수(원)로. 할인이 없으면 0. 모르면 null,',
  '  "paid": 실제 낸 금액(\'받은금액\' 또는 결제 금액)을 정수(원)로. 모르면 null,',
  '  "pay_method": "결제 수단. 신용카드·체크카드면 \\"카드\\", 현금이면 \\"현금\\", 그 외엔 영수증에 적힌 대로(계좌이체, 카카오페이, 서울페이, 온누리). 모르면 null",',
  '  "cash_receipt": 현금영수증을 발행한 표시가 있으면 true, 없으면 false,',
  '  "branch": "영수증 맨 위에 인쇄된 매장 이름(예: 중계점). 모르면 null",',
  '  "items": "산 상품명과 수량 요약 30자 이내 (예: 버터프레첼 1개, 소금빵 2개). 모르면 null",',
  '  "confidence": 0에서 1 사이 숫자. 사진이 흐리거나 값이 애매하면 낮게',
  "}",
].join("\n");

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
function toInt(v: unknown): number | null {
  if (v == null) return null;
  const n = parseInt(String(v).replace(/[^\d-]/g, ""), 10);
  return isNaN(n) ? null : n;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST로 보내 주세요" }, 405);

  const appKey = Deno.env.get("APP_KEY");
  if (appKey) {
    const got = req.headers.get("apikey") || (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (got !== appKey) return json({ error: "허용되지 않은 호출이에요" }, 401);
  }
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ error: "ANTHROPIC_API_KEY 비밀값이 아직 없어요 (Edge Functions → Secrets)" }, 500);

  let body: { image_base64?: string; media_type?: string; kind?: string };
  try { body = await req.json(); } catch { return json({ error: "요청 내용을 읽을 수 없어요" }, 400); }
  const data = (body.image_base64 || "").replace(/\s/g, "");
  const mediaType = (body.media_type || "image/jpeg") as "image/jpeg" | "image/png" | "image/webp";
  const kind = body.kind === "staff_purchase" ? "staff_purchase" : "expense";
  if (!data) return json({ error: "사진이 없어요" }, 400);
  if (data.length > 6_000_000) return json({ error: "사진이 너무 커요 (앱에서 줄여서 보내야 해요)" }, 413);

  const client = new Anthropic({ apiKey });
  let text = "";
  try {
    const res = await client.messages.create({
      model: MODEL,
      max_tokens: 512,
      messages: [{
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: mediaType, data } },
          { type: "text", text: kind === "staff_purchase" ? PROMPT_STAFF : PROMPT_EXPENSE },
        ],
      }],
    });
    for (const block of res.content) if (block.type === "text") text += block.text;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return json({ error: "Claude 호출 실패: " + msg }, 502);
  }

  const cleaned = text.replace(/```json|```/g, "").trim();
  const start = cleaned.indexOf("{"), end = cleaned.lastIndexOf("}");
  try {
    const parsed = JSON.parse(cleaned.slice(start, end + 1));
    const dateOk = (v: unknown) => v != null && /^\d{4}-\d{2}-\d{2}$/.test(String(v)) ? String(v) : null;
    if (kind === "staff_purchase") {
      parsed.bought_on = dateOk(parsed.bought_on);
      parsed.list_total = toInt(parsed.list_total);
      parsed.discount = toInt(parsed.discount);
      parsed.paid = toInt(parsed.paid);
      parsed.cash_receipt = parsed.cash_receipt === true;
      // 셋 중 둘만 읽혔으면 나머지는 계산
      if (parsed.list_total != null && parsed.discount != null && parsed.paid == null) parsed.paid = parsed.list_total - parsed.discount;
      if (parsed.list_total != null && parsed.paid != null && parsed.discount == null) parsed.discount = parsed.list_total - parsed.paid;
      if (parsed.discount != null && parsed.paid != null && parsed.list_total == null) parsed.list_total = parsed.discount + parsed.paid;
    } else {
      if (parsed.card_last4 != null) { const m = String(parsed.card_last4).match(/\d{4}/); parsed.card_last4 = m ? m[0] : null; }
      parsed.amount = toInt(parsed.amount);
      parsed.spent_on = dateOk(parsed.spent_on);
    }
    return json({ ok: true, model: MODEL, kind, ...parsed });
  } catch {
    return json({ error: "읽은 내용을 해석하지 못했어요", raw: text }, 502);
  }
});
