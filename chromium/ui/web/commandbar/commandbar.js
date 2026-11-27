// The command bar page. Talks to the app only through Birch.send / Birch.on
// (names fixed in core/ui_channel.cc). App data goes in with textContent.
"use strict";

(function () {
  const bar = document.getElementById("bar");
  const text = document.getElementById("text");
  const results = document.getElementById("results");
  const switcher = document.getElementById("switcher");
  const tiles = document.getElementById("tiles");

  let mode = "none"; // none | new | edit | switch
  let rows = []; // [{key, kind, title, subtitle, hint}] as last drawn
  let chosen = -1; // index of the arrowed row, -1 = none
  let haveFocus = false;
  let modifier = "Control";
  let switcherTabs = [];
  let selectedTab = "";

  function setColors(msg) {
    const root = document.documentElement;
    root.classList.toggle("private", Boolean(msg.private));
    if (Array.isArray(msg.colors) && msg.colors.length) {
      root.style.setProperty("--accent", msg.colors[msg.colors.length - 1]);
    } else {
      root.style.removeProperty("--accent");
    }
  }

  const GLYPH = { tab: "", search: "⌕", bang: "!", address: "↗", url: "↗", command: "›" };

  function renderRow(r) {
    const li = document.createElement("li");
    li.className = "row";
    li.setAttribute("role", "option");
    li.dataset.key = r.key;
    const icon = document.createElement("span");
    icon.className = "icon";
    li.appendChild(icon);
    const body = document.createElement("span");
    body.className = "text";
    const title = document.createElement("span");
    title.className = "title";
    const sub = document.createElement("span");
    sub.className = "subtitle";
    body.append(title, sub);
    li.appendChild(body);
    const hint = document.createElement("span");
    hint.className = "hint";
    li.appendChild(hint);
    li.addEventListener("mousedown", (e) => e.preventDefault()); // keep typing focus
    li.addEventListener("click", () => Birch.send("commandbar.pick", { key: r.key }));
    return li;
  }

  function fillRow(li, r) {
    const icon = li.querySelector(".icon");
    icon.textContent = r.kind === "tab" ? (r.title || "?").trim().charAt(0).toUpperCase() : GLYPH[r.kind] || "";
    li.querySelector(".title").textContent = r.title;
    li.querySelector(".subtitle").textContent = r.subtitle;
    li.querySelector(".hint").textContent = r.hint;
  }

  // Rows are matched by key between keystrokes: kept rows update in place,
  // new ones arrive, others leave (never a wholesale rebuild).
  function draw(list) {
    const previousKey = chosen >= 0 && rows[chosen] ? rows[chosen].key : null;
    const existing = new Map();
    for (const li of results.children) existing.set(li.dataset.key, li);
    const keep = new Set(list.map((r) => r.key));
    for (const [key, li] of existing) {
      if (!keep.has(key)) {
        existing.delete(key);
        if (window.BirchMotion) BirchMotion.leave(li, () => li.remove());
        else li.remove();
      }
    }
    let prev = null;
    for (const r of list) {
      let li = existing.get(r.key);
      if (!li) {
        li = renderRow(r);
        if (window.BirchMotion) BirchMotion.enter(li);
      }
      fillRow(li, r);
      if (li.previousSibling !== prev || !li.parentNode) {
        results.insertBefore(li, prev ? prev.nextSibling : results.firstChild);
      }
      prev = li;
    }
    rows = list;
    chosen = previousKey ? list.findIndex((r) => r.key === previousKey) : -1;
    paintChosen();
    text.setAttribute("aria-expanded", list.length ? "true" : "false");
  }

  function paintChosen() {
    let i = 0;
    for (const li of results.children) {
      if (li.dataset.key === (rows[chosen] || {}).key) li.classList.add("chosen");
      else li.classList.remove("chosen");
      i++;
    }
  }

  function move(delta) {
    if (!rows.length) return;
    chosen = chosen < 0 ? (delta > 0 ? 0 : rows.length - 1) : (chosen + delta + rows.length) % rows.length;
    paintChosen();
  }

  function query() {
    Birch.send("commandbar.query", { text: text.value });
  }

  text.addEventListener("input", () => {
    chosen = -1;
    query();
  });
  text.addEventListener("focus", () => (haveFocus = true));
  text.addEventListener("blur", () => {
    if (mode === "new" || mode === "edit") {
      if (haveFocus) Birch.send("commandbar.cancel", {});
    }
  });
  text.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      move(1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      move(-1);
    } else if (e.key === "Escape") {
      e.preventDefault();
      Birch.send("commandbar.cancel", {});
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (chosen >= 0 && rows[chosen]) Birch.send("commandbar.pick", { key: rows[chosen].key });
      else if (text.value.trim()) Birch.send("commandbar.submit", { text: text.value });
    }
  });

  // ---- the Control+Tab switcher --------------------------------------------------------
  function drawSwitcher() {
    tiles.textContent = "";
    for (const t of switcherTabs) {
      const li = document.createElement("li");
      li.className = "tile" + (t.id === selectedTab ? " chosen" : "");
      li.dataset.id = t.id;
      const av = document.createElement("span");
      av.className = "avatar";
      av.textContent = (t.title || t.host || "?").trim().charAt(0).toUpperCase();
      const name = document.createElement("span");
      name.className = "name";
      name.textContent = t.title || t.host;
      const host = document.createElement("span");
      host.className = "host";
      host.textContent = t.host;
      li.append(av, name, host);
      li.addEventListener("click", () => Birch.send("switcher.pick", { id: t.id }));
      tiles.appendChild(li);
    }
    const on = tiles.querySelector(".chosen");
    if (on && on.scrollIntoView) on.scrollIntoView({ block: "nearest", inline: "center" });
  }

  document.addEventListener("keyup", (e) => {
    if (mode === "switch" && e.key === modifier) Birch.send("switcher.release", {});
  });
  document.addEventListener("keydown", (e) => {
    if (mode === "switch" && e.key === "Escape") {
      e.preventDefault();
      Birch.send("switcher.cancel", {});
    }
  });
  window.addEventListener("blur", () => {
    if (mode === "switch") Birch.send("switcher.release", {});
  });

  // ---- from the app ------------------------------------------------------------------------
  Birch.on("bar.show", (msg) => {
    mode = msg.mode === "edit" ? "edit" : "new";
    setColors(msg);
    switcher.hidden = true;
    bar.hidden = false;
    haveFocus = document.hasFocus();
    text.value = msg.text || "";
    rows = [];
    chosen = -1;
    results.textContent = "";
    text.focus();
    if (msg.text) text.select();
    query();
  });
  Birch.on("bar.results", (msg) => {
    if (mode !== "new" && mode !== "edit") return;
    if (msg.text !== text.value) return; // an answer to older typing
    draw(Array.isArray(msg.results) ? msg.results : []);
  });
  Birch.on("bar.hide", () => {
    mode = "none";
    bar.hidden = true;
    switcher.hidden = true;
    text.value = "";
    results.textContent = "";
    rows = [];
  });
  Birch.on("switcher.show", (msg) => {
    mode = "switch";
    setColors(msg);
    bar.hidden = true;
    switcher.hidden = false;
    modifier = msg.modifier || "Control";
    switcherTabs = Array.isArray(msg.tabs) ? msg.tabs : [];
    selectedTab = msg.selected || "";
    drawSwitcher();
    window.focus();
  });
  Birch.send("ui.ready", {});
})();
