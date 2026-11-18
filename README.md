<p align="center">
  <img src="Resources/Logo/AppIcon.svg" width="128" alt="Inquiline's icon">
</p>

<h1 align="center">Inquiline</h1>

<p align="center"><b>Android apps on your Mac, as Mac apps.</b></p>

<p align="center">
  <a href="https://github.com/inquiline-app/inquiline/releases/latest"><img src="https://img.shields.io/github/v/release/inquiline-app/inquiline?label=download" alt="Latest version"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-lightgrey" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="Apache 2.0 license"></a>
</p>

<p align="center"><a href="https://github.com/inquiline-app/inquiline/releases/latest"><b>Download Inquiline</b></a> · <a href="#install">How to install</a> · <a href="#good-to-know">Good to know</a></p>

<p align="center"><img src="docs/images/windows.jpg" alt="Wikipedia, the game Mindustry and a clock app, each in its own Mac window"></p>

An app you add to Inquiline doesn't open inside a phone-shaped box. It gets a window of its own, an icon in the Dock and Launchpad, a place in Spotlight and Finder, and its notifications arrive in Notification Center. Behind it runs real Android 15, on your Mac's own chip. Inquiline is free and open source, with no account and nothing to sign up for.

## Double-click an APK

<p align="center"><img src="docs/images/install.gif" width="720" alt="Double-clicking Wikipedia.apk in Finder installs it, and Wikipedia opens in its own window"></p>

Open an `.apk` file, or an app bundle such as `.xapk`, `.apkm` or `.apks`, and a few seconds later the app is in your Applications folder. Games that download their data on first launch do so as on a phone. With Google Play added, apps come from the Play Store instead.

## Windows that fit

<p align="center"><img src="docs/images/resize.gif" width="560" alt="Wikipedia's window is made narrow and Wikipedia switches to its phone layout, then widened back to its tablet layout"></p>

Make a window wider and the app lays itself out again for the new size, with its tablet layout if it has one, rather than stretching a phone screen. Games keep their shape and scale up to the window, up to full screen.

## Notifications in Notification Center

<p align="center"><img src="docs/images/notifications.gif" width="400" alt="A timer runs out while another app is in front, its notification appears at the top of the screen, and clicking it brings the clock app forward"></p>

Apps notify you while you work in something else, even with no window open. Clicking a notification opens the app on what it's about, such as the chat that got a message, and chats can be answered right from the notification. With **Open at Login**, they arrive as soon as your Mac starts.

## Each app's own settings

<p align="center"><img src="docs/images/app-settings.png" width="360" alt="The gear menu of an app window: Permissions, Ad Blocking with a slider set to Balanced, and Data with the app's sizes and buttons to show it in Finder or clear its cache or data"></p>

The gear in each window holds what Android's Settings would for that app:

- **Permissions** the app asks for, each with a switch, notifications included.
- **Ad Blocking** with four levels, from Off to Strong. It uses the same lists as uBlock Origin, AdGuard's list for ads in apps and games, and the list for your Mac's language, and they update on their own every day. It works in the app and in the web pages it shows, and counts what it blocked.
- **Data:** how much space the app takes, its folder in Finder, and Clear Cache or Clear Data.

## Games

Games run on your Mac's GPU, with Vulkan 1.3 and OpenGL ES 3.2, at up to 60 frames a second, and macOS gives them Game Mode. Touch-only games can be played with the keyboard and mouse: put keys on buttons, a W A S D stick on the joystick, look around with the mouse, and play several taps with one key. Xbox, PlayStation and MFi controllers work in games that support them, and can also drive the on-screen controls of games that don't.

## Your data stays on your Mac

Nothing about what you do in Android leaves your Mac through Inquiline. Inquiline itself only asks GitHub once a day whether there's a new version, and the ad blocker fetches its lists from their publishers. Other apps can't connect to Android, its disk in Finder opens only with a password Inquiline makes for your Mac, and Inquiline's folder is closed to other user accounts.

## Not an emulator

<p align="center"><img src="docs/images/how-it-works.svg" width="720" alt="Diagram: on your Mac, each Android app is a Mac app with its own window, Dock icon and notifications; it talks to Android 15 in a small virtual machine on Apple's Hypervisor framework, whose graphics run on the Mac's GPU through gfxstream, MoltenVK and Metal"></p>

Android runs in a small virtual machine, built on the virtualization Apple includes in macOS. Android's Arm apps run on your Mac's Apple Silicon as they are, without translation, and draw with its GPU through Metal. Each frame reaches the app's window as Android drew it, without video compression.

## Requirements

- A Mac with Apple Silicon (M1 or later)
- macOS 14 Sonoma or later
- 8 GB of memory; 16 GB or more is better for big games
- About 3 GB of free disk space, plus room for your apps

So far it's been tested on a Mac mini with M4 (macOS 27) and a MacBook Air with M2 and 8 GB (macOS 26). If you try it on another Mac, please [tell us how it went](https://github.com/inquiline-app/inquiline/issues/new/choose), whether it works or not.

## Install

