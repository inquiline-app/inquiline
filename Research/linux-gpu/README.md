# Linux GPU route

Runs Android on the Mac GPU without Google's emulator or any Google binaries. The app bundles this stack.

## Stack

Android 15 (Redroid) > Alpine with Fedora's kernel > QEMU 11.1.2 with rutabaga_gfx and gfxstream, built by `Scripts/vm/build-qemu.sh` > MoltenVK > Metal. QEMU boots the kernel directly, with no firmware.

Inside Android:
- Vulkan is Mesa's gfxstream guest driver, `vulkan.gfxstream.so`, which sends Vulkan commands to gfxstream on the Mac.
- OpenGL ES is Android's own ANGLE on that Vulkan: ES 3.2 with ASTC and ETC2.
- Buffers come from minigbm, `gralloc.cros`, which is already in the image.

## Measured

On an M4, gfxstream route:
- SuperTuxKart (ES 3.1 through ANGLE) held 60 FPS in a race. Every frame took 16.7 ms.
- PPSSPP drew its interface with native Vulkan.
- Video through scrcpy's encoder was intact.
- QEMU used about 4.3 GB after boot, with Android idle.

Old virgl route, for comparison: 1945 Air Force reached 59 FPS. It was limited to ES 3.0.

## Settings that matter

