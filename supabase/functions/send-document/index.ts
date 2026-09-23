// 서명이 끝난 입사 서류(PDF)를 직원 메일 + 사장님 메일(참조)로 보내고, 보낸 기록을 ops_documents에 남기는 함수.
// 배포: Supabase 대시보드 -> Edge Functions -> Deploy a new function -> Via Editor -> 이름 send-document -> 이 파일 내용 붙여넣기 -> Deploy
// 설정: 함수 상세 -> "Verify JWT" 끄기 (앱이 publishable 키를 쓰기 때문)
// 비밀값(Secrets):
//   GMAIL_USER (예: bonnoel.news@gmail.com), GMAIL_APP_PASSWORD (지메일 앱 비밀번호 16자리)  ← 기본 발송 방식
//   OWNER_EMAIL (사장님 사본 주소. 앱의 ops_settings docs.owner_email 이 있으면 그걸 먼저 씀)
//   APP_KEY (선택: 앱의 publishable 키를 넣으면 그 키를 가진 앱만 호출 가능)
//   MAIL_PROVIDER=resend + RESEND_API_KEY + MAIL_FROM (선택: 지메일 SMTP가 막힐 때 대안. 도메인 인증 필요)
// SUPABASE_URL / SUPABASE_ANON_KEY 는 Supabase가 자동으로 넣어 줌 (버킷·표는 anon 정책으로 접근 가능)
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
function b64(bytes: Uint8Array): string {
  let s = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) s += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(s);
}
function esc(s: unknown): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));
}
// denomailer(1.6.0)의 본문 quoted-printable 인코더에 실제 버그가 있다: 74자 줄바꿈이 한글 등 멀티바이트 글자의 escape
// 시퀀스 한가운데를 자르면서, 그 잘린 조각이 하필 마지막 줄에서 발생하면 글자 일부가 통째로 사라진다(메일 본문에 깨진 글자로 나타남).
// mimeContent를 직접 만들어 넘기면 denomailer가 자체 인코딩을 하지 않으므로, 이 문제가 없는 base64로 대신 인코딩한다.
function mimeTextPart(text: string, mimeType: string) {
  const b = b64(new TextEncoder().encode(text));
  const lines: string[] = [];
  for (let i = 0; i < b.length; i += 76) lines.push(b.slice(i, i + 76));
  return { mimeType: `${mimeType}; charset="utf-8"`, content: lines.join("\r\n"), transferEncoding: "base64" };
}
// 메일 제목의 한글을 RFC 2047 base64 조각(각 75자 이하)으로 직접 인코딩한다.
// denomailer가 한글 제목을 quoted-printable로 바꾸면서 74자마다 줄을 접어 헤더가 깨지기 때문.
// 앞에 공백 하나를 두면 라이브러리가 "이미 인코딩된 것"으로 다시 감싸지 않고 그대로 보낸다.
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
// 첨부파일 이름은 영문만 (라이브러리가 파일명을 따옴표 없이 써서 한글·공백이 깨짐)
const FILE_NAMES: Record<string, string> = { contract: "1_contract", privacy: "2_privacy_consent", pledge: "3_pledge", cctv: "4_cctv_consent", uniform: "5_uniform", guardian: "6_guardian_consent" };
function kst(d = new Date()): string {
  const t = new Date(d.getTime() + 9 * 3600 * 1000);
  return t.toISOString().slice(0, 16).replace("T", " ");
}

