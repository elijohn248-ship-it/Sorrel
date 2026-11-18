# Birch

A private, Arc-style web browser for the Mac, built on Safari's engine (WebKit).

Birch was called **Sorrel** until version 0.3.1. Copies of Sorrel update to Birch by themselves and keep your tabs, logins and settings.

- **Spaces and a sidebar** for your tabs, pinned tabs and favorites
- **Ads and trackers blocked** out of the box, with uBlock Origin Lite built in
- **No analytics, crash reporting or telemetry.** Birch never sends anything about you or your Mac.
- **Extensions** from the Chrome Web Store and Safari
- **Bangs** (`!w`, `!yt`, …) in the command bar
- **Import** your spaces, tabs, bookmarks and history from Arc, Chrome, Firefox, Zen, Safari and others

## Requirements

- A Mac with **Apple Silicon** (M1 or later). Intel Macs aren't supported.
- **macOS 15.4** (Sequoia) or later

## Install

1. Go to the [latest release](https://github.com/elijohn248-ship-it/sorrel/releases/latest) and download the disk image, `Birch-<version>.dmg`, under **Assets**.
2. Open the downloaded `.dmg`. A window opens showing Birch and your Applications folder.
3. Drag **Birch** onto the **Applications** folder in that window.
4. Open Birch from Applications. (Then you can eject the Birch disk in Finder's sidebar and delete the `.dmg`.)
5. **The first time only**, macOS says it can't verify Birch. This is because Birch isn't notarized by Apple, which requires a paid developer account. To open it anyway:
   1. Click **Done** in the warning.
   2. Open **System Settings ▸ Privacy & Security**.
   3. Scroll down to the message about Birch and click **Open Anyway**.
   4. Confirm with your password or Touch ID.

After that, Birch opens normally.

> **Run it from Applications, not Downloads or the disk image.** macOS won't let an app running from there update itself. If you open it from there by mistake, Birch offers to move itself into Applications.

The `.zip` in the release works too (and is the only download for releases before the disk image was added): open it, then drag `Birch.app` into Applications.

### Make Birch your default browser (optional)

Go to **Settings ▸ General** in Birch and click **Make Birch the Default Browser**.

## Updates

Birch updates itself. It checks for a new version every few hours and installs it the next time you quit. To check right away, choose **Birch ▸ Check for Updates…**.

Every update is signed, and Birch installs only updates that pass the signature check. You can turn automatic checks off in **Settings ▸ General ▸ Updates**.

After an update, websites may ask again for your camera or microphone.

## Uninstall

1. Quit Birch and drag it from Applications to the Trash.
2. To also delete your tabs, history, cookies and settings, delete the folder `~/Library/Containers/app.sorrel.browser`. (The folder keeps Birch's earlier name.)
   - In Finder, choose **Go ▸ Go to Folder…** and paste that path.

## Build from source

You need Xcode 16.3 or later, or its Command Line Tools.

```sh
git clone https://github.com/elijohn248-ship-it/sorrel.git
cd sorrel
./build.sh            # builds build/Birch.app
./build.sh install    # builds and copies it to /Applications
```

## License

Copyright © 2026 Eli Johnson

Birch is free software under the [GNU General Public License v3.0](LICENSE). You may use, change and share it, but any version you share must stay open under the same license.

Birch includes [uBlock Origin Lite](vendor/ubol) (GPL-3.0) and [Kagi's bangs list](vendor/kagi-bangs) (MIT); their licenses are in their folders.
