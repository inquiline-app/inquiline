# To do

## Before the first preview release

- [ ] Fresh install on the MacBook Air M2: first launch, Google Play, a game, a controller.
- [ ] Try a controller now that it stays plugged in and drives the front window only.
- [x] Name Inquiline: bundle identifier `io.github.inquiline-app.Inquiline`, apps `io.github.inquiline-app.app.<package>`, data in `~/Library/Application Support/Inquiline`, apps in `~/Applications/Inquiline Apps`; all moved over from the earlier names on first launch. Logo: an i whose dot (Inquiline, orange) sits at the corner of two bars, the Mac's (silver, vertical) and Android's (green); Resources/Logo has the grid. Still to do: buying inquiline.app.
- [ ] Memory: 12 GB on Macs with 16 GB or more, 4 GB below (0.1.8). Measured 2026-11-11, M4 16 GB, Asphalt, Call of Duty and PUBG open and one played: engine 5.4 GB asleep, 8.7 / 11 / 14 GB with one, two, three games, 16 GB while playing; the Mac's swap grew from 4.6 to 9.3 GB with no slowdown felt; closing them brought the engine back to 5.4 GB and free memory to 74% within seconds. Earlier note: With 12 GB and four games open, Android used 5.5 GB while the engine held 12 GB and the Mac swapped. Freed memory does go back (closing the apps took it down to 3.5 GB in seconds); the rest is likely the games' GPU memory on the Mac, which no limit on Android covers. Measure how it splits. Oniro once drew its whole scene red; it didn't happen again at 12 GB in the same place, so memory wasn't the cause. Watch for it, and note what was going on when it does (how long the game ran, whether its window had been in the back).
- [x] README for users: install and first open, using apps, what to expect, how it works, licenses and trademarks.
- [x] Third-party licenses: THIRD-PARTY-NOTICES.md lists every part in the app and on Android's disk with its version, license and source, with an offer of the GPL and LGPL source; the texts are in Resources/Licenses and the app. Update it when a part changes.
- [x] GitHub repository and release 0.1.0 (DMG, Sparkle updates).
- [ ] A screenshot or GIF at the top of the README.

## Compatibility

- [ ] Find why Genshin Impact shows as incompatible ("available only for your other devices"). Multitouch is declared now; still missing: a gyroscope and a chipset name (`ro.soc.*`). Genshin 7.0 lists minimum chipsets, so Play may filter by chipset. Needs the APK's manifest to tell.
- Play Store check, 2026-11-11, 22 popular games: 20 can be installed (PUBG, CoD, Free Fire, Star Rail, ZZZ, Wuthering Waves, Clash Royale, Clash of Clans, Brawl Stars, Minecraft, MLBB, Subway Surfers, Candy Crush, eFootball, FC Mobile, Honor of Kings, Among Us, Stumble Guys, 8 Ball Pool, Asphalt). Not: Genshin, Pokémon GO (needs GPS). Roblox isn't listed because it's blocked in Turkey.
- [ ] See how a banking app reacts (Play Integrity, root).
- [ ] Compare with an Android tablet.

## Features

- [x] Multi-touch from trackpad gestures (pinch, rotate). Still to do: declare `touchscreen.multitouch`.
- [ ] Settings in the menu bar: memory limit, pausing apps in the back, and other choices.
- [x] FPS indicator, sound and rotate buttons in the window's toolbar (the Mac's own NSToolbar, customizable).
- [ ] Play Store auto-updates: check whether they ever run, since Android only runs while an app is open (charging and idle conditions).
- [x] Key mapping for apps without keyboard or controller support, with macros (0.1.9).
- [ ] Microphone (QEMU's Core Audio backend has no capture).
- [ ] Android notifications as Mac notifications.
- [ ] Camera and location from the Mac.
- [ ] Vibration on the controller.

## Security

- [ ] ADB with key authentication (any Mac process can reach it on 127.0.0.1 now).
- [ ] Keep Android from reaching the Mac's own local services through the NAT.
- [ ] A user build without root.
- [ ] SELinux on.

## Performance

- [ ] First launch of big games (shaders): see `linux-gpu/README.md` for what was tried. Open options: wake the guest with a virtio-gpu interrupt instead of spinning; open apps once after install.
- [ ] Installing a new build seems to empty the engine's Metal shader cache (`$(getconf DARWIN_USER_CACHE_DIR)/io.github.inquiline-app.Inquiline/com.apple.metal` was created anew at the first start after an install), so the next launch of every game compiles everything again, and while it does Android's sound stutters 2–3 times a second (AudioFlinger "throttle end"). Confirm, and find what keys the cache (the ad hoc signature changes with every build): an update shouldn't cost every game its cache.

## Housekeeping

- [ ] Move the Android NDK and the Fedora build VM out of the temporary folder they're in now, which macOS may clear.
