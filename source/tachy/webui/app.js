/* tachy web console — plain ES2020, no framework, no build step.
 *
 * A tiny ad-hoc toolkit (h(), api(), EventSource wiring) plus the
 * application state: projects from /api/state, runs started with
 * POST /api/run, and one Server-Sent-Events stream per run whose
 * records are the tachy event protocol (fileStart / job / fileDone)
 * wrapped with a timestamp, plus "log" and "done" records.
 */
"use strict";

// ---- tiny dom helper ------------------------------------------------------

function h(tag, attrs, ...children) {
  const node = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (k === "class") node.className = v;
      else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
      else if (v === true) node.setAttribute(k, "");
      else if (v !== false && v != null) node.setAttribute(k, String(v));
    }
  }
  add(node, children);
  return node;
}

function add(node, children) {
  for (const c of children) {
    if (c == null || c === false) continue;
    if (Array.isArray(c)) add(node, c);
    else node.append(c.nodeType ? c : document.createTextNode(String(c)));
  }
}

async function api(path, method, body) {
  const res = await fetch(path, {
    method: method || "GET",
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (_) { /* non-JSON */ }
  if (!res.ok) {
    throw new Error((data && data.error) || res.status + " " + res.statusText);
  }
  return data;
}

function fmtTime(ms) {
  const d = new Date(ms || Date.now());
  const p = (n) => String(n).padStart(2, "0");
  return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
}

function basename(path) {
  const i = path.lastIndexOf("/");
  return i >= 0 ? path.slice(i + 1) : path;
}

// ---- state ------------------------------------------------------------------

const state = {
  projects: [],
  hosts: [],
  tags: [],
  inventoryError: "",
  runs: [],
  project: null, // selected project path
  current: null, // open run id
  es: null,      // its EventSource
  view: null,    // { ok, changed, failed, finished, exit }
};

const els = {};
for (const id of ["inventory", "inv-error", "projects", "projects-empty",
  "runbar", "runbar-project", "runbar-kind", "run-form", "selection",
  "btn-check", "btn-apply", "chips", "runs-list", "runs-empty", "runview",
  "run-mode", "run-selection", "run-status", "run-project", "run-started",
  "verbose", "c-ok", "c-changed", "c-failed", "events"])
  els[id] = document.getElementById(id);

// ---- rendering ----------------------------------------------------------------

function renderInventory() {
  if (state.inventoryError) {
    els.inventory.textContent = "inventory error";
    els["inv-error"].textContent = state.inventoryError;
    els["inv-error"].classList.remove("hidden");
  } else {
    els.inventory.textContent =
      state.hosts.length + " host" + (state.hosts.length === 1 ? "" : "s")
      + (state.tags.length ? " — tags: " + state.tags.map(t => "@" + t).join(" ") : "");
    els["inv-error"].classList.add("hidden");
  }
}

function renderProjects() {
  els.projects.textContent = "";
  els["projects-empty"].classList.toggle("hidden", state.projects.length > 0);
  for (const p of state.projects) {
    els.projects.append(h("li", {
      class: (p.path === state.project ? "selected " : "")
        + (p.kind === "missing" ? "missing" : ""),
      onclick: () => { state.project = p.path; renderProjects(); renderRunbar(); },
    },
      h("span", { class: "proj-name" }, p.name),
      p.kind === "missing" ? null : h("span", { class: "proj-kind" },
        p.kind === "directory" ? "dir → main.pravic" : "file"),
      h("span", { class: "proj-path" }, p.path),
    ));
  }
}

function renderRunbar() {
  const p = state.projects.find(p => p.path === state.project);
  els.runbar.classList.toggle("hidden", !p);
  if (!p) return;
  els["runbar-project"].textContent = p.name;
  els["runbar-kind"].textContent = p.path;

  // selection chips: known hosts and tags, lit when part of the selection
  els.chips.textContent = "";
  const parts = selectionParts();
  const chip = (label, value) => h("span", {
    class: "chip" + (parts.includes(value) ? " on" : ""),
    onclick: () => toggleSelection(value),
  }, label);
  for (const host of state.hosts) els.chips.append(chip(host.name, host.name));
  for (const t of state.tags) els.chips.append(chip("@" + t, "@" + t));
}

function selectionParts() {
  return els.selection.value.split(",").map(s => s.trim()).filter(s => s.length);
}

function toggleSelection(value) {
  const parts = selectionParts();
  const i = parts.indexOf(value);
  if (i >= 0) parts.splice(i, 1);
  else parts.push(value);
  els.selection.value = parts.length ? parts.join(",") : "all";
  renderRunbar();
}

function statusClass(status) {
  if (status === "failed") return "failed";
  if (status.startsWith("changed")) return "changed";
  return "ok";
}

function renderRuns() {
  els["runs-list"].textContent = "";
  els["runs-empty"].classList.toggle("hidden", state.runs.length > 0);
  for (const r of state.runs) {
    els["runs-list"].append(h("li", {
      class: r.id === state.current ? "selected" : "",
      onclick: () => openRun(r.id),
    },
      h("span", { class: "r-id" }, r.id),
      h("span", { class: "r-mode " + r.mode }, r.mode),
      h("span", { class: "r-proj" }, basename(r.project)),
      h("span", { class: "r-sel" }, r.selection),
      r.status === "running"
        ? h("span", { class: "r-time" }, "running…")
        : h("span", { class: "r-counts" },
            h("span", { class: "k" }, "ok=" + r.ok), " ",
            h("span", { class: "c" }, "ch=" + r.changed), " ",
            h("span", { class: "f" }, "f=" + r.failed)),
      h("span", { class: "r-time" },
        r.status === "running" ? "—" : "exit " + r.exit),
    ));
  }
}

// ---- the run view ----------------------------------------------------------------

function nearBottom() {
  return window.innerHeight + window.scrollY >= document.body.scrollHeight - 80;
}

const maxRows = 5000;

function appendRow(row) {
  const follow = nearBottom();
  els.events.append(row);
  while (els.events.children.length > maxRows)
    els.events.removeChild(els.events.firstChild);
  if (follow) window.scrollTo(0, document.body.scrollHeight);
}

function resetView(r) {
  state.view = { ok: 0, changed: 0, failed: 0, finished: false, exit: null };
  els.events.textContent = "";
  els["run-mode"].textContent = r.mode;
  els["run-mode"].className = "badge mode-" + r.mode;
  els["run-selection"].textContent = r.selection;
  els["run-project"].textContent = r.project;
  els["run-started"].textContent = r.started ? "started " + r.started : "";
  setRunStatus("st-running", "running");
  updateCounters();
}

function setRunStatus(kind, text) {
  els["run-status"].textContent = text;
  els["run-status"].className = "badge " + kind;
}

function updateCounters() {
  const v = state.view;
  els["c-ok"].textContent = v.ok;
  els["c-changed"].textContent = v.changed;
  els["c-failed"].textContent = v.failed;
}

function applyRecord(rec) {
  if (rec.ev) { applyEvent(rec.ev, rec.ts); return; }
  if (rec.log !== undefined) {
    appendRow(h("tr", { class: "log" },
      h("td", { class: "time" }, fmtTime(rec.ts)),
      h("td", { colspan: "3", class: "msg" }, rec.log),
    ));
    return;
  }
  if (rec.done !== undefined) {
    state.view.finished = true;
    state.view.exit = rec.exit;
    setRunStatus(rec.exit === 0 ? "st-exit-ok" : "st-exit-fail", "exit " + rec.exit);
    if (state.es) { state.es.close(); state.es = null; }
    refreshState();
  }
}

function applyEvent(ev, ts) {
  if (ev.t === "fileStart") {
    appendRow(h("tr", { class: "divider" },
      h("td", { class: "time" }, fmtTime(ts)),
      h("td", { colspan: "3", class: "msg" },
        "== " + (ev.file || "") + " | hosts: " + (ev.hosts || []).join(", ")),
    ));
    return;
  }
  if (ev.t === "fileDone") {
    state.view.ok = ev.ok;
    state.view.changed = ev.changed;
    state.view.failed = ev.failed;
    updateCounters();
    appendRow(h("tr", { class: "footer" },
      h("td", { class: "time" }, fmtTime(ts)),
      h("td", { colspan: "3", class: "msg" },
        "-- " + (ev.file || "") + ": ok=" + ev.ok + " changed=" + ev.changed
        + " failed=" + ev.failed
        + (ev.check ? " (check mode, nothing applied)" : "")),
    ));
    return;
  }
  // a job line: fold counters as they arrive
  const v = state.view;
  if (ev.status === "failed") v.failed++;
  else if (ev.status.startsWith("changed")) v.changed++;
  else v.ok++;
  updateCounters();

  appendRow(h("tr", { class: "st-" + statusClass(ev.status) },
    h("td", { class: "time" }, fmtTime(ts)),
    h("td", { class: "host" }, ev.host),
    h("td", { class: "status" }, ev.status),
    h("td", { class: "msg" },
      ev.label + ": " + ev.msg
      + (ev.ms ? " ("
        + (ev.ms >= 1000 ? (ev.ms / 1000).toFixed(1) + "s" : ev.ms + "ms")
        + ")" : "")),
  ));
  // details are always in the stream; CSS shows them only in verbose mode
  if (ev.details) {
    for (const d of ev.details)
      appendRow(h("tr", { class: "detail" },
        h("td", { colspan: "4" }, d)));
  }
}

// ---- run lifecycle ----------------------------------------------------------------

async function startRun(mode) {
  if (!state.project) return;
  const btn = els["btn-" + mode];
  btn.disabled = true;
  try {
    const r = await api("/api/run", "POST", {
      project: state.project,
      selection: els.selection.value.trim() || "all",
      mode: mode,
    });
    await openRun(r.id);
  } catch (e) {
    alert(e.message || String(e));
  } finally {
    btn.disabled = false;
  }
}

async function openRun(id) {
  if (!state.runs.some(r => r.id === id)) await refreshState();
  const run = state.runs.find(r => r.id === id);
  if (!run) return;

  state.current = id;
  if (state.es) state.es.close();
  els.runview.classList.remove("hidden");
  resetView(run);
  renderRuns();

  const es = new EventSource("/api/events/" + encodeURIComponent(id));
  state.es = es;
  es.onmessage = (m) => {
    let rec;
    try { rec = JSON.parse(m.data); } catch (_) { return; }
    applyRecord(rec);
  };
  // the server ends a finished run's replay with an "end" event so the
  // browser does not reconnect forever
  es.addEventListener("end", () => {
    es.close();
    if (state.es === es) state.es = null;
    if (!state.view.finished) {
      state.view.finished = true;
      setRunStatus("st-exit-fail", "stream ended");
    }
  });
  // a dropped connection reconnects with Last-Event-ID and resumes
}

// ---- boot ----------------------------------------------------------------

async function refreshState() {
  const s = await api("/api/state");
  state.projects = s.projects || [];
  state.hosts = s.hosts || [];
  state.tags = s.tags || [];
  state.inventoryError = s.inventoryError || "";
  state.runs = s.runs || [];
  renderInventory();
  renderProjects();
  renderRunbar();
  renderRuns();
}

function init() {
  els["btn-check"].addEventListener("click", () => startRun("check"));
  els["btn-apply"].addEventListener("click", () => startRun("apply"));
  els["run-form"].addEventListener("submit", (e) => e.preventDefault());
  els.selection.addEventListener("input", renderRunbar);
  els.verbose.addEventListener("change", () => {
    document.body.classList.toggle("verbose", els.verbose.checked);
  });

  refreshState().then(() => {
    if (!state.project && state.projects.length)
      state.project = state.projects[0].path;
    renderProjects();
    renderRunbar();
    // open the most recent run, if any
    if (state.runs.length) openRun(state.runs[state.runs.length - 1].id);
  }).catch((e) => {
    els["inv-error"].textContent = "cannot reach the tachy server: " + e.message;
    els["inv-error"].classList.remove("hidden");
  });

  // runs started elsewhere (another tab) show up here too
  setInterval(() => refreshState().catch(() => {}), 15000);
}

init();
