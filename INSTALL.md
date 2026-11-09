# NotchNote: install, pause, restart, remove

**Quickest way: go to "Option A" at the bottom. No Xcode, no Terminal.**

Everything below is done on your Mac. You do not need a paid Apple account. Allow about 20 minutes the first time, mostly waiting for Xcode to download.

## Part 1. One-time setup

**Step 1. Install a build tool. You do not need the full Xcode app.**
Pick one:
- **Small option (recommended): Command Line Tools, about 1 to 2 GB.** Open **Terminal** (⌘ Space, type Terminal), type `xcode-select --install`, press Return, and click Install in the window that appears. Wait until it says the software was installed.
- **Big option: Xcode from the App Store, 10 GB or more.** Open it once, click Agree on the license, let it install extra components, then quit it.

The installer in Step 3 uses Xcode if it is there and the Command Line Tools otherwise. One limit of the small option: the Shortcuts action "Add task" is not registered; everything else works.

**Step 2. Unpack the project.**
Find `NotchNote.tar.gz` (in Documents or Downloads) and double-click it. A folder called **NotchNote-project** appears next to it.

## Part 2. Install

**Step 3. Run the installer.**
Open the **NotchNote-project** folder. Right-click **Install NotchNote.command**, choose **Open**, then click **Open** again in the warning.
A Terminal window opens and prints a lot of text. It builds the app, which takes 2 to 5 minutes the first time. Do not close it.

If double-clicking does not work, do this instead: open **Terminal**, type `cd ` (with a space), drag the NotchNote-project folder into the window, press Return, then type `make install` and press Return.

**Step 4. Wait for the last line.**
When you see `Installed and started: /Applications/NotchNote.app`, it worked. Press any key to close Terminal.

**Step 5. Answer the first-run prompts.**
- A small **Getting Started** window appears. Read it and close it.
- macOS may ask to allow **notifications**: choose Allow (needed for reminders).
- macOS may ask for **calendar access**: optional, only needed for the Today agenda.
- If a banner says NotchNote was added to **Login Items**, leave it on.

**Step 6. Try it.**
Move the pointer to the notch at the top centre of the screen. The panel opens. Click anywhere outside it and it folds back.

**If Step 3 ends with red errors:** copy the last 30 lines of the Terminal window and send them to me. The app has not been compiled before, so one or two small fixes are possible.

## Part 3. Everyday use (it runs in the background)

NotchNote has no Dock icon and no window. It sits in the notch and has a small note icon in the menu bar at the top right. It starts by itself every time you log in.

## Part 4. Pause: quit it, and open it again later

**To quit (pause everything, including reminders):**
1. Click the note icon in the menu bar.
2. Click **Quit NotchNote**.
Your notes are saved first.

**To open it again later:**
- Press **⌘ Space**, type `NotchNote`, press Return. Or open **Finder, Applications, NotchNote**.

**To keep it from starting at login (so a quit stays quit after a restart):**
- Click the menu bar icon, **Settings**, switch **Launch at login** off. Or: **System Settings, General, Login Items**, switch NotchNote off.

**Quieter without quitting:** in **Settings**, set "Remind me about unchecked items" to **Off**.

## Part 5. Remove it completely

1. Quit it (menu bar icon, Quit NotchNote).
2. Open Terminal, type `cd ` (with a space), drag the NotchNote-project folder in, press Return, then run `make uninstall`. This removes the app from Applications.
   Without Terminal: open Finder, Applications, drag **NotchNote** to the Trash.
3. Open **System Settings, General, Login Items** and make sure NotchNote is not listed.
4. Optional, to delete your notes too: in Finder choose **Go, Go to Folder** and enter `~/Library/Application Support/NotchNote`, then move that folder to the Trash. If you chose a sync folder in Settings, delete the **NotchNote** folder inside it as well.
5. Optional: delete the NotchNote-project folder and NotchNote.tar.gz.

Notes are kept by default when you uninstall, so you can reinstall later and find them again.

## Reinstall or update

Repeat Step 3. It replaces the old copy and keeps your notes.

## Option A (easiest). Download the finished app

The app is built for you on GitHub's Mac servers every time the project changes.

1. Open `https://github.com/clementtoumire-maker/notchnote/releases` (signed in; the repository is private).
2. Under the newest release, click **NotchNote-app.zip** to download it.
3. Double-click the zip to unzip it. Drag **NotchNote.app** into **Applications**.
4. First open only: right-click the app, choose **Open**, then **Open** again. If macOS still refuses, open Terminal and run `xattr -cr /Applications/NotchNote.app`, then open it again.
5. It then runs in the background and starts at login (see Part 4 to quit, pause or remove it).

Nothing else needs to be installed. The sections below (Options B and C) are only for building it yourself.
