"use strict";
(() => {
  const card = document.getElementById("test-update");
  const check = document.getElementById("update-check");
  const install = document.getElementById("update-install");
  Birch.on("update.state", (state) => {
    if (!state || typeof state !== "object") return;
    card.hidden = !state.supported;
    document.getElementById("update-auto").checked = Boolean(state.automatic);
    document.getElementById("update-message").textContent = String(state.message || "");
    document.getElementById("update-version").textContent = state.version ? String(state.version) : "";
    check.disabled = Boolean(state.busy);
    install.hidden = !state.canInstall;
    install.disabled = Boolean(state.busy);
    check.textContent = state.busy ? "Please wait…" : "Check for updates";
  });
  document.getElementById("update-auto").addEventListener("change", (event) =>
    Birch.send("update.automatic", {enabled: event.target.checked}));
  check.addEventListener("click", () => Birch.send("update.check", {}));
  install.addEventListener("click", () => Birch.send("update.install", {}));
})();