type Row = { id: string; batch_id: string; staff_id: string; doc_key: string; doc_title: string; status: string; pdf_path: string | null; email_to: string | null; signed_at: string | null; data: Record<string, unknown> };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST로 보내 주세요" }, 405);

  const appKey = Deno.env.get("APP_KEY");
  if (appKey) {
    const got = req.headers.get("apikey") || (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    if (got !== appKey) return json({ error: "허용되지 않은 호출이에요" }, 401);
  }

  let body: { batch_id?: string; ua?: string };
  try { body = await req.json(); } catch { return json({ error: "요청 내용을 읽을 수 없어요" }, 400); }
  const batchId = String(body.batch_id || "");
  if (!/^[0-9a-f-]{36}$/i.test(batchId)) return json({ error: "batch_id가 없어요" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data: rows, error: e1 } = await sb.from("ops_documents").select("*").eq("batch_id", batchId).order("created_at");
  if (e1) return json({ error: "서류를 읽지 못했어요: " + e1.message }, 500);
  const docs = (rows || []) as Row[];
  const sendable = docs.filter((r) => r.pdf_path && ["signed", "failed", "sent"].includes(r.status));
  if (!sendable.length) return json({ error: "보낼 서류가 없어요 (아직 서명 전이거나 PDF가 없어요)" }, 404);

  const to = (sendable.find((r) => r.email_to)?.email_to || "").trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return json({ error: "직원 이메일 주소가 올바르지 않아요: " + to }, 400);

  const { data: staff } = await sb.from("manual_staff").select("name").eq("id", sendable[0].staff_id).single();
  const { data: setting } = await sb.from("ops_settings").select("value").eq("key", "docs").maybeSingle();
  const cc = String((setting?.value as Record<string, unknown> | null)?.owner_email || Deno.env.get("OWNER_EMAIL") || "").trim();
  const staffName = staff?.name || "근로자";
  const ip = (req.headers.get("x-forwarded-for") || req.headers.get("cf-connecting-ip") || "").split(",")[0].trim() || null;
  const ua = String(body.ua || req.headers.get("user-agent") || "").slice(0, 300) || null;

  const dateK = kst().slice(0, 10);
  // PDF 내려받기
  const attachments: { filename: string; content: string; contentType: string; encoding: "base64" }[] = [];
  for (const r of sendable) {
    const { data: file, error } = await sb.storage.from("documents").download(r.pdf_path!);
    if (error || !file) return await fail(sb, sendable, "PDF를 내려받지 못했어요: " + (error?.message || r.pdf_path));
    const bytes = new Uint8Array(await file.arrayBuffer());
    attachments.push({ filename: `bonnoel_${FILE_NAMES[r.doc_key] || r.doc_key}_${dateK}.pdf`, content: b64(bytes), contentType: "application/pdf", encoding: "base64" });
  }

  const subject = `[본노엘] 근로계약서 등 입사 서류 교부 - ${staffName} (${dateK})`;
  const list = sendable.map((r) => `<li>${esc(r.doc_title)}${r.signed_at ? ` <span style="color:#777">(서명 ${kst(new Date(r.signed_at))})</span>` : ""}</li>`).join("");
  const html = `<div style="font-family:'Apple SD Gothic Neo','Malgun Gothic',sans-serif;font-size:15px;line-height:1.6;color:#222;max-width:560px">
<p><b>${esc(staffName)}</b> 님, 안녕하세요. 주식회사 본노엘입니다.</p>
<p>오늘 전자서명하신 아래 서류를 PDF로 첨부해 드립니다. 이 메일은 근로기준법 제17조 제2항에 따른 근로계약서의 서면(전자문서) 교부입니다. 파일을 잘 보관해 주세요.</p>
<ul>${list}</ul>
<p style="font-size:13px;color:#666">서명 일시: ${esc(kst())} (한국 시간) · 문서 묶음 번호: ${esc(batchId.slice(0, 8))}<br>
내용에 궁금한 점이 있으면 매장 매니저나 대표(${esc(cc || "본노엘")})에게 말씀해 주세요.</p>
<p style="font-size:13px;color:#666">주식회사 본노엘 · 서울시 동대문구 전농로75-18 · 대표 손성필</p>
</div>`;
  const text = `${staffName} 님, 주식회사 본노엘입니다. 오늘 전자서명하신 입사 서류를 PDF로 첨부해 드립니다 (근로기준법 제17조에 따른 서면 교부). 서류: ${sendable.map((r) => r.doc_title).join(", ")}`;

  try {
    const provider = (Deno.env.get("MAIL_PROVIDER") || "gmail").toLowerCase();
    if (provider === "resend") {
      const key = Deno.env.get("RESEND_API_KEY");
      const from = Deno.env.get("MAIL_FROM");
      if (!key || !from) throw new Error("RESEND_API_KEY / MAIL_FROM 비밀값이 없어요");
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: "Bearer " + key, "Content-Type": "application/json" },
        body: JSON.stringify({ from, to: [to], cc: cc ? [cc] : undefined, subject, html, text, attachments: attachments.map((a) => ({ filename: a.filename, content: a.content })) }),
      });
      if (!res.ok) throw new Error("Resend 응답 " + res.status + ": " + (await res.text()).slice(0, 200));
    } else {
      const user = Deno.env.get("GMAIL_USER");
      const pass = Deno.env.get("GMAIL_APP_PASSWORD");
      if (!user || !pass) throw new Error("GMAIL_USER / GMAIL_APP_PASSWORD 비밀값이 아직 없어요 (Edge Functions → Secrets)");
      const client = new SMTPClient({ connection: { hostname: "smtp.gmail.com", port: 465, tls: true, auth: { username: user, password: pass } } });
      try {
        await client.send({ from: `본노엘 <${user}>`, to, cc: cc || undefined, subject: encodeSubject(subject), mimeContent: [mimeTextPart(text, "text/plain"), mimeTextPart(html, "text/html")], attachments });
      } finally {
        try { await client.close(); } catch (_) { /* 이미 닫혔으면 무시 */ }
      }
    }
  } catch (e) {
    return await fail(sb, sendable, String((e as Error).message || e));
  }

  const now = new Date().toISOString();
  const patch = { status: "sent", email_to: to, email_cc: cc || null, email_sent_at: now, email_error: null, signed_ip: ip, signed_ua: ua, updated_at: now };
  const { error: e2 } = await sb.from("ops_documents").update(patch).eq("batch_id", batchId).in("id", sendable.map((r) => r.id));
  if (e2) return json({ ok: true, sent_to: to, cc, warn: "메일은 갔지만 기록 저장에 실패: " + e2.message });
  return json({ ok: true, sent_to: to, cc, count: sendable.length });
});

async function fail(sb: ReturnType<typeof createClient>, rows: Row[], msg: string) {
  const now = new Date().toISOString();
  await sb.from("ops_documents").update({ status: "failed", email_error: msg.slice(0, 500), updated_at: now }).in("id", rows.map((r) => r.id));
  return json({ error: msg }, 500);
}
