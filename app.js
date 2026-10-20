// ================== SETUP ==================
const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
const $ = (id) => document.getElementById(id);
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const manila = (t) => t ? new Date(t).toLocaleString("en-PH", { timeZone: "Asia/Manila" }) : "-";

let me = null;
let programs = [], terms = [];
let allSubs = [], allScholars = [], allLog = [];

function say(text, bad = false) {
  const m = $("msg");
  m.textContent = text;
  m.className = "msg " + (bad ? "bad" : "good");
  clearTimeout(say.t);
  say.t = setTimeout(() => (m.className = "msg hidden"), 5000);
}

// ================== BADGES ==================
const badge = (text, kind) => `<span class="badge ${kind}">${esc(text)}</span>`;
function verifyBadge(s) {
  if (s.verify_status === "verified") return badge("Verified", "good");
  if (s.verify_status === "rejected") return badge("Wrong - fix it", "bad");
  return badge("Waiting", "wait");
}
function ruleBadge(s) {
  if (s.compliance === "compliant") return badge("Compliant", "good");
  if (s.compliance === "deficient") return badge("With Deficiency", "bad");
  return s.verify_status === "verified" ? badge("Not checked yet", "wait") : badge("Blocked", "grey");
}
function decisionBadge(s) {
  if (s.decision === "approved") return badge("Approved", "good");
  if (s.decision === "held") return badge("Held", "bad");
  return badge("No decision", "grey");
}

// ================== LOGIN / LOGOUT ==================
$("loginBtn").onclick = async () => {
  const { error } = await db.auth.signInWithPassword({
    email: $("email").value.trim(),
    password: $("password").value,
  });
  if (error) return say(error.message, true);
  start();
};
$("password").addEventListener("keydown", (e) => { if (e.key === "Enter") $("loginBtn").click(); });
$("logoutBtn").onclick = async () => { await db.auth.signOut(); location.reload(); };

async function start() {
  const { data: { session } } = await db.auth.getSession();
  if (!session) {
    $("loginView").classList.remove("hidden");
    $("appView").classList.add("hidden");
    return;
  }
  const { data, error } = await db.from("profiles").select("*, programs(*)").eq("id", session.user.id).single();
  if (error) { say("No profile for this login.", true); await db.auth.signOut(); return; }
  me = data;

  const [p, t] = await Promise.all([
    db.from("programs").select("*").order("name"),
    db.from("terms").select("*").order("deadline"),
  ]);
  programs = p.data || [];
  terms = t.data || [];

  $("loginView").classList.add("hidden");
  $("appView").classList.remove("hidden");
  $("who").textContent = me.full_name;
  $("roleTag").textContent = me.role;

  if (me.role === "staff") {
    $("staffView").classList.remove("hidden");
    $("scholarView").classList.add("hidden");
    loadStaff();
  } else {
    $("scholarView").classList.remove("hidden");
    $("staffView").classList.add("hidden");
    loadScholar();
  }
}

// ================== SCHOLAR ==================
async function loadScholar() {
  const pr = me.programs;
  $("myRules").innerHTML = pr
    ? `<p><b>${esc(pr.name)}</b></p>
       <ul>
         <li>Best GWA allowed: ${pr.max_gwa}</li>
         <li>Min units: ${pr.min_units}</li>
         <li>Max failed: ${pr.max_failed}</li>
         <li>Max incomplete: ${pr.max_inc}</li>
         <li>Max dropped: ${pr.max_dropped}</li>
       </ul>`
    : `<p>Staff has not picked your scholarship yet. You cannot submit until they do.</p>`;

  $("term").innerHTML = terms
    .map((t) => `<option value="${t.id}">${esc(t.label)} (deadline ${manila(t.deadline)})</option>`)
    .join("");

  const [s, h] = await Promise.all([
    db.from("submissions").select("*, terms(label, deadline)").order("submitted_at", { ascending: false }),
    db.from("audit_log").select("*").order("created_at", { ascending: false }),
  ]);
  const subs = s.data || [];

  $("mySubs").innerHTML = subs.length
    ? `<table>
        <tr><th>Semester</th><th>GWA</th><th>Units</th><th>F / INC / D</th><th>Submitted</th>
            <th>Proof check</th><th>Rules</th><th>Decision</th><th>Notes</th></tr>
        ${subs.map((x) => `<tr>
          <td>${esc(x.terms?.label)}</td>
          <td>${x.gwa}</td><td>${x.units}</td>
          <td>${x.failed} / ${x.inc} / ${x.dropped}</td>
          <td>${manila(x.submitted_at)}${x.is_late ? " " + badge("Late", "bad") : ""}</td>
          <td>${verifyBadge(x)}</td>
          <td>${ruleBadge(x)}</td>
          <td>${decisionBadge(x)}</td>
          <td>
            ${x.verify_note ? `<div>Staff note: ${esc(x.verify_note)}</div>` : ""}
            ${x.reasons ? `<div><b>Why deficient:</b> ${esc(x.reasons)}</div>` : ""}
            ${x.decision_note ? `<div>Decision note: ${esc(x.decision_note)}</div>` : ""}
            ${x.verify_status === "rejected" ? `<div class="small">Fix it and submit again above.</div>` : ""}
          </td></tr>`).join("")}
       </table>`
    : "<p>Nothing submitted yet.</p>";

  $("myHistory").innerHTML = logTable(h.data || [], false);
}