- `ro.hardware.gralloc=cros`, `ro.hardware.vulkan=gfxstream`, and `ro.hardware.egl=angle` with `persist.graphics.egl=angle`. These are written by `gpu_config.sh` on the disk.
- `debug.angle.feature_overrides_enabled=exposeNonConformantExtensionsAndVersions:exposeES32ForTesting` makes ANGLE give GLES 3.2. MoltenVK has everything 3.2 needs except `VK_EXT_custom_border_color`, which ANGLE treats as a blocker. Without it, only `GL_EXT_texture_border_clamp` with an arbitrary color is missing. SuperTuxKart runs at 60 FPS on the 3.2 context.
- Claims match reality, because the Play Store filters games by them:
  - GLES 3.2 (`ro.opengles.version=196610`, the image's own value);
  - no `android.hardware.opengles.aep`, which needs border clamp;
  - `android.hardware.vulkan.version` 1.3, where the image claims 1.1.
- QEMU's device is `virtio-gpu-rutabaga-pci,gfxstream-vulkan=on,x-gfxstream-gles=on,x-gfxstream-composer=on,hostmem=2G,x-gfxstream-features=GuestVulkanOnly:enabled;GuestVulkanMaxApiVersion:1.3`. gfxstream splits features on `;` as well as `,`, which keeps them out of QEMU's own comma syntax.
  - With `GuestVulkanOnly`, the Mac needs no OpenGL ES of its own.
  - QEMU 11 offers blob alignment, so Fedora's stock virtio-gpu module works on 16 KB pages.
- In QEMU's environment:
  - `ANDROID_EMU_VK_ICD=moltenvk`.
  - `VK_DRIVER_FILES` names `Resources/vulkan/MoltenVK_icd.json`.
  - `DYLD_FALLBACK_LIBRARY_PATH` is `Frameworks`, because gfxstream opens the Vulkan loader by name.
  - `DYLD_INSERT_LIBRARIES` loads `libmemory-release.dylib`.
- `androidboot.redroid_gpu_mode=host`, with the kernel argument `selinux=0`.
- The guest needs `loop` (`max_loop=64`) and `dm_verity`, and `/dev/mapper/control` passed in as `/dev/device-mapper`.

## Frames to the window

Android's frames reach the window without video encoding.

On Android:
- Our scrcpy server build, with `frames=true`, has the virtual display draw into an `ImageReader`.
- For each frame it waits for the drawing to finish (`Image.getFence`).
- `Vendor/frames` (JNI) then turns the buffer into its virtio-gpu resource id. It gets the `AHardwareBuffer`'s native handle, then calls `DRM_IOCTL_PRIME_FD_TO_HANDLE` and `DRM_IOCTL_VIRTGPU_RESOURCE_INFO`.
- The video socket carries the resource id and a frame number. Control message 100 returns the frame.

On the Mac:
- gfxstream's frame server (`patches/gfxstream/0101`) listens on `INQUILINE_FRAMES_SOCKET`. It gives each window a POSIX shared memory object. The VM side creates it, because Swift can't call variadic `shm_open` with `O_CREAT`.
- On request, it copies the resource's ColorBuffer into that memory on the GPU. The copy is `patches/gfxstream/0004` from mini-android-emulator-mac, extended to keep one host-memory import per window.
- `FrameRenderer` keeps three slots in that memory and wraps each as a `MTLTexture` on a no-copy `MTLBuffer`. It draws them into a `CAMetalLayer`. Display widths must be a multiple of 4, for the 16-byte row alignment.
- Measured in Subway Surfers: 60 FPS drawn by the window, which used about 7% CPU. The server used about 4%; there is no encoder and no decoder.

## Virtual displays

On Android 15 the shell user lacks `ADD_TRUSTED_DISPLAY`, and scrcpy drops root to shell. So the server runs through `su 1000`, with its package name patched to `android` (see `Vendor/scrcpy-server.patch`). Build it with d8 from build-tools 36: d8 from build-tools 34 crashes with a NullPointerException.

## Shader compiling while games load

Games build their pipelines while loading, and each one becomes a Metal library: SPIR-V to MSL in MoltenVK, then Metal's compiler. Metal caches the result in `$(getconf DARWIN_USER_CACHE_DIR)/io.github.inquiline.Inquiline/com.apple.metal`, so only a game's first launch pays for it. Asphalt Legends, empty cache, M4: main menu after about 7.5 minutes; second launch about 1 minute.

- Two locks made those compiles one at a time, found on 2026-11-10 by sampling the engine while Asphalt Legends loaded with an empty Metal cache (11+ minutes, Metal's compiler at about 55%):
  - gfxstream runs each app's Vulkan commands in one order across all its threads (`seqno` in `vk_decoder.cpp`), so a thread's next command waited, spinning, for another thread's pipeline to finish compiling. Pipeline creation now gives its turn up before compiling (patch `gfxstream/0103`): nothing the app sends depends on a pipeline before it has it back.
  - MoltenVK compiled a restored pipeline cache's shaders one by one in `vkCreatePipelineCache` (Asphalt's logo), and held its shader cache lock while compiling. Both now compile at the same time (patch `moltenvk/0100`).
  - Result, empty Metal cache, M4: Asphalt Legends' main menu at 59 FPS after about 3.5 minutes, instead of more than 11.
- With compiles in parallel the CPU became the limit, so the guest driver's spinning mattered again: it now sleeps once a wait passes 5 ms (Mesa patch 0101, disk revision 12). Sleeping after 2000 spins instead cost about 15% of Asphalt's frame rate (47-50 FPS instead of 57-59), as frames' own short waits slept too. Empty Metal cache: Asphalt 202 s → 144 s, Free Fire 118 s → 85 s; menu frame rate unchanged (57-58 FPS).
- Upstream gfxstream's guest driver waits for the host by spinning, 50 million `sched_yield`s before it sleeps, as the Android emulator expects spare cores. While a game compiles its shaders, its loading threads spin this way and take most of the Mac's cores (QEMU at about 800% in Asphalt Legends), which starves Metal's compiler and makes the first screens run at about 1 FPS. Sleeping after 1000 spins brought QEMU to 5-110% without changing the load time; it was taken out again (disk revision 8) to keep upstream's behaviour. Waking the guest with a virtio-gpu interrupt when the reply is written would be the clean way.
- Where the time goes, 159 of Asphalt's shaders as MoltenVK writes them, empty cache: MSL source to a Metal library 0.095 s each, pipelines from those 0.009 s each. 91% is Metal reading MSL (a trivial shader takes 0.003 s). Metal compiles up to 10 shaders at once (16 synthetic ones: 0.46 s together, 0.10 s each one by one), but games ask for pipelines one at a time and wait for each, and MoltenVK compiles a restored pipeline cache's shaders one at a time in `vkCreatePipelineCache` (Asphalt's logo).
- Tried and set aside:
  - Compiling outside MoltenVK's pipeline cache lock, a restored cache's shaders on first use or in the background: helped little alone; with more requests at once, ANGLE's small UI shaders waited behind the game's and Android closed Asphalt as not responding.
  - Gfxstream returning pipelines at once, compiling them on 8 threads and skipping draws until ready (as emulators do): Asphalt's menu at about 50 s instead of minutes, but objects missing at first, sound breaking up while compiling, and no Android driver works that way.
  - Shaders through DXIL (`../dxil-path.md`): about 5 times faster per shader in a standalone test, but in the app its pipelines drew nothing, and it needs Apple's Metal Shader Converter (behind a developer sign-in) and much more work.
- Not done: opening an app once out of sight after install so its shaders compile before the user's first launch.

## MoltenVK

`build-moltenvk.sh` builds MoltenVK 1.4.2 with the private Metal API and a SPIRV-Cross fix (`patches/spirv-cross`).

The bug it fixes:
- When a fragment shader writes an output array, such as `gl_FragData[8]`, and the render pass has fewer color attachments, MoltenVK masks out the extra locations.
- SPIRV-Cross still put those array elements in the output struct, without `[[color(n)]]`, so Metal refused the whole shader.
- Free Fire logged 4146 pipeline errors and stayed black; Asphalt drew dialogs without content.
- With the fix, masked elements stay in the local array, as a whole masked variable does. Free Fire then had 0 errors.

KosmicKrisp drew these games correctly too, but it idled at about 400% CPU and 10 GB.

## Why not Venus

Venus reaches the Mac GPU and showed Vulkan 1.3 in Android. On macOS, though, virglrenderer can't hand an Android buffer to Venus's separate render server: `vkGetMemoryResourcePropertiesMESA` fails with `invalid res_id`. SurfaceFlinger then crashes as soon as ANGLE imports a buffer. This happens with both the GBM and minigbm gralloc. gfxstream keeps all GPU work in QEMU's process, so it doesn't have this problem.

## Limits

- Texture border clamp with an arbitrary border color isn't available, so the Extension Pack isn't claimed.
- gfxstream logs `Could not export ColorBuffer memory`. It does no visible harm.

## Sound

Android has a sound card, and QEMU plays it on the Mac (`-audiodev coreaudio -device virtio-sound-pci`). This replaces scrcpy's audio capture, whose remote submix added about 50 to 150 ms and sometimes muted the media stream.

- The kernel loads `virtio_snd`. `/dev/snd/*` is given to group audio (1005) before the container starts, which copies it.
- The image's `audio.primary.default` is AOSP's stub, which sends sound nowhere. `Vendor/audio` is that stub with tinyalsa 1.1.1 writing to card 0, device 0. It is built by `build-guest-audio.sh` as `audio.primary.redroid.so`, which Android's loader prefers by `ro.hardware=redroid`.
  - Periods are 10 ms and the card holds four, so Android measured about 60 ms of delay.
  - A card that has just started can refuse its first write once, so the HAL opens it again.
  - `pcm_writei` returns 0 for the write that starts the card.
  - Without the card, a stream falls back to the stub's timing.
- Android's own volumes are set to their highest once it's ready (`cmd audio set-volume`), as the Mac's volume is the one that counts. scrcpy's capture took the mix before volume, so the default music volume of 5 of 15 (-33 dB) went unnoticed until the card played it.
- No microphone yet: QEMU's CoreAudio backend has no capture (`Can not open virtio-sound.in`). Android records silence, as before.

## Game controllers

`GamepadBridge` reads the Mac's controllers through GameController and plugs each into the app in front with scrcpy's UHID messages (12 to 14), using scrcpy's Xbox 360 report. On Android 15, the server ties each HID device to its app's display, so two windows don't share a controller.

The disk side:
- `uhid` is loaded and `/dev/uhid` is world-writable, because the server runs as Android's system user.
- The container's `/dev` is a tmpfs copied once at start, so new input devices never show up there. Binding the kernel's `/dev/input` doesn't work either: its contents are emptied when the container starts, and devtmpfs removes the folder with its last device, which leaves the bind pointing at a deleted folder.
- So `mdev -df` (busybox, listening on netlink) runs `inquiline-input` for each `input/eventN`. It makes the node in `/run/inquiline-input`, which Android binds as `/dev/input`, in group input (1004) as ueventd would.
- Each node is made world-readable first and narrowed after: EventHub opens it on the inotify event, before `chgrp` could run.

## Disk updates

A release whose disk changes what Android runs on raises `diskRevision` in `AndroidRuntime.swift`. It also ships `disk-update.tar` with:
- the changed files, at their paths on the disk;
- `disk-update.sh` for anything to delete.

On the next start of an older disk, and on the first start of a new one (so `android-disk.xz` needn't be rebuilt for each revision), Linux alone boots with `init=/bin/sh`, unpacks the tar from a second drive, and powers off. This takes about a second, and apps and data stay. A single changed file, such as `vulkan.gfxstream.so`, can be swapped in the tar with Python's `tarfile`, keeping root ownership.

The tar holds every change since revision 1, so any older disk gets them all. To make it for revision 5, mount the new disk in the Fedora guest and run:

`tar -cf disk-update.tar -C <disk> var/inquiline/{gpu_config.sh,libdrm.so,vulkan.gfxstream.so,vulkan-version.xml,no-aep.xml} usr/local/bin/inquiline-{android,boot,input} etc/mdev.conf lib/modules/<kernel>/kernel/drivers/hid/uhid.ko lib/modules/<kernel>/modules.* -C Scripts/vm disk-update.sh`

Put the result in `.build/vm`.

## Before release

- Offer the sources of the GPL and LGPL parts next to each release:
  - QEMU, with `Scripts/vm/patches/qemu`;
  - glib and gettext;
  - the Linux kernel (Fedora's source RPM);
  - Android's GPL parts.

## Building

1. `Scripts/vm/build-guest-vulkan.sh <mesa-26.2.5>` builds `vulkan.gfxstream.so`. It needs the NDK named in `android-aarch64.ini`, Bison 3 or later, and Python 3.10 or later.
2. `Scripts/vm/build-disk.sh` runs in a Fedora guest and fills an empty disk. It needs `libdrm.so` and `vulkan.gfxstream.so` there, plus the Redroid image.
3. `Scripts/vm/collect-parts.sh` takes that guest's kernel and the disk.
4. `Scripts/vm/build-qemu.sh` builds the engine, then `Scripts/vm/build-moltenvk.sh` adds MoltenVK with the SPIRV-Cross fix (needs Xcode). It needs `brew install meson ninja rust pkgconf glib pixman libslirp vulkan-loader`.
5. `Scripts/build-app.sh --zip` builds the release: a 480 MB zip.

`android-aarch64.ini` is the Meson cross file for the NDK.

## Memory after an app closes

Activity Monitor's figure is `phys_footprint`, which also counts compressed pages. It stays high after a game closes, until Inquiline quits. This was measured on a 4 GB guest:

| | Idle | In game | After closing |
|---|---|---|---|
| Stock QEMU | 4.33 GB | 6.61 GB | 6.43 GB |
| All three below | 2.96 GB | 5.68 GB | 3.10 GB |

- QEMU's balloon discard uses `MADV_DONTNEED`, which doesn't lower the footprint on macOS. `Scripts/vm/memory-release.c` interposes it (from a dylib: dyld ignores interposing from the main executable) and instead unmaps the range from the VM, replaces it with `mmap(MAP_FIXED)` and maps it back.
- Guest file cache holds most of what a game used. Dropping it with `/proc/sys/vm/drop_caches` frees it.
- `page_reporting.page_reporting_order=2` reports free blocks down to 16 KB. The default only reports 2 MB and larger.

The app does this when its last window closes. A failure in `memory-release.c` stops Android outright. 12 cycles during gameplay caused no failures.

On a 16 GB Mac (6.4 GB guest) with Oniro, the footprint fell from 7.6 GB to about 3.6-4.1 GB within 30 seconds of closing, across 8 cycles with no failures.

## Traps

- Don't change a display's size under a running app. Non-resizable apps get letterboxed with a restart prompt, `force_resizable_activities` crops them, and a 3840x2160 request kills the encoder.
- To turn the screen, rotate it (scrcpy control message 11) rather than resizing it. Apps locked to one way ignore the rotation.
- When checking frames from a raw H.264 file, decode all of it. `ffmpeg -sseof` lands on an earlier frame, which can look like a broken layout.

- The power-off port must stay outside 5555-5585. The adb server probes those ports, and a connection powers the VM off.
- Android mutes its media stream when an app first plays sound, so `AudioBridge` keeps checking. While muted, a volume key up does nothing until a key down has come first.
