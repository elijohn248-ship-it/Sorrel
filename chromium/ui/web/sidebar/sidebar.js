// The sidebar. Draws what the app sends ("state"), and turns clicks and
// typing into channel messages. App data goes into the page only as
// textContent / properties, never as HTML.
"use strict";

(function () {
  const $ = (id) => document.getElementById(id);
  const tabsEl = $("tabs");
  const spacesEl = $("spaces");
  const spaceScroll = $("space-scroll");
  const sidebar = $("sidebar-surface");
  const menu = $("sidebar-menu");
  const darkMode = matchMedia("(prefers-color-scheme: dark)");
  const input = $("address");
  const notSecure = $("not-secure");
  let state = null;
  let editing = false;
  let newTabMode = false;
  let drag = null;
  let dropIndicator = null;
  let hideTimer = 0;
  let pendingMode = "";
  let spaceDirection = 0;

  function action(action, { id = "", target = "", index = 0, text = "", extra = "", value = 0 } = {}) {
    Birch.send("sidebar.action", { action, id, target, index, text, extra, value });
  }

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
  function clamp(value, min = 0, max = 1) {
    return Math.min(max, Math.max(min, value));
  }

  function applyColours(space, theme) {
    const root = document.documentElement;
    const isPrivate = Boolean(space.private);
    const look = theme && (isPrivate || darkMode.matches ? theme.dark : theme.light);
    const stops = look?.stops || [];
    const locations = look?.locations || [];
    const gradient = stops.map(({ r, g, b, a }, index) => {
      const rgb = [r, g, b].map((channel) => Math.round(clamp(channel) * 255));
      return `rgba(${rgb.join(",")},${clamp(a ?? 1)}) ${100 * clamp(locations[index])}%`;
    });
    if (gradient.length > 1 && Number.isFinite(theme.angle)) {
      // The Mac's angle is measured from the right in a y-up coordinate system.
      root.style.setProperty("--space-gradient", `linear-gradient(${90 - theme.angle}deg, ${gradient.join(",")})`);
    } else {
      root.style.removeProperty("--space-gradient");
    }
    const luminance = stops.reduce((sum, { r, g, b }) => sum + 0.2126 * r + 0.7152 * g + 0.0722 * b, 0);
    root.classList.toggle("private", isPrivate);
    root.classList.toggle("dark", isPrivate || (stops.length ? luminance / stops.length < 0.55 : darkMode.matches));
    const colors = Array.isArray(space.colors) ? space.colors : [];
    const base = isPrivate ? [38, 35, 46] : [247, 245, 250];
    const strength = isPrivate ? 0.12 : 0.45;
    const a = mix(colors[0], base, strength);
    const b = mix(colors[1] || colors[0], base, strength * 0.8);
    if (a) root.style.setProperty("--tint-a", a);
    if (b) root.style.setProperty("--tint-b", b);
    if (hexToRgb(space.background)) {
      root.style.setProperty("--surround", space.background);
    }
    root.style.setProperty("--grain-opacity", String(0.32 * clamp(look?.grain ?? 0)));
    if (look?.grain) paintGrain();
  }

  const grain = $("grain");
  let grainTile;

  function paintGrain() {
    const width = Math.round(grain.clientWidth * devicePixelRatio);
    const height = Math.round(grain.clientHeight * devicePixelRatio);
    if (!width || !height || (grainTile && grain.width === width && grain.height === height)) return;
    grain.width = width;
    grain.height = height;
    const context = grain.getContext("2d");
    if (!context) return;
    if (!grainTile) {
      grainTile = document.createElement("canvas");
      grainTile.width = grainTile.height = 256;
      const tileContext = grainTile.getContext("2d");
      const image = tileContext.createImageData(256, 256);
      let seed = 0x5eed50ffe1n;
      const random = () => {
        seed = BigInt.asUintN(64, seed * 6364136223846793005n + 1442695040888963407n);
        return Number(seed >> 11n) / (2 ** 53);
      };
      for (let i = 0; i < image.data.length; i += 4) {
        const noise = clamp(((random() + random() + random() + random()) / 4 - 0.5) * 3.2, -1, 1);
        const shade = noise > 0 ? 255 : 0;
        image.data[i] = image.data[i + 1] = image.data[i + 2] = shade;
        image.data[i + 3] = Math.trunc(255 * Math.abs(noise));
      }
      tileContext.putImageData(image, 0, 0);
    }
    const pattern = context.createPattern(grainTile, "repeat");
    pattern.setTransform(new DOMMatrix().scale(devicePixelRatio / 2));
    context.fillStyle = pattern;
    context.fillRect(0, 0, width, height);
  }

  new ResizeObserver(() => { if (grainTile) paintGrain(); }).observe(grain);
  darkMode.addEventListener("change", () => { if (state) applyColours(state.space || {}, state.theme); });

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
    if (!sidebar.matches(":hover")) scheduleHide();
  });

  Birch.on("address.dismiss", () => {
    editing = false;
    newTabMode = false;
    input.blur();
    showAddress();
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
    if (row.kind === "section") {
      li.className = "section";
      li.textContent = row.title;
      return li;
    }
    const control = document.createElement("button");
    control.type = "button";
    control.className = "row-main";
    if (row.kind === "favorite") {
      const mark = document.createElement("span");
      mark.className = "favorite-mark";
      mark.setAttribute("aria-hidden", "true");
      control.append(mark);
    }
    const title = document.createElement("span");
    title.className = "title";
    control.append(title);
    li.append(control);
    li.draggable = Boolean(row.id);
    if (row.target) {
      li.className = "tab";
      if (row.kind === "favorite") li.classList.add("favorite");
      li.dataset.target = row.target;
      li.addEventListener("click", () => {
        Birch.send("tab.select", { id: li.dataset.target });
      });
      if (row.kind === "today" || row.kind === "split") {
        const close = document.createElement("button");
        close.className = "close";
        close.textContent = "×";
        close.title = "Close Tab";
        close.setAttribute("aria-label", "Close Tab");
        close.addEventListener("click", (e) => {
          e.stopPropagation();
          Birch.send("tab.close", { id: li.dataset.target });
        });
        li.append(close);
      }
    } else if (row.kind === "folder") {
      li.className = "folder";
      li.addEventListener("click", () => action("folder.toggle", { id: row.id }));
    } else {
      control.disabled = true;
    }
    return li;
  }

  function displayRows(rows) {
    const favorite = { kind: "section", id: "favorites", title: "Favorites" };
    const pinned = { kind: "section", id: "pinned", title: "Pinned" };
    const today = { kind: "section", id: "today", title: "Today" };
    const result = [favorite];
    let section = "favorites";
    for (const row of rows) {
      if (row.kind !== "favorite" && section === "favorites") {
        result.push(pinned);
        section = "pinned";
      }
      if (row.kind === "separator") {
        result.push(today);
        section = "today";
        continue;
      }
      result.push({ ...row, section: row.section || section });
    }
    if (section === "favorites") result.push(pinned);
    if (section !== "today") result.push(today);
    return result;
  }

  function renderRows(rows, selected) {
    const existing = new Map();
    for (const li of tabsEl.children) {
      if (!li.classList.contains("leaving")) existing.set(li.dataset.key, li);
    }
    const keep = new Set();
    let before = tabsEl.firstChild;
    for (const row of displayRows(rows)) {
      const key = rowKey(row);
      let li = existing.get(key);
      const fresh = !li;
      if (fresh) li = makeRow(row);
      keep.add(key);
      li.dataset.item = row.id || "";
      li.dataset.kind = row.kind;
      li.dataset.destination = row.parent || row.section || row.id;
      li.dataset.index = String(row.index ?? 0);
      li.dataset.section = row.section || "";
      const title = li.querySelector(".title");
      if (title) {
        const text = String(row.title || "");
        title.textContent = text;
        li.title = text;
        const mark = li.querySelector(".favorite-mark");
        if (mark) mark.textContent = Array.from(text.trim())[0]?.toLocaleUpperCase() || "•";
      }
      if (row.kind === "folder") {
        li.querySelector("button").setAttribute("aria-expanded", String(Boolean(row.expanded)));
      }
      if (row.target) {
        li.querySelector("button").setAttribute("aria-current", row.target === selected ? "page" : "false");
      }
      li.style.setProperty("--depth", String(Math.max(0, Math.min(8, row.depth | 0))));
      li.classList.toggle("selected", Boolean(row.target) && row.target === selected);
      while (before && before.classList && before.classList.contains("leaving")) {
        before = before.nextSibling;
      }
      if (li !== before) tabsEl.insertBefore(li, before);
      else before = before.nextSibling;
      if (fresh && state && !spaceDirection) {
        const animation = BirchMotion.enter(li);
        animation.finished.then(() => animation.cancel?.(), () => {});
      }
    }
    for (const [key, li] of existing) {
      if (keep.has(key)) continue;
      if (spaceDirection) {
        li.remove();
        continue;
      }
      li.classList.add("leaving");
      li.inert = true;
      BirchMotion.leave(li, () => li.remove());
    }
  }

  // ---- spaces, folders and dragging ----------------------------------------------

  function renderSpaces(spaces, currentSpace, isPrivate) {
    const existing = new Map(Array.from(spacesEl.children, (button) => [button.dataset.space, button]));
    for (const [index, space] of spaces.entries()) {
      let button = existing.get(space.id);
      if (!button) {
        button = document.createElement("button");
        button.className = "icon motion-glide";
        button.dataset.space = space.id;
        button.addEventListener("click", () => selectSpace(button.dataset.space));
        button.addEventListener("contextmenu", (event) => {
          if (button.dataset.space !== state?.currentSpace) return;
          event.preventDefault();
          openSpaceEditor();
        });
      }
      existing.delete(space.id);
      button.draggable = !isPrivate;
      button.dataset.index = String(index);
      button.textContent = space.icon || "◈";
      button.title = space.name;
      button.setAttribute("aria-label", space.name);
      button.setAttribute("aria-pressed", String(space.id === currentSpace));
      if (button !== spacesEl.children[index]) spacesEl.insertBefore(button, spacesEl.children[index] || null);
    }
    for (const button of existing.values()) button.remove();
    if (state?.currentSpace !== currentSpace) {
      spacesEl.querySelector('[aria-pressed="true"]')?.scrollIntoView({ block: "nearest", inline: "nearest" });
    }
  }

  function selectSpace(id) {
    if (!state || id === state.currentSpace) return;
    const spaces = state.spaces || [];
    const index = spaces.findIndex((space) => space.id === id);
    const previous = spaces.findIndex((space) => space.id === state.currentSpace);
    if (index < 0) return;
    spaceDirection = Math.sign(index - previous);
    action("space.select", { id });
  }

  spaceScroll.addEventListener("wheel", (event) => {
    if (event.ctrlKey) return;
    event.preventDefault();
    const delta = event.deltaX || event.deltaY;
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? spaceScroll.clientWidth : 1;
    spaceScroll.scrollLeft += delta * unit;
  }, { passive: false });

  // Chromium reports horizontal touchpad gestures as pixel-mode wheel streams.
  // Consume the rest of the stream after changing spaces, including momentum.
  let swipeDelta = 0;
  let swipeHandled = false;
  let swipeReset = 0;
  tabsEl.addEventListener("wheel", (event) => {
    if ((state?.spaces?.length || 0) < 2 || drag || event.deltaMode !== 0 || event.ctrlKey || event.shiftKey) return;
    if (!swipeHandled && Math.abs(event.deltaX) <= Math.abs(event.deltaY) * 1.4) return;
    event.preventDefault();
    clearTimeout(swipeReset);
    swipeReset = setTimeout(() => { swipeDelta = 0; swipeHandled = false; }, 150);
    if (swipeHandled) return;
    swipeDelta += event.deltaX;
    if (Math.abs(swipeDelta) < 58) return;
    swipeHandled = true;
    const current = state.spaces.findIndex((space) => space.id === state.currentSpace);
    const destination = state.spaces[current + Math.sign(swipeDelta)];
    if (destination) selectSpace(destination.id);
  }, { passive: false });

  const appendPosition = 1000000; // Native moves clamp a final index to the destination length.
  const bottom = $("new-tab").parentElement;

  function clearDropIndicator() {
    if (!dropIndicator) return;
    dropIndicator.element.classList.remove(dropIndicator.className);
    dropIndicator = null;
  }

  function endDrag() {
    drag?.element.classList.remove("drag-source");
    drag = null;
    updateHoverHold();
    clearDropIndicator();
  }

  sidebar.addEventListener("dragstart", (event) => {
    const element = event.target.closest("[draggable='true']");
    if (!element || !state || state.space?.private) return;
    const { item, space } = element.dataset;
    if (!item && !space) return;
    drag = { element, item, space };
    updateHoverHold();
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("application/x-birch-sidebar", "move");
    element.classList.add("drag-source");
  });

  function dropAt(event) {
    const icon = event.target.closest("#spaces button");
    if (drag.space) {
      if (!icon || icon === drag.element) return null;
      const rect = icon.getBoundingClientRect();
      const after = event.clientX > rect.left + rect.width / 2;
      const boundary = Number(icon.dataset.index) + Number(after);
      const index = boundary - Number(Number(drag.element.dataset.index) < boundary);
      return { element: icon, className: after ? "drop-after" : "drop-before", name: "space.move", fields: { id: drag.space, index } };
    }
    const source = drag.element.dataset;
    const row = event.target.closest("#tabs li:not(.leaving)");
    const space = icon?.dataset.space || state.currentSpace;
    const fields = { id: drag.item, extra: space, index: 0 };
    let element = row;
    let className = "drop-inside";
    if (icon && space !== state.currentSpace) {
      fields.target = source.section === "today" ? "today" : "pinned";
      fields.index = appendPosition;
      element = icon;
    } else if (bottom.contains(event.target) && !icon) {
      fields.target = "today";
      fields.index = appendPosition;
      element = bottom;
    } else if (row && row !== drag.element) {
      const rect = row.getBoundingClientRect();
      const data = row.dataset;
      const fraction = data.kind === "favorite"
        ? (event.clientX - rect.left) / rect.width
        : (event.clientY - rect.top) / rect.height;
      const inFolder = data.kind === "folder" && fraction >= 0.28 && fraction <= 0.72;
      if (inFolder) {
        fields.target = data.item;
        fields.index = appendPosition;
      } else {
        fields.target = data.destination;
        if (data.kind !== "section") {
          const after = fraction > 0.5;
          const boundary = Number(data.index) + Number(after);
          fields.index = boundary - Number(source.destination === fields.target && Number(source.index) < boundary);
          className = after ? "drop-after" : "drop-before";
        }
      }
    } else {
      return null;
    }
    if (source.kind === "folder" && ["favorites", "today"].includes(fields.target)) return null;
    if (source.kind === "split" && fields.target === "favorites") return null;
    return { element, className, name: "item.move", fields };
  }

  sidebar.addEventListener("dragover", (event) => {
    if (!drag) return;
    const drop = dropAt(event);
    if (!drop || drop.element !== dropIndicator?.element || drop.className !== dropIndicator?.className) clearDropIndicator();
    if (!drop) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    if (!dropIndicator) {
      dropIndicator = drop;
      drop.element.classList.add(drop.className);
    }
  });
  sidebar.addEventListener("drop", (event) => {
    if (!drag) return;
    const drop = dropAt(event);
    endDrag();
    if (!drop) return;
    event.preventDefault();
    action(drop.name, drop.fields);
  });
  sidebar.addEventListener("dragleave", (event) => {
    if (!sidebar.contains(event.relatedTarget)) clearDropIndicator();
  });
  document.addEventListener("dragend", endDrag);

  // ---- editors and sidebar visibility --------------------------------------------

  const spaceEditor = $("space-editor");
  const folderEditor = $("folder-editor");
  const settingsEditor = $("settings-editor");
  const editors = [spaceEditor, folderEditor, settingsEditor];
  const hoverSettings = [
    [$("hover-width"), "sidebarHoverEdgeWidth", 14, "px"],
    [$("hover-overshoot"), "sidebarOvershootReach", 90, "px"],
    [$("hover-delay"), "sidebarHideDelay", 0.12, "seconds"],
    [$("hover-speed"), "sidebarAnimationDuration", 0.2, "seconds"],
  ];
  const colorCount = $("color-count");
  const colorInputs = [$("color-1"), $("color-2"), $("color-3")];
  let editingSpace = "";
  let folderSpace = "";

  function updateColorCount() {
    colorInputs.forEach((input, index) => { input.hidden = index >= Number(colorCount.value); });
  }

  function openSpaceEditor() {
    const space = state?.spaces?.find((candidate) => candidate.id === state.currentSpace);
    if (!space || state.space?.private || spaceEditor.open) return;
    const theme = state.theme || {};
    const colors = theme.colors || [];
    editingSpace = space.id;
    $("space-name").value = space.name;
    $("space-emoji").value = space.icon || "";
    colorCount.value = String(clamp(colors.length, 1, 3));
    colorInputs.forEach((input, index) => {
      input.value = hexToRgb(colors[index]) ? colors[index] : ["#8978f9", "#6cbad9", "#34e895"][index];
    });
    updateColorCount();
    const angle = theme.angle ?? 315;
    $("space-angle").value = String(((angle % 360) + 360) % 360);
    $("space-intensity").value = String(theme.intensity ?? 0.8);
    $("space-brightness").value = String(theme.brightness ?? 0);
    $("space-grain").value = String(theme.grain ?? 0.35);
    $("space-logins").checked = Boolean(theme.separateLogins);
    spaceEditor.showModal();
    BirchMotion.enter(spaceEditor);
  }

  function saveSpace() {
    const text = $("space-name").value.trim();
    if (!text) {
      $("space-name").focus();
      return;
    }
    const extra = JSON.stringify({
      icon: $("space-emoji").value.trim(),
      colors: colorInputs.slice(0, Number(colorCount.value)).map((input) => input.value),
      angle: $("space-angle").valueAsNumber,
      intensity: $("space-intensity").valueAsNumber,
      brightness: $("space-brightness").valueAsNumber,
      grain: $("space-grain").valueAsNumber,
      separateLogins: $("space-logins").checked,
    });
    action("space.edit", { id: editingSpace, text, extra });
    spaceEditor.close();
  }

  function saveFolder() {
    const text = $("folder-name").value.trim();
    if (!text) {
      $("folder-name").focus();
      return;
    }
    action("folder.create", { id: folderSpace, text });
    folderEditor.close();
  }

  function requestMode(mode) {
    if (!state || state.sidebarMode === mode || pendingMode === mode) return;
    pendingMode = mode;
    action("sidebar.mode", { text: mode });
  }

  function cancelHide() { clearTimeout(hideTimer); }

  function scheduleHide() {
    cancelHide();
    if(state?.settings?.nativeHover) return;
    if (state?.sidebarMode !== "peeking" || editors.some((editor) => editor.open) || drag) return;
    const delay = clamp(state.settings?.sidebarHideDelay ?? 0.12, 0, 3) * 1000;
    hideTimer = setTimeout(() => {
      if (!sidebar.matches(":hover") && !editors.some((editor) => editor.open) && !drag) requestMode("hidden");
    }, delay);
  }

  function applyMode(next) {
    const mode = next.sidebarMode || "pinned";
    const hidden = mode === "hidden";
    if (mode === pendingMode || mode !== state?.sidebarMode) pendingMode = "";
    document.body.dataset.mode = mode;
    sidebar.inert = hidden;
    const title = mode === "peeking" ? "Pin Sidebar (Ctrl+S)" : "Enable Sidebar Auto-hide (Ctrl+S)";
    $("sidebar-mode").title = title;
    $("sidebar-mode").setAttribute("aria-label", title);
    if (mode === "peeking" && state?.sidebarMode !== mode) {
      const duration = clamp(next.settings?.sidebarAnimationDuration ?? 0.2, 0, 1) * 1000;
      if (duration) {
        const animation = BirchMotion.animate(sidebar, [
          { transform: "translateX(-12px)", opacity: 0 },
          { transform: "none", opacity: 1 },
        ], "settle", duration);
        animation.finished.then(() => animation.cancel?.(), () => {});
      }
    }
  }

  $("space-title").addEventListener("click", openSpaceEditor);
  $("new-space").addEventListener("click", () => action("space.create", { text: "New Space" }));
  $("new-folder").addEventListener("click", () => {
    if (!state?.currentSpace) return;
    menu.open = false;
    folderSpace = state.currentSpace;
    $("folder-name").value = "";
    folderEditor.showModal();
    BirchMotion.enter(folderEditor);
  });
  $("archive-now").addEventListener("click", () => { menu.open = false; action("archive.now"); });
  $("sleep-now").addEventListener("click", () => { menu.open = false; action("tabs.sleepNow"); });
  function showSettingValue(control, unit) {
    const value = `${control.value} ${unit}`;
    control.title = value;
    control.setAttribute("aria-valuetext", value);
  }
  for (const [control, , , unit] of hoverSettings) {
    control.addEventListener("input", () => showSettingValue(control, unit));
  }
  $("sidebar-settings").addEventListener("click", () => {
    menu.open = false;
    for (const [control, key, fallback, unit] of hoverSettings) {
      control.value = String(state?.settings?.[key] ?? fallback);
      showSettingValue(control, unit);
    }
    settingsEditor.showModal();
    BirchMotion.enter(settingsEditor);
  });
  $("cancel-settings").addEventListener("click", () => settingsEditor.close());
  $("save-settings").addEventListener("click", () => {
    const settings = Object.fromEntries(hoverSettings.map(([control, key]) => [key, control.valueAsNumber]));
    action("sidebar.settings", { extra: JSON.stringify(settings) });
    settingsEditor.close();
  });
  $("sidebar-mode").addEventListener("click", () => requestMode(state?.sidebarMode === "peeking" ? "pinned" : "hidden"));
  $("hover-strip").addEventListener("pointerenter", () => requestMode("peeking"));
  sidebar.addEventListener("pointerenter", cancelHide);
  sidebar.addEventListener("pointerleave", scheduleHide);
  document.addEventListener("pointerdown", (event) => { if (!menu.contains(event.target)) menu.open = false; });
  menu.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      menu.open = false;
      menu.querySelector("summary").focus();
    }
  });
  colorCount.addEventListener("change", updateColorCount);
  $("cancel-space").addEventListener("click", () => spaceEditor.close());
  $("cancel-folder").addEventListener("click", () => folderEditor.close());
  $("save-space").addEventListener("click", saveSpace);
  $("save-folder").addEventListener("click", saveFolder);
  for (const [dialog, save] of [[spaceEditor, saveSpace], [folderEditor, saveFolder]]) {
    dialog.addEventListener("keydown", (event) => {
      if (!event.isComposing && event.key === "Enter" && event.target.type === "text") {
        event.preventDefault();
        save();
      }
    });
  }
  for (const editor of editors) editor.addEventListener("close", () => { if (!sidebar.matches(":hover")) scheduleHide(); });

  function updateHoverHold() {
    action("sidebar.hold", { value: Number(Boolean(drag) || editors.some((editor) => editor.open)) });
  }
  const editorObserver = new MutationObserver(updateHoverHold);
  for (const editor of editors) editorObserver.observe(editor, { attributes: true, attributeFilter: ["open"] });

  // ---- state from the app ---------------------------------------------------------------

  Birch.on("state", (next) => {
    if (!next || typeof next !== "object") return;
    const currentSpaceChanged = state && state.currentSpace !== next.currentSpace;
    if (currentSpaceChanged && !spaceDirection) {
      const position = (id) => next.spaces?.findIndex((space) => space.id === id) ?? 0;
      spaceDirection = Math.sign(position(next.currentSpace) - position(state.currentSpace));
    }
    applyColours(next.space || {}, next.theme);
    applyMode(next);
    $("space-title").textContent = String((next.space && next.space.title) || "");
    $("space-title").disabled = Boolean(next.space?.private) || !next.currentSpace;
    $("new-space").disabled = Boolean(next.space?.private);
    $("new-folder").disabled = Boolean(next.space?.private);
    $("archive-now").disabled = Boolean(next.space?.private);
    $("sidebar-settings").disabled = Boolean(next.space?.private);
    renderSpaces(next.spaces || [], next.currentSpace, Boolean(next.space?.private));
    $("back").disabled = !next.nav.back;
    $("forward").disabled = !next.nav.forward;
    $("reload").disabled = !next.nav.reload;
    notSecure.hidden = !next.address.notSecure;
    renderRows(Array.isArray(next.rows) ? next.rows : [], next.selected || "");
    if (currentSpaceChanged && spaceDirection) {
      const animation = BirchMotion.animate(tabsEl, [
        { transform: `translateX(${16 * spaceDirection}px)`, opacity: 0.35 },
        { transform: "none", opacity: 1 },
      ], "settle");
      animation.finished.then(() => animation.cancel?.(), () => {});
      tabsEl.scrollTop = 0;
    }
    if (currentSpaceChanged) spaceDirection = 0;
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