$("submitBtn").onclick = async () => {
  const file = $("proof").files[0];
  const gwa = parseFloat($("gwa").value);
  const units = parseInt($("units").value, 10);
  const failed = parseInt($("failed").value, 10);
  const inc = parseInt($("inc").value, 10);
  const dropped = parseInt($("dropped").value, 10);

  if ([gwa, units, failed, inc, dropped].some(Number.isNaN)) return say("Fill in all number boxes.", true);
  if (!file) return say("Attach your proof.", true);

  $("submitBtn").disabled = true;
  const path = `${me.id}/${Date.now()}_${file.name.replace(/[^\w.\-]/g, "_")}`;
  const up = await db.storage.from("proofs").upload(path, file);
  if (up.error) { $("submitBtn").disabled = false; return say(up.error.message, true); }

  const { error } = await db.rpc("submit_grades", {
    p_term: $("term").value, p_gwa: gwa, p_units: units,
    p_failed: failed, p_inc: inc, p_dropped: dropped, p_proof: path,
  });
  $("submitBtn").disabled = false;
  if (error) return say(error.message, true);

  say("Submitted! Waiting for staff to verify.");
  $("proof").value = "";
  loadScholar();
};

// ================== STAFF ==================
async function loadStaff() {
  const [sc, su, lg] = await Promise.all([
    db.from("profiles").select("*, programs(name)").eq("role", "scholar").order("student_no"),
    db.from("submissions")
      .select("*, terms(label), programs(name), profiles:scholar_id(full_name, student_no)")
      .order("submitted_at", { ascending: false }),
    db.from("audit_log")
      .select("*, profiles:scholar_id(full_name, student_no)")
      .order("created_at", { ascending: false }).limit(300),
  ]);
  allScholars = sc.data || [];
  allSubs = su.data || [];
  allLog = lg.data || [];
  renderStaff();
}

function renderStaff() {
  const q = $("search").value.trim().toLowerCase();
  const hit = (name, no) => !q || (name || "").toLowerCase().includes(q) || (no || "").toLowerCase().includes(q);

  // Dashboard big numbers
  const waiting = allSubs.filter((s) => s.verify_status === "pending").length;
  const good = allSubs.filter((s) => s.compliance === "compliant").length;
  const bad = allSubs.filter((s) => s.compliance === "deficient").length;
  $("stats").innerHTML = [
    ["Scholars", allScholars.length],
    ["Waiting", waiting],
    ["Compliant", good],
    ["With Deficiency", bad],
  ].map(([label, n]) => `<div class="stat"><b>${n}</b>${label}</div>`).join("");

  // Submissions tab
  const subs = allSubs.filter((s) => hit(s.profiles?.full_name, s.profiles?.student_no));
  $("tab-subs").innerHTML = subs.length
    ? `<table>
        <tr><th>Student</th><th>Program</th><th>Semester</th><th>GWA</th><th>Units</th>
            <th>F / INC / D</th><th>Submitted</th><th>Proof check</th><th>Rules</th>
            <th>Decision</th><th>Actions</th></tr>
        ${subs.map((s) => `<tr>
          <td>${esc(s.profiles?.full_name)}<div class="small">${esc(s.profiles?.student_no)}</div></td>
          <td>${esc(s.programs?.name)}</td>
          <td>${esc(s.terms?.label)}</td>
          <td>${s.gwa}</td><td>${s.units}</td>
          <td>${s.failed} / ${s.inc} / ${s.dropped}</td>
          <td>${manila(s.submitted_at)}${s.is_late ? " " + badge("Late", "bad") : ""}</td>
          <td>${verifyBadge(s)}${s.verify_note ? `<div class="small">${esc(s.verify_note)}</div>` : ""}</td>
          <td>${ruleBadge(s)}${s.reasons ? `<div class="small">${esc(s.reasons)}</div>` : ""}</td>
          <td>${decisionBadge(s)}${s.decision_note ? `<div class="small">${esc(s.decision_note)}</div>` : ""}</td>
          <td>${actionButtons(s)}</td></tr>`).join("")}
       </table>`
    : "<p>No submissions found.</p>";

  // Assign tab
  const sch = allScholars.filter((s) => hit(s.full_name, s.student_no));
  $("tab-scholars").innerHTML = `<table>
      <tr><th>ID</th><th>Name</th><th>Scholarship</th><th></th></tr>
      ${sch.map((s) => `<tr>
        <td>${esc(s.student_no)}</td><td>${esc(s.full_name)}</td>
        <td><select id="prog-${s.id}">
          <option value="">-- pick one --</option>
          ${programs.map((p) => `<option value="${p.id}" ${p.id === s.program_id ? "selected" : ""}>${esc(p.name)}</option>`).join("")}
        </select></td>
        <td><button onclick="assignProgram('${s.id}')">Save</button></td></tr>`).join("")}
    </table>`;

  // History tab
  const log = allLog.filter((l) => hit(l.profiles?.full_name, l.profiles?.student_no));
  $("tab-history").innerHTML = logTable(log, true);
}

