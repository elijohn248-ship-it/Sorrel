# Birch's UI pages (Chromium edition)

Birch's own interface, as HTML/CSS/JS pages compiled into the app
(`tools/embed_ui.py`) and shown by the UI host (`engine/ui_page.h`) as
`birch-ui://<folder>/index.html`, each in a browser of its own that never
loads web content. Rules: CLAUDE.md ▸ Chromium edition ▸ UI host.

| Folder | What | Owner |
|---|---|---|
| `shared/` | `base.css` (tokens, type), `motion.css` + `motion.js` (the three curves `settle` / `leave` / `glide`, Reduce Motion), `channel.js` (`Birch.send` / `Birch.on` over the native `birchUI`) | shared: change with care |
| `sidebar/` | the sidebar: space title, back/forward/reload, address box, tabs, + New Tab | agent 5 |
| `commandbar/` | the Ctrl+T command bar | agent 6 |
| `peek/`, `split/`, `library/` | Peek chrome, split view chrome, the Library | agent 8 |
| `settings/` | settings pages (Privacy, Extensions: agent 7) | agent 7 (others as they need) |

Each page:
- loads only its own files and `shared/<file>` by relative URL
  (`shared/motion.js` from `birch-ui://<folder>/` serves `ui/web/shared/`);
- has no inline script or style (the CSP forbids them), no frames, no
  network, no forms;
- talks to the app only with `Birch.send(name, args)` (names and argument
  types are fixed in `core/ui_channel.cc`; anything else is refused) and
  hears from it with `Birch.on(name, fn)` (data arrives as JSON, already
  parsed); never puts app data into `innerHTML`: use `textContent`.

Only `.html .css .js .svg .png .woff2` files are built in. A new page
folder needs a C++ `engine::UiPage::Create("<folder>", …)` caller in its
`ui/<area>/` host; a new message needs a line in `core/ui_channel.cc` and a
case in `tests/unit/ui_channel_tests.cc`.
