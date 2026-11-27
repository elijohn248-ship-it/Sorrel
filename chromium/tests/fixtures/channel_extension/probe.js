"use strict";
window.extensionProbe = {
  id: chrome.runtime.id,
  name: chrome.runtime.getManifest().name,
  channel: typeof window.birchUI + "/" + typeof window.cefQuery,
  sent: false,
};
if (window.birchUI) {
  window.birchUI.send("tab.new", {});
  window.extensionProbe.sent = true;
}