function actionButtons(s) {
  let b = "";
  if (s.proof_path) b += `<button class="ghost" onclick="viewProof('${esc(s.proof_path)}')">View proof</button>`;
  if (s.verify_status === "pending") {
    b += `<button class="ok" onclick="verify('${s.id}', true)">Verified</button>`;
    b += `<button class="no" onclick="verify('${s.id}', false)">Wrong, fix it</button>`;
  }
  if (s.verify_status === "verified") {
    b += `<button onclick="checkRules('${s.id}')">${s.compliance === "not_checked" ? "Check rules" : "Re-check"}</button>`;
  }
  if (s.compliance !== "not_checked") {
    const cant = s.compliance === "deficient";
    b += `<button class="ok" ${cant ? "disabled title='Cannot approve: deficient'" : ""} onclick="decide('${s.id}', 'approved')">Approve</button>`;
    b += `<button class="warn" onclick="decide('${s.id}', 'held')">Hold</button>`;
  }
  return b;
}

function logTable(rows, showStudent) {
  if (!rows.length) return "<p>No history yet.</p>";
  return `<table>
    <tr><th>When (Manila)</th><th>Who did it</th><th>What</th>${showStudent ? "<th>Student</th>" : ""}<th>Note</th></tr>
    ${rows.map((l) => `<tr>
      <td>${manila(l.created_at)}</td><td>${esc(l.actor_name)}</td><td>${esc(l.action)}</td>
      ${showStudent ? `<td>${esc(l.profiles?.full_name)} <span class="small">${esc(l.profiles?.student_no)}</span></td>` : ""}
      <td>${esc(l.note)}</td></tr>`).join("")}
  </table>`;
}

// ---------- staff actions (each one calls a database function) ----------
async function callDb(fn, args, okText) {
  const { error } = await db.rpc(fn, args);
  if (error) return say(error.message, true);
  say(okText);
  loadStaff();
}

async function viewProof(path) {
  const { data, error } = await db.storage.from("proofs").createSignedUrl(path, 120);
  if (error) return say(error.message, true);
  window.open(data.signedUrl, "_blank");
}

function verify(id, ok) {
  const note = prompt(ok ? "Note (optional):" : "What is wrong? (required)");
  if (note === null) return;
  callDb("verify_submission", { p_id: id, p_ok: ok, p_note: note }, ok ? "Marked verified." : "Sent back to scholar.");
}
function checkRules(id) { callDb("check_rules", { p_id: id }, "Rules checked."); }
function decide(id, decision) {
  const note = prompt("Note (optional):");
  if (note === null) return;
  callDb("set_decision", { p_id: id, p_decision: decision, p_note: note }, "Decision saved: " + decision);
}
function assignProgram(scholarId) {
  const val = $("prog-" + scholarId).value;
  if (!val) return say("Pick a scholarship first.", true);
  callDb("assign_program", { p_scholar: scholarId, p_program: val }, "Scholarship assigned.");
}

// ---------- tabs + search ----------
document.querySelectorAll(".tab").forEach((btn) => {
  btn.onclick = () => {
    document.querySelectorAll(".tab").forEach((b) => b.classList.remove("active"));
    btn.classList.add("active");
    ["subs", "scholars", "history"].forEach((t) =>
      $("tab-" + t).classList.toggle("hidden", t !== btn.dataset.tab));
  };
});
$("search").addEventListener("input", renderStaff);

// ================== GO ==================
start();
