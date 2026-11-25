// BirchMotion: the three curves (settle, leave, glide) for scripted
// animation, and Reduce Motion. Mirrors motion.css; the Mac's Motion enum
// (Support.swift) is the reference.
//   BirchMotion.enter(el)            a row/card arriving (rise + fade in)
//   BirchMotion.leave(el, done)      going (sink + fade out), then done()
//   BirchMotion.animate(el, frames, "settle"|"leave"|"glide", ms)
// With Reduce Motion, transforms are dropped and only opacity animates.
"use strict";

(function () {
  const curves = {
    settle: "cubic-bezier(0.22, 1, 0.36, 1)",
    leave: "cubic-bezier(0.4, 0, 1, 1)",
    glide: "cubic-bezier(0.4, 0, 0.2, 1)",
  };
  const durations = { settle: 220, leave: 140, glide: 180 };
  const query = window.matchMedia("(prefers-reduced-motion: reduce)");

  function reduced() {
    return query.matches;
  }

  function animate(el, frames, curve, ms) {
    const kind = curves[curve] ? curve : "glide";
    let list = frames;
    if (reduced()) {
      // Keep fades, drop movement.
      list = frames.map((f) => {
        const out = {};
        if ("opacity" in f) out.opacity = f.opacity;
        if ("offset" in f) out.offset = f.offset;
        return out;
      });
      if (!list.some((f) => "opacity" in f)) {
        return { finished: Promise.resolve() };
      }
    }
    if (!el.animate) {
      return { finished: Promise.resolve() };
    }
    return el.animate(list, {
      duration: ms || durations[kind],
      easing: curves[kind],
      fill: "both",
    });
  }

  function enter(el) {
    return animate(
      el,
      [
        { opacity: 0, transform: "translateY(-4px) scale(0.98)" },
        { opacity: 1, transform: "none" },
      ],
      "settle"
    );
  }

  function leave(el, done) {
    const a = animate(
      el,
      [
        { opacity: 1, transform: "none" },
        { opacity: 0, transform: "scale(0.97)" },
      ],
      "leave"
    );
    a.finished.then(done, done);
  }

  window.BirchMotion = Object.freeze({
    curves: Object.freeze(curves),
    durations: Object.freeze(durations),
    reduced,
    animate,
    enter,
    leave,
  });
})();