1. Download `Inquiline-<version>-arm64.dmg` from [Releases](https://github.com/inquiline-app/inquiline/releases) and open it.
2. Drag **Inquiline** onto the Applications folder. (If you open it from elsewhere, it offers to move itself there.)
3. Open it. Inquiline isn't notarized by Apple yet (that needs a paid developer account), so macOS stops it the first time:
   - **macOS 15 Sequoia and later:** after the warning, open **System Settings > Privacy & Security**, scroll down, and choose **Open Anyway** next to Inquiline.
   - **macOS 14 Sonoma:** Control-click Inquiline, choose **Open**, then **Open** again.

   You only do this once.

Inquiline lives in the menu bar. The first time, it unpacks Android, which takes under a minute. It checks for new versions once a day, or when you choose **Check for Updates…**.

## Adding apps

- **From an APK:** double-click an `.apk` file, or choose **Add APK…** from Inquiline in the menu bar.
- **From Google Play:** Google's apps can't be included, but you can add them yourself: download [MindTheGapps for Android 15 arm64](https://github.com/MindTheGapps/15.0.0-arm64/releases/latest), choose **Install Google Play…** from the menu bar, then **Choose Zip…**, and pick the zip without opening it. If Safari unpacked it, it moved the zip to the Trash: put it back from there, then choose it. More in [docs/google-play.md](docs/google-play.md).

Each app you add appears in your Applications folder and in Launchpad; you can move it into a folder of your own there. To remove one, move it to the Trash: it's removed from Android with its data, as deleting an app on a phone is.

## Using apps

| Mac | Android |
|---|---|
| Click and drag | Touch |
| Scroll, pinch, rotate | Scroll, pinch, rotate |
| Typing | Text input |
| Esc | Back |
| Cmd+C, Cmd+X, Cmd+V, Cmd+A | Copy, cut, paste, select all |
| Cmd+K | Keyboard controls for games |
| Ctrl+Cmd+F | Full screen |

- **The toolbar** shows the frame rate and has buttons for keyboard controls, mute, turning between portrait and landscape, and the app's settings. **View > Customize Toolbar** changes it.
- **Windows** open where and as large as you left them, and an app closed in full screen opens in full screen.
- **Closing a window quits the app**, as swiping it away on a phone does. Apps keep running while their window is in the back or minimized.
- **Files:** choose **Show Files in Finder** from the menu bar, or **Show in Finder** in an app's settings. Android's storage and each app's own folders appear as the **Android** disk.
- **Android rests** when no app needs it, as a phone does, and wakes for notifications and alarms. When your Mac needs memory, Android closes apps in the background.
- **Android follows your Mac:** its language, dark mode, time zone and 24-hour clock are your Mac's, and its storage is your Mac's free space.

## Good to know

- **The first launch of a big game is slow.** The game's graphics programs (shaders) are prepared for your Mac's GPU, which can take a few minutes for large 3D games. Later launches are much faster.
- **Not certified by Google.** Apps that check the device's integrity, such as most banking apps and some streaming apps, may refuse to run. Google may also limit Google Play on uncertified devices; **Register with Google…** in the menu bar helps with that.
- **Not for sensitive apps.** This preview's Android is a development build with root access, so don't use it for banking, payments or other sensitive accounts.
- **Missing hardware:** no camera, microphone, location or vibration yet.
- **Memory:** Android can use up to 12 GB on Macs with 16 GB or more, 4 GB on others, and gives back what it frees.
- **Logs:** Inquiline, its engine and Android keep logs on your Mac, about 50 MB at most, for finding what went wrong. They stay there: only **Report a Problem…** gathers them, into a zip you can look at and send yourself, with your name, e-mail addresses, web addresses and numbers that could identify you taken out.

Inquiline is an early preview: expect rough edges, and please report problems with **Report a Problem…** in the menu bar, or [open an issue](https://github.com/inquiline-app/inquiline/issues).

App data lives in `~/Library/Application Support/Inquiline`. Deleting that folder resets Android, and deletes every app and its data.

**To uninstall,** move Inquiline to the Trash while it's running in the menu bar: it removes the apps you added, Android with everything in it, and its own settings, caches and logs, leaving nothing behind.

## How it works

- A Linux virtual machine, run by QEMU on Apple's Hypervisor framework, runs Android 15 ([Redroid](https://github.com/remote-android/redroid-doc)).
- Android's Vulkan reaches the Mac's GPU through [gfxstream](https://android.googlesource.com/platform/hardware/google/gfxstream) and [MoltenVK](https://github.com/KhronosGroup/MoltenVK); its OpenGL ES is ANGLE on that Vulkan.
- Each app runs on its own Android display. Its frames are copied once on the GPU into memory its window shares with the VM.
- Sound goes through a virtual sound card to CoreAudio, controllers through virtual USB devices, and files to Finder through a local network disk that only Inquiline can open.
- Ad blocking is a small VPN and filtering proxy inside Android, for the apps you choose, using uBlock Origin's lists and rules.

More detail is in [Research/linux-gpu](Research/linux-gpu/README.md).

## Building

Building needs Xcode, Homebrew and the VM's parts; see [Research/linux-gpu](Research/linux-gpu/README.md).

```bash
Scripts/build-app.sh --dmg
```

This writes `build/Inquiline.app` and the release disk image. `Scripts/make-appcast.sh` then adds it to `appcast.xml`, which [Sparkle](https://sparkle-project.org) reads to offer updates; it signs it with the update key in the Keychain. To try a first launch without touching your data, start the app with `INQUILINE_HOME` set to an empty folder with a short path, such as `/tmp/inquiline` (the VM's sockets are in it, and macOS limits socket paths to 104 characters). That copy keeps its apps in the folder too.

## License

Inquiline is licensed under the [Apache License 2.0](LICENSE). It includes open source software under other licenses, among them the GPL; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the full list and where to get the source code.

The apps shown above are [Wikipedia](https://github.com/wikimedia/apps-android-wikipedia), [Mindustry](https://github.com/Anuken/Mindustry) and [Fossify Clock](https://github.com/FossifyOrg/Clock), all open source, installed from [F-Droid](https://f-droid.org).

Android is a trademark of Google LLC. Mac, macOS and Apple Silicon are trademarks of Apple Inc. Inquiline isn't affiliated with or endorsed by Google or Apple.
