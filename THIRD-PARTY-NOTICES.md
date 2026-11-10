# Third-party software

Inquiline itself is licensed under the [Apache License 2.0](LICENSE). It includes the software below, under their own licenses. The license texts are in [Resources/Licenses](Resources/Licenses) and, in the app, in `Inquiline.app/Contents/Resources/licenses`.

## Source code

Everything Inquiline adds to or changes in the projects below is in this repository: the patches in `Scripts/vm/patches` and `Vendor/scrcpy-server.patch`, and the scripts that build each part in `Scripts/vm`.

For the parts licensed under the GPL or LGPL, the complete corresponding source code is available from the sources linked below. If any of it is no longer available there, we'll provide it on request, for at least three years after the last release that includes it: open an issue at <https://github.com/inquiline-app/inquiline/issues>.

## In the Mac app

| Component | Version | License | Source | Changes |
|---|---|---|---|---|
| [QEMU](https://www.qemu.org) | 11.1.2 | GPL-2.0-only, some parts GPL-2.0-or-later, LGPL-2.1-or-later, BSD and MIT | <https://gitlab.com/qemu-project/qemu> (tag v11.1.2) | `Scripts/vm/patches/qemu`; runs as `Inquiline Engine` |
| [gfxstream](https://android.googlesource.com/platform/hardware/google/gfxstream) | e9eed53 | Apache-2.0 | <https://github.com/utzcoz/gfxstream> | `Scripts/vm/patches/gfxstream` |
| [rutabaga_gfx](https://github.com/magma-gpu/rutabaga_gfx) | 60603af | BSD-3-Clause | <https://github.com/magma-gpu/rutabaga_gfx> | `Scripts/vm/patches/rutabaga_gfx` |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | 1.4.2 | Apache-2.0 | <https://github.com/KhronosGroup/MoltenVK> (tag v1.4.2) | none |
| [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) | 6c09849 | Apache-2.0 | <https://github.com/KhronosGroup/SPIRV-Cross> | `Scripts/vm/patches/spirv-cross` |
| [Vulkan loader](https://github.com/KhronosGroup/Vulkan-Loader) | 1.4.363.0 | Apache-2.0 | <https://github.com/KhronosGroup/Vulkan-Loader> | none |
| [GLib](https://gitlab.gnome.org/GNOME/glib) | 2.90.1 | LGPL-2.1-or-later | <https://download.gnome.org/sources/glib/2.90/> | none |
| [PCRE2](https://github.com/PCRE2Project/pcre2), inside GLib | 10.46 | BSD-3-Clause | <https://github.com/PCRE2Project/pcre2> | none |
| [libffi](https://github.com/libffi/libffi), inside GLib | 3.5.2 | MIT | <https://github.com/libffi/libffi> | none |
| [zlib](https://zlib.net), inside GLib | 1.3.1 | Zlib | <https://zlib.net/fossils/> | none |
| [proxy-libintl](https://github.com/frida/proxy-libintl), inside GLib | 0.5 | LGPL-2.0-or-later | <https://github.com/frida/proxy-libintl> | none |
| [pixman](https://gitlab.freedesktop.org/pixman/pixman) | 0.46.4 | MIT | <https://cairographics.org/releases/> | none |
| [libslirp](https://gitlab.freedesktop.org/slirp/libslirp) | 4.9.7 | BSD-3-Clause | <https://gitlab.freedesktop.org/slirp/libslirp> | none |
| [Sparkle](https://sparkle-project.org) | 2.10.1 | MIT, with parts under other permissive licenses (see its LICENSE) | <https://github.com/sparkle-project/Sparkle> (tag 2.10.1) | none; updates |
| [scrcpy](https://github.com/Genymobile/scrcpy) server | 5.0.1 | Apache-2.0 | <https://github.com/Genymobile/scrcpy> (tag v5.0.1) | `Vendor/scrcpy-server.patch`; runs inside Android |

GLib, with what it takes in, is a separate dynamic library in `Inquiline.app/Contents/Frameworks`, which you can replace with your own build. `Scripts/vm/build-qemu.sh` builds all of these from the sources above.

## In Android's disk

The disk (`android-disk.xz` in the app, unpacked to `~/Library/Application Support/Inquiline/vm/disk.raw`) runs a small Linux, which runs Android.

| Component | Version | License | Source | Changes |
|---|---|---|---|---|
| [Linux](https://www.kernel.org), as built by Fedora | 7.2.7-200.fc44 | GPL-2.0-only | <https://kojipkgs.fedoraproject.org/packages/kernel/7.2.7/200.fc44/src/> | none |
| [Redroid](https://github.com/remote-android/redroid-doc): Android 15 ([AOSP](https://source.android.com)) | 15.0.0_64only, BP1A.250505.005.D1 | Apache-2.0 and others, listed inside Android (`/system/etc/NOTICE.xml.gz`) | <https://github.com/remote-android/redroid-doc>, <https://android.googlesource.com> | one font and the Vulkan drivers removed |
| [Mesa](https://mesa3d.org) gfxstream Vulkan driver | 26.2.5 | MIT | <https://gitlab.freedesktop.org/mesa/mesa> (tag mesa-26.2.5) | `Scripts/vm/patches/mesa`, `Scripts/vm/guest-headers` |
| [libdrm](https://gitlab.freedesktop.org/mesa/drm) | as Mesa 26.2.5 fetches it | MIT | <https://gitlab.freedesktop.org/mesa/drm> | none |
| Android audio HAL (AOSP stub) | Android 15 | Apache-2.0 | <https://android.googlesource.com> | rewritten for virtio-sound: `Vendor/audio` |
| [tinyalsa](https://github.com/tinyalsa/tinyalsa) | as in AOSP | BSD-3-Clause | <https://android.googlesource.com/platform/external/tinyalsa> | none; in `Vendor/audio/tinyalsa` |
| [Alpine Linux](https://alpinelinux.org) | 3.24.3 | see the packages below | <https://gitlab.alpinelinux.org/alpine/aports> (branch 3.24-stable), <https://distfiles.alpinelinux.org/distfiles/v3.24/> | none |

### Alpine Linux packages

| Package | Version | License |
|---|---|---|
| aardvark-dns | 1.17.1-r0 | Apache-2.0 |
| acl | 2.3.2-r1 | LGPL-2.1-or-later AND GPL-2.0-or-later |
| acl-libs | 2.3.2-r1 | LGPL-2.1-or-later AND GPL-2.0-or-later |
| alpine-baselayout | 3.7.2-r1 | GPL-2.0-only |
| alpine-baselayout-data | 3.7.2-r1 | GPL-2.0-only |
| alpine-keys | 2.6-r0 | MIT |
| alpine-release | 3.24.3-r0 | MIT |
| apk-tools | 3.0.8-r0 | GPL-2.0-only |
| avahi-libs | 0.9_rc4-r0 | LGPL-2.1-or-later |
| brotli-libs | 1.2.1-r0 | MIT |
| busybox | 1.37.0-r31 | GPL-2.0-only |
| busybox-binsh | 1.37.0-r31 | GPL-2.0-only |
| ca-certificates-bundle | 20261020-r0 | MPL-2.0 AND MIT |
| catatonit | 0.2.1-r0 | GPL-2.0-or-later |
| conmon | 2.2.1-r0 | Apache-2.0 |
| containers-common | 0.64.2-r0 | Apache-2.0 |
| crun | 1.30.1-r0 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| cups-libs | 2.4.19-r1 | Apache-2.0 |
| dbus-libs | 1.16.2-r2 | AFL-2.1 OR GPL-2.0-or-later |
| gdbm | 1.26-r0 | GPL-3.0-or-later |
| glib | 2.88.1-r1 | LGPL-2.1-or-later |
| gmp | 6.3.0-r4 | LGPL-3.0-or-later OR GPL-2.0-or-later |
| gnupg-dirmngr | 2.4.9-r1 | GPL-3.0-or-later |
| gnupg-gpgconf | 2.4.9-r1 | GPL-3.0-or-later |
| gnupg-keyboxd | 2.4.9-r1 | GPL-3.0-or-later |
| gnutls | 3.8.13-r0 | LGPL-2.1-or-later |
| gpg | 2.4.9-r1 | GPL-3.0-or-later |
| gpg-agent | 2.4.9-r1 | GPL-3.0-or-later |
| gpgme | 2.0.1-r1 | LGPL-2.1-or-later AND GPL-3.0-or-later |
| gpgsm | 2.4.9-r1 | GPL-3.0-or-later |
| icu-data-en | 78.1-r0 | ICU |
| icu-libs | 78.1-r0 | ICU |
| iptables | 1.8.13-r0 | GPL-2.0-or-later |
| jansson | 2.15.0-r0 | MIT |
| json-c | 0.18-r1 | MIT |
| kmod | 34.2-r1 | GPL-2.0-or-later |
| ldb | 4.23.8-r0 | GPL-3.0-or-later AND LGPL-3.0-or-later |
| libapk | 3.0.8-r0 | GPL-2.0-only |
| libassuan | 3.0.2-r0 | LGPL-2.1-or-later |
| libauth-samba | 4.23.8-r0 | GPL-3.0-or-later AND LGPL-3.0-or-later |
| libblkid | 2.42.3-r1 | LGPL-2.1-or-later |
| libbsd | 0.12.2-r0 | BSD-3-Clause |
| libbz2 | 1.0.8-r6 | bzip2-1.0.6 |
| libcap2 | 2.78-r0 | BSD-3-Clause OR GPL-2.0-only |
| libcrypto3 | 3.5.9-r0 | Apache-2.0 |
| libeconf | 0.8.3-r0 | MIT |
| libffi | 3.5.2-r1 | MIT |
| libgcc | 15.2.0-r5 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| libgcrypt | 1.12.2-r0 | LGPL-2.1-or-later AND GPL-2.0-or-later |
| libgpg-error | 1.61-r0 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| libidn2 | 2.3.8-r0 | GPL-2.0-or-later OR LGPL-3.0-or-later |
| libintl | 1.0-r0 | LGPL-2.1-or-later |
| libksba | 1.7.0-r0 | LGPL-3.0-only AND GPL-2.0-only AND GPL-3.0-only |
| libldap | 2.6.15-r0 | OLDAP-2.8 |
| libmd | 1.2.0-r0 | BSD-3-Clause AND BSD-2-Clause AND ISC AND Beerware AND Public Domain |
| libmnl | 1.0.5-r2 | LGPL-2.1-or-later |
| libmount | 2.42.3-r1 | LGPL-2.1-or-later |
| libncursesw | 6.6_p20260516-r0 | X11 |
| libnftnl | 1.3.1-r0 | GPL-2.0-or-later |
| libsasl | 2.1.28-r9 | BSD-3-Clause-Attribution AND BSD-4-Clause |
| libseccomp | 2.6.1-r0 | LGPL-2.1-or-later |
| libssl3 | 3.5.9-r0 | Apache-2.0 |
| libstdc++ | 15.2.0-r5 | GPL-2.0-or-later AND LGPL-2.1-or-later |
| libtasn1 | 4.21.0-r0 | LGPL-2.1-or-later |
| libunistring | 1.4.2-r0 | GPL-2.0-or-later OR LGPL-3.0-or-later |
| liburing | 2.14-r0 | LGPL-2.1-or-later OR MIT |
| libwbclient | 4.23.8-r0 | GPL-3.0-or-later AND LGPL-3.0-or-later |
| libxtables | 1.8.13-r0 | GPL-2.0-or-later |
| linux-pam | 1.7.1-r2 | BSD-3-Clause |
| lmdb | 0.9.35-r0 | OLDAP-2.8 |
| musl | 1.2.6-r3 | MIT |
| musl-utils | 1.2.6-r3 | MIT AND BSD-2-Clause AND GPL-2.0-or-later |
| ncurses-terminfo-base | 6.6_p20260516-r0 | X11 |
| netavark | 1.17.2-r0 | Apache-2.0 |
| nettle | 3.10.2-r0 | GPL-2.0-or-later OR LGPL-3.0-or-later |
| npth | 1.8-r0 | LGPL-2.0-or-later |
| p11-kit | 0.26.2-r0 | BSD-3-Clause |
| passt | 2026.05.26-r0 | BSD-3-Clause AND GPL-2.0-or-later |
| pcre2 | 10.49-r0 | BSD-3-Clause |
| pinentry | 1.3.2-r0 | GPL-2.0-or-later |
| podman | 5.8.9-r0 | Apache-2.0 |
| popt | 1.19-r4 | MIT |
| readline | 8.3.3-r1 | GPL-3.0-or-later |
| samba-client-libs | 4.23.8-r0 | GPL-3.0-or-later AND LGPL-3.0-or-later |
| samba-common | 4.23.8-r0 | GPL-3.0-or-later AND LGPL-3.0-or-later |
| samba-common-server-libs | 4.23.8-r0 | GPL-3.0-or-later AND LGPL-3.0-or-later |
| samba-libs | 4.23.8-r0 | GPL-3.0-or-later AND LGPL-3.0-or-later |
| samba-server | 4.23.8-r0 | GPL-3.0-or-later AND LGPL-3.0-or-later |
| samba-util-libs | 4.23.8-r0 | GPL-3.0-or-later AND LGPL-3.0-or-later |
| scanelf | 1.3.9-r1 | GPL-2.0-only |
| shadow-libs | 4.18.0-r1 | BSD-3-Clause |
| shadow-subids | 4.18.0-r1 | BSD-3-Clause |
| skalibs-libs | 2.15.0.0-r0 | ISC |
| socat | 1.8.1.3-r0 | GPL-2.0-only WITH OpenSSL-Exception |
| sqlite-libs | 3.53.4-r0 | blessing |
| ssl_client | 1.37.0-r31 | GPL-2.0-only |
| talloc | 2.4.4-r1 | LGPL-3.0-or-later |
| tdb-libs | 1.4.15-r1 | LGPL-3.0-or-later |
| tevent | 0.17.1-r1 | LGPL-3.0-or-later |
| utmps-libs | 0.1.3.3-r0 | ISC |
| xz-libs | 5.8.4-r0 | GPL-2.0-or-later AND 0BSD AND Public-Domain AND LGPL-2.1-or-later |
| zlib | 1.3.2-r1 | Zlib |
| zstd-libs | 1.5.7-r2 | BSD-3-Clause OR GPL-2.0-or-later |
