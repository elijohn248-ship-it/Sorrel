# Sorrel

A private, Arc-style web browser for the Mac, built on Safari's engine (WebKit).

- **Spaces and a sidebar** for your tabs, pinned tabs and favorites
- **Ads and trackers blocked** out of the box, with uBlock Origin Lite built in
- **No analytics, crash reporting or telemetry.** Sorrel never sends anything about you or your Mac.
- **Extensions** from the Chrome Web Store and Safari
- **Bangs** (`!w`, `!yt`, …) in the command bar
- **Import** your spaces, tabs, bookmarks and history from Arc, Chrome, Firefox, Zen, Safari and others

## Requirements

- A Mac with **Apple Silicon** (M1 or later). Intel Macs aren't supported.
- **macOS 15.4** (Sequoia) or later

## Install

1. Go to the [latest release](https://github.com/elijohn248-ship-it/sorrel/releases/latest) and download the `.zip` file under **Assets**.
2. Open the downloaded zip. Your Mac unzips it into `Sorrel.app`.
3. Drag **Sorrel** into your **Applications** folder.
4. Open Sorrel from Applications.
5. **The first time only**, macOS says it can't verify Sorrel. This is because Sorrel isn't notarized by Apple, which requires a paid developer account. To open it anyway:
   1. Click **Done** in the warning.
   2. Open **System Settings ▸ Privacy & Security**.
   3. Scroll down to the message about Sorrel and click **Open Anyway**.
   4. Confirm with your password or Touch ID.

After that, Sorrel opens normally.

> **Run it from Applications, not Downloads.** macOS won't let an app running from the Downloads folder update itself.

### Make Sorrel your default browser (optional)

Go to **Settings ▸ General** in Sorrel and click **Make Sorrel the Default Browser**.

## Updates

Sorrel updates itself. It checks for a new version every few hours and installs it the next time you quit. To check right away, choose **Sorrel ▸ Check for Updates…**.

Every update is signed, and Sorrel installs only updates that pass the signature check. You can turn automatic checks off in **Settings ▸ General ▸ Updates**.

After an update, websites may ask again for your camera or microphone.

## Uninstall

1. Quit Sorrel and drag it from Applications to the Trash.
2. To also delete your tabs, history, cookies and settings, delete the folder `~/Library/Containers/app.sorrel.browser`.
   - In Finder, choose **Go ▸ Go to Folder…** and paste that path.

## Build from source

You need Xcode 16.3 or later, or its Command Line Tools.

```sh
git clone https://github.com/elijohn248-ship-it/sorrel.git
cd sorrel
./build.sh            # builds build/Sorrel.app
./build.sh install    # builds and copies it to /Applications
```

## License

Copyright © 2026 Eli Johnson

Sorrel is free software under the [GNU General Public License v3.0](LICENSE). You may use, change and share it, but any version you share must stay open under the same license.

Sorrel includes [uBlock Origin Lite](vendor/ubol) (GPL-3.0) and [Kagi's bangs list](vendor/kagi-bangs) (MIT); their licenses are in their folders.
