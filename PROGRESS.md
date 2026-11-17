# Progress

- **Sidebar mini player (implemented and verified):** compact sidebar player with play/pause, tab mute, source selection and return-to-tab. Native controls with a fixed-script resume fallback for audio-only pages. Verified after merging current main: `swift build`, release bundle build (the same two source warnings), `SORREL_MEDIATEST` with silent local audio, and `SORREL_CLEANTEST` for Library/memory/data behavior. Owner still needs to judge the feel and test their music site while switching tabs/spaces, pausing/resuming and muting/unmuting.
- **Proton Pass pop-up fixed (2026-11-16):** owner confirmed the `proton-list` sizing fix works. Details: BUGS.md ▸ Fixed.
- **Browser import is merged:** fixture checks passed. Still needs the owner: the real Open-panel Allow flow, Safari folder access, and the card's motion. Zen workspaces, Chromium open tabs, cookies and passwords are not imported.
