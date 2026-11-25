// Birch.send(name, args) / Birch.on(name, fn) over the native `birchUI`
// object, which exists only in Birch's own UI pages (engine/cef/
// ui_renderer.cc). Names and argument types are fixed in
// core/ui_channel.cc; the app refuses anything else. Data from the app
// arrives already parsed from JSON.
"use strict";

(function () {
  const native = window.birchUI;
  const handlers = new Map();

  if (native) {
    native.onMessage((name, data) => {
      const list = handlers.get(name);
      if (list) {
        for (const fn of list) fn(data);
      }
    });
  }

  window.Birch = Object.freeze({
    available: Boolean(native),
    send(name, args) {
      if (native) native.send(name, args || {});
    },
    on(name, fn) {
      if (!handlers.has(name)) handlers.set(name, []);
      handlers.get(name).push(fn);
    },
  });
})();
