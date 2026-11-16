# Progress

- Proton Pass pop-up fixes (`proton-popup` merged; `proton-guard` follows it): verified in test profiles signed out. Still needs the owner, signed in, to confirm the password list shows after Sorrel has sat idle for a minute or more, and that opening Proton's settings (right-click its icon) then its pop-up still works.
- Browser import (`browser-import`, not merged): built and tested against fixtures for every format and, counts only, against copies of the owner's real Arc, Helium and Zen data. Needs the owner: the real Open panel (does Allow on Arc's pre-selected folder hand it over, and does Safari's folder open or fall back to the export message), and the feel of the card's motion on screen. Not read: Zen workspaces, Chromium open tabs, cookies, passwords.
