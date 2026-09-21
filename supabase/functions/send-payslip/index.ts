// 급여명세서를 직원 메일로 보내고, 보낸 기록을 ops_pay_runs에 남기는 함수.
// 배포: Supabase 대시보드 -> Edge Functions -> Deploy a new function -> Via Editor -> 이름 send-payslip -> 이 파일 내용 붙여넣기 -> Deploy
// 설정: 함수 상세 -> "Verify JWT" 끄기 (앱이 publishable 키를 쓰기 때문)
// 비밀값(Secrets)은 send-document와 동일한 것을 그대로 씀 (새로 설정할 것 없음):
//   GMAIL_USER, GMAIL_APP_PASSWORD ← 기본 발송 방식
//   APP_KEY (선택), MAIL_PROVIDER=resend + RESEND_API_KEY + MAIL_FROM (선택, 대안)
// SUPABASE_URL / SUPABASE_ANON_KEY 는 Supabase가 자동으로 넣어 줌
import { createClient } from "npm:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
// 메일 제목의 한글을 RFC 2047 base64 조각으로 인코딩한다 (send-document와 같은 이유: denomailer가 긴 한글 제목을 깨뜨림).
function encodeSubject(s: string): string {
  if (!/[^\x20-\x7e]/.test(s)) return s;
  const enc = new TextEncoder();
  const words: string[] = [];
  let cur = "";
  for (const ch of s) {
    if (enc.encode(cur + ch).length > 42) { words.push(cur); cur = ch; } else cur += ch;
  }
  if (cur) words.push(cur);
  return " " + words.map((w) => `=?UTF-8?B?${btoa(String.fromCharCode(...enc.encode(w)))}?=`).join(" ");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST로 보내 주세요" }, 405);

  const appKey = Deno.env.get("APP_KEY");
  if (appKey) {
    const got = req.headers.get("apikey") || (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (got !== appKey) return json({ error: "허용되지 않은 호출이에요" }, 401);
  }

  let body: { run_id?: string; to?: string; subject?: string; html?: string };
  try { body = await req.json(); } catch { return json({ error: "요청 내용을 읽을 수 없어요" }, 400); }
  const runId = String(body.run_id || "");
  const to = String(body.to || "").trim();
  const subject = String(body.subject || "").slice(0, 200);
  const html = String(body.html || "");

  if (!/^[0-9a-f-]{36}$/i.test(runId)) return json({ error: "run_id가 없어요" }, 400);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return json({ error: "이메일 주소가 올바르지 않아요: " + to }, 400);
  if (!subject || !html) return json({ error: "제목·내용이 비어있어요" }, 400);
  if (html.length > 200000) return json({ error: "명세서 내용이 너무 커요" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data: run, error: e1 } = await sb.from("ops_pay_runs").select("id").eq("id", runId).maybeSingle();
  if (e1) return json({ error: "급여 기록을 읽지 못했어요: " + e1.message }, 500);
  if (!run) return json({ error: "급여 기록을 찾을 수 없어요" }, 404);

  try {
    const provider = (Deno.env.get("MAIL_PROVIDER") || "gmail").toLowerCase();
    if (provider === "resend") {
      const key = Deno.env.get("RESEND_API_KEY");
      const from = Deno.env.get("MAIL_FROM");
      if (!key || !from) throw new Error("RESEND_API_KEY / MAIL_FROM 비밀값이 없어요");
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: "Bearer " + key, "Content-Type": "application/json" },
        body: JSON.stringify({ from, to: [to], subject, html }),
      });
      if (!res.ok) throw new Error("Resend 응답 " + res.status + ": " + (await res.text()).slice(0, 200));
    } else {
      const user = Deno.env.get("GMAIL_USER");
      const pass = Deno.env.get("GMAIL_APP_PASSWORD");
      if (!user || !pass) throw new Error("GMAIL_USER / GMAIL_APP_PASSWORD 비밀값이 아직 없어요 (Edge Functions → Secrets)");
      const client = new SMTPClient({ connection: { hostname: "smtp.gmail.com", port: 465, tls: true, auth: { username: user, password: pass } } });
      try {
        await client.send({ from: `본노엘 <${user}>`, to, subject: encodeSubject(subject), content: "명세서는 HTML로 첨부되어 있어요.", html });
      } finally {
        try { await client.close(); } catch (_) { /* 이미 닫혔으면 무시 */ }
      }
    }
  } catch (e) {
    const msg = String((e as Error).message || e);
    await sb.from("ops_pay_runs").update({ email_error: msg.slice(0, 500) }).eq("id", runId);
    return json({ error: msg }, 500);
  }

  const now = new Date().toISOString();
  const { error: e2 } = await sb.from("ops_pay_runs").update({ email_to: to, email_sent_at: now, email_error: null }).eq("id", runId);
  if (e2) return json({ ok: true, sent_to: to, warn: "메일은 갔지만 기록 저장에 실패: " + e2.message });
  return json({ ok: true, sent_to: to });
});
