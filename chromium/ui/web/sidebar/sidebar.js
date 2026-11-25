// The sidebar. Draws what the app sends ("state"), and turns clicks and
// typing into channel messages. App data goes into the page only as
// textContent / properties, never as HTML.
"use strict";

(function () {
  const $ = (id) => document.getElementById(id);
  const tabsEl = $("tabs");
  const input = $("address");
  const notSecure = $("not-secure");
  let state = null;
  let editing = false;
  let newTabMode = false;

  // ---- colours ---------------------------------------------------------------

  function hexToRgb(hex) {
    const m = /^#([0-9a-f]{6})$/i.exec(hex || "");
    if (!m) return null;
    const v = parseInt(m[1], 16);
    return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
  }
  function mix(hex, base, amount) {
    const c = hexToRgb(hex);
    if (!c) return null;
    const out = c.map((v, i) => Math.round(v * amount + base[i] * (1 - amount)));
    return `rgb(${out[0]}, ${out[1]}, ${out[2]})`;
  }
  function applyColours(space) {
    const root = document.documentElement;
    root.classList.toggle("private", Boolean(space.private));
    const colors = Array.isArray(space.colors) ? space.colors : [];
    const base = space.private ? [38, 35, 46] : [247, 245, 250];
    const strength = space.private ? 0.12 : 0.45;
    const a = mix(colors[0], base, strength);
    const b = mix(colors[1] || colors[0], base, strength * 0.8);
    if (a) root.style.setProperty("--tint-a", a);
    if (b) root.style.setProperty("--tint-b", b);
    if (hexToRgb(space.background)) {
      root.style.setProperty("--surround", space.background);
    }
  }

  // ---- address box -------------------------------------------------------------

  function showAddress() {
    if (editing || !state) return;
    const text = state.address.text;
    input.value = typeof text === "string" ? text : "";
  }

  input.addEventListener("focus", () => {
    if (!editing) {
      editing = true;
      input.value = newTabMode || !state ? "" : state.address.full || "";
    }
    input.select();
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      const text = input.value.trim();
      editing = false;
      newTabMode = false;
      Birch.send("address.submit", { text });
      showAddress();
    } else if (e.key === "Escape") {
      e.preventDefault();
      editing = false;
      newTabMode = false;
      showAddress();
      Birch.send("address.cancel", {});
    }
  });
  input.addEventListener("blur", () => {
    if (!editing) return;
    editing = false;
    newTabMode = false;
    showAddress();
    Birch.send("address.blur", {});
  });

  Birch.on("address.focus", (msg) => {
    newTabMode = Boolean(msg && msg.newTab);
    editing = true;
    input.value = newTabMode ? "" : String((msg && msg.full) || "");
    input.focus();
    input.select();
  });

  // ---- tabs ----------------------------------------------------------------------

  function rowKey(row) {
    return `${row.kind}:${row.id || ""}:${row.target || ""}`;
  }

  function makeRow(row) {
    const li = document.createElement("li");
    li.dataset.key = rowKey(row);
    if (row.kind === "separator") {
      li.className = "separator";
      li.setAttribute("aria-hidden", "true");
      return li;
    }
    const title = document.createElement("span");
    title.className = "title";
    li.append(title);
    if (row.target) {
      li.className = "tab";
      li.dataset.target = row.target;
      li.addEventListener("click", () => {
        Birch.send("tab.select", { id: li.dataset.target });
      });
      if (row.kind === "today" || row.kind === "split") {
        const close = document.createElement("button");
        close.className = "close";
        close.textContent = "×";
        close.title = "Close Tab";
        close.addEventListener("click", (e) => {
          e.stopPropagation();
          Birch.send("tab.close", { id: li.dataset.target });
        });
        li.append(close);
      }
    } else {
      li.className = row.kind === "folder" ? "folder" : "label";
    }
    return li;
  }

  function renderRows(rows, selected) {
    const existing = new Map();
    for (const li of tabsEl.children) {
      if (!li.classList.contains("leaving")) existing.set(li.dataset.key, li);
    }
    const keep = new Set();
    let before = tabsEl.firstChild;
    for (const row of rows) {
      const key = rowKey(row);
      let li = existing.get(key);
      const fresh = !li;
      if (fresh) li = makeRow(row);
      keep.add(key);
      const title = li.querySelector(".title");
      if (title) {
        title.textContent = String(row.title || "");
        li.title = String(row.title || "");
      }
      li.style.setProperty("--depth", String(Math.max(0, Math.min(8, row.depth | 0))));
      li.classList.toggle("selected", Boolean(row.target) && row.target === selected);
      while (before && before.classList && before.classList.contains("leaving")) {
        before = before.nextSibling;
      }
      if (li !== before) tabsEl.insertBefore(li, before);
      else before = before.nextSibling;
      if (fresh && state) BirchMotion.enter(li);
    }
    for (const [key, li] of existing) {
      if (keep.has(key)) continue;
      li.classList.add("leaving");
      BirchMotion.leave(li, () => li.remove());
    }
  }

  // ---- state from the app ---------------------------------------------------------------

  Birch.on("state", (next) => {
    if (!next || typeof next !== "object") return;
    applyColours(next.space || {});
    $("space-title").textContent = String((next.space && next.space.title) || "");
    $("back").disabled = !next.nav.back;
    $("forward").disabled = !next.nav.forward;
    $("reload").disabled = !next.nav.reload;
    notSecure.hidden = !next.address.notSecure;
    renderRows(Array.isArray(next.rows) ? next.rows : [], next.selected || "");
    state = next;
    showAddress();
  });

  // ---- buttons ---------------------------------------------------------------------------

  $("back").addEventListener("click", () => Birch.send("nav.back", {}));
  $("forward").addEventListener("click", () => Birch.send("nav.forward", {}));
  $("reload").addEventListener("click", () => Birch.send("nav.reload", {}));
  $("new-tab").addEventListener("click", () => Birch.send("tab.new", {}));

  Birch.send("ui.ready", {});
})();
