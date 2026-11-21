// Shared Instantly mail helpers (11-21). An exact copy of ops-sync/index.ts (AUTO, HUMAN, YES, bodyOf, snippet,
// fullText) so instantly-webhook classifies a reply exactly like the 10-min sync. ops-sync still has its own copy;
// switching it to import this file is Simas's side's call (keeps one source of truth for the rules).
export const AUTO = /out of (the )?office|\bOOO\b|on (vacation|holiday|leave|maternity)|auto(matic)?[- ]?reply|thank(s| you)( so much| very much)? for (your (email|message|e-mail|inquiry|enquiry|note)|reaching|getting|emailing|contacting)|your (message|email) has been (received|forwarded)|you will receive a (response|reply)|vielen dank f|(reply|respond|get back)[^.]{0,40}(upon|on|after) my return|away at a conference|reply above this line|your request (\(#?\d+\) )?has been received|we strive to respond within|limited access to (my )?e-?mails?|for (the )?fastest (assistance|response)|we (aim to )?(respond|reply) to (all )?e-?mails? within|in the meantime, here are|view (this email )?in (your )?browser|unsubscribe/i;
export const HUMAN = /sorry for the (late|delayed|slow) (reply|response)|\bi was (out|away|travell?ing)\b|\b(adding|looping in|cc'?ing|copying in)\b|\bi'?ve (now )?(reviewed|watched|looked)|\b(aren'?t|are not|am not|i'?m not|not) (currently )?(looking for|interested)|\bno,? thank(s| you)\b|\b(just|i'?ve|we'?ve|i|we) (just )?paid\b|looking forward to working (together|with)/i;
export const YES = /\b(yes|yeah|sure|interested|go ahead|send it|please do|sounds good|let'?s do|i'?d (like|love|be happy)|take you up on)\b/i;
export const bodyOf = (e: any) => e.body?.text || e.content_preview || "";
export function snippet(t: string) {
  if (t.trimStart().startsWith(">")) t = t.replace(/^>\s?/gm, "");
  return t.split(/\n\s*On .{5,80}wrote:|\n>/)[0].replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").slice(0, 160);
}

// The whole message as readable text (SIMAS 11-12: whole conversations in the CRM). Mirrors replies.full_text in the Dashboard repo.
export function fullText(e: any): string {
  let h: string = e.body?.html || "", t: string = e.body?.text || e.content_preview || "";
  if (h) {
    h = h.replace(/<blockquote\b[\s\S]*|<div[^>]*class="?gmail_quote[\s\S]*|<div[^>]*id="?(?:divRplyFwdMsg|appendonsend)[\s\S]*/i, "")
      .replace(/<(style|script|head)\b[\s\S]*?<\/\1>/gi, "")
      .replace(/<br\s*\/?>|<\/(?:p|div|li|tr|h[1-6])>/gi, "\n")
      .replace(/<a\b[^>]*href="(https?:\/\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/gi, (_m: string, u: string, x: string) => x.includes(u.replace(/\/$/, "")) ? x : `${x} (${u})`)
      .replace(/<[^>]+>/g, "");
    t = h.replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'")
      .replace(/&#(\d+);/g, (_m: string, n: string) => String.fromCodePoint(+n))
      .replace(/&#x([0-9a-f]+);/gi, (_m: string, x: string) => String.fromCodePoint(parseInt(x, 16))).replace(/&amp;/g, "&");
  }
  t = t.replace(/\r/g, "").replace(/ /g, " ");
  if (t.trimStart().startsWith(">")) t = t.replace(/^>\s?/gm, "");
  t = ("\n" + t).split(/\n\s*On .{5,160}?wrote:|\n-{2,}\s*Original Message\s*-{2,}|\nFrom: .{3,120}\n(?:Sent|Date): |\n>/)[0];
  const lines = t.split("\n").map(x => x.replace(/[ \t]+/g, " ").trim()), subj = (e.subject || "").trim().toLowerCase();
  while (lines.length && (!lines[0] || lines[0].toLowerCase() === subj)) lines.shift();
  return lines.join("\n").replace(/\n{3,}/g, "\n\n").trim().slice(0, 12000);
}
