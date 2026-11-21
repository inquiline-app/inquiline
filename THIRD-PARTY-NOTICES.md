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
| [KDE Connect](https://kdeconnect.kde.org) for Android | 1.37.3 | GPL-2.0-only or GPL-3.0-only | <https://invent.kde.org/network/kdeconnect-android> (tag v1.37.3); the app as F-Droid builds it, <https://f-droid.org/packages/org.kde.kdeconnect_tp/> | none; a separate app installed inside Android, which brings its notifications to the Mac |

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

## StevenBlack/hosts

The ad blocking list (Scripts/vm/notifications-agent/assets/blocklist.txt) is the unified hosts list of https://github.com/StevenBlack/hosts, under the MIT License:

Copyright (c) 2026 Steven Black

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## EasyList and EasyPrivacy

The ad blocking rules in Scripts/vm/notifications-agent/assets/easylist.txt and easyprivacy.txt are EasyList and EasyPrivacy (https://easylist.to), by the EasyList authors, used under the Creative Commons Attribution-ShareAlike 3.0 Unported license (https://creativecommons.org/licenses/by-sa/3.0/); they are dual-licensed with the GNU General Public License version 3. They are included unchanged.

## uBlock filters

The rules in Scripts/vm/notifications-agent/assets/ublock-filters.txt, ublock-quick-fixes.txt, ublock-unbreak.txt, ublock-privacy.txt, ublock-badware.txt, ublock-cookies.txt and ublock-annoyances.txt are uBlock Origin's own filter lists (https://github.com/uBlockOrigin/uAssets), by Raymond Hill and contributors, under the GNU General Public License version 3 (https://www.gnu.org/licenses/gpl-3.0.html). It is included unchanged, as data the helper reads; its source is the file itself.

## AdGuard Mobile Ads filter

The rules in Scripts/vm/notifications-agent/assets/adguard-mobile.txt are AdGuard's Mobile Ads filter (https://github.com/AdguardTeam/AdguardFilters), in the form AdGuard publishes for uBlock Origin, by AdGuard and contributors, under the GNU General Public License version 3. It is included unchanged, as data the helper reads.

## uBlock Origin's regional lists

Scripts/vm/notifications-agent/assets/regions.json is taken from uBlock Origin's catalog of regional lists (assets/assets.json, https://github.com/gorhill/uBlock, GPL-3.0): each list's name, languages and source. The lists themselves are not included; the helper fetches those for Android's languages from their sources, under their own authors' licenses, as uBlock Origin does.

## uBlock Origin scriptlets

Scripts/vm/notifications-agent/assets/scriptlets.json holds uBlock Origin's scriptlets (https://github.com/gorhill/uBlock, src/js/resources), Copyright (C) Raymond Hill, under the GNU General Public License version 3, taken from its source unchanged by Scripts/vm/build-scriptlets.mjs. The ad blocker adds them to web pages, as uBlock Origin does; their source is the file itself and uBlock Origin's repository.

## EasyList Cookie, Social and Newsletters lists (Fanboy)

The rules in Scripts/vm/notifications-agent/assets/easylist-cookies.txt, easylist-social.txt and easylist-newsletters.txt are Fanboy's lists of the EasyList project (https://easylist.to, https://secure.fanboy.co.nz), used under the Creative Commons Attribution 3.0 license (https://creativecommons.org/licenses/by/3.0/) and EasyList's licence (https://easylist.to/pages/licence.html). They are included unchanged.

## uBlock Origin stand-in resources

The files in Scripts/vm/notifications-agent/assets/redirects are uBlock Origin's web accessible resources (https://github.com/gorhill/uBlock, src/web_accessible_resources), under the GNU General Public License version 3, copied unchanged by Scripts/vm/build-scriptlets.mjs.

## Brave's ad blocking engine (adblock-rust)

The helper inside Android (Vendor/inquiline-notifications.apk) contains libinquiline_adblock.so, built from Scripts/vm/adblock-engine by Scripts/vm/build-adblock-engine.sh. It is Brave's adblock-rust (https://github.com/brave/adblock-rust), unchanged, under the Mozilla Public License 2.0 (https://www.mozilla.org/MPL/2.0/); its source is that repository and https://crates.io/crates/adblock/0.13.6. It is linked with these Rust libraries, unchanged, from https://crates.io under their own licenses:

| Library | Version | License |
|---|---|---|
| adblock | 0.13.6 | MPL-2.0 |
| addr | 0.15.6 | MIT/Apache-2.0 |
| aho-corasick | 1.1.5 | Unlicense OR MIT |
| arrayvec | 0.7.8 | MIT OR Apache-2.0 |
| base64 | 0.23.1 | MIT OR Apache-2.0 |
| bitflags | 2.13.2 | MIT OR Apache-2.0 |
| bytes | 1.12.2 | MIT |
| cesu8 | 1.1.0 | Apache-2.0/MIT |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 |
| combine | 4.6.9 | MIT |
| displaydoc | 0.2.7 | MIT OR Apache-2.0 |
| either | 1.19.0 | MIT OR Apache-2.0 |
| flatbuffers | 25.12.19 | Apache-2.0 |
| icu_collections | 2.4.0 | Unicode-3.0 |
| icu_locale_core | 2.4.0 | Unicode-3.0 |
| icu_normalizer | 2.4.0 | Unicode-3.0 |
| icu_normalizer_data | 2.4.0 | Unicode-3.0 |
| icu_properties | 2.4.0 | Unicode-3.0 |
| icu_properties_data | 2.4.0 | Unicode-3.0 |
| icu_provider | 2.4.0 | Unicode-3.0 |
| idna | 1.1.0 | MIT OR Apache-2.0 |
| idna_adapter | 1.2.2 | Apache-2.0 OR MIT |
| itertools | 0.14.0 | MIT OR Apache-2.0 |
| itoa | 1.0.19 | MIT OR Apache-2.0 |
| jni | 0.21.1 | MIT/Apache-2.0 |
| jni-sys | 0.3.1 | MIT OR Apache-2.0 |
| jni-sys | 0.4.1 | MIT OR Apache-2.0 |
| jni-sys-macros | 0.4.1 | MIT OR Apache-2.0 |
| litemap | 0.8.3 | Unicode-3.0 |
| log | 0.4.35 | MIT OR Apache-2.0 |
| memchr | 2.8.3 | Unlicense OR MIT |
| percent-encoding | 2.3.2 | MIT OR Apache-2.0 |
| potential_utf | 0.1.6 | Unicode-3.0 |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 |
| psl | 2.1.260 | MIT/Apache-2.0 |
| psl-types | 2.0.11 | MIT/Apache-2.0 |
| quote | 1.0.47 | MIT OR Apache-2.0 |
| regex | 1.13.2 | MIT OR Apache-2.0 |
| regex-automata | 0.4.19 | MIT OR Apache-2.0 |
| regex-syntax | 0.8.12 | MIT OR Apache-2.0 |
| rustc-hash | 2.1.3 | Apache-2.0 OR MIT |
| seahash | 4.1.0 | MIT |
| serde | 1.0.229 | MIT OR Apache-2.0 |
| serde_core | 1.0.229 | MIT OR Apache-2.0 |
| serde_derive | 1.0.229 | MIT OR Apache-2.0 |
| serde_json | 1.0.154 | MIT OR Apache-2.0 |
| smallvec | 1.16.6 | MIT OR Apache-2.0 |
| stable_deref_trait | 1.2.1 | MIT OR Apache-2.0 |
| syn | 2.0.119 | MIT OR Apache-2.0 |
| syn | 3.0.10 | MIT OR Apache-2.0 |
| synstructure | 0.14.0 | MIT |
| thiserror | 1.0.69 | MIT OR Apache-2.0 |
| thiserror-impl | 1.0.69 | MIT OR Apache-2.0 |
| tinystr | 0.8.5 | Unicode-3.0 |
| unicode-ident | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| utf8_iter | 1.1.0 | Apache-2.0 OR MIT |
| utf_types | 1.0.0 | Apache-2.0 OR MIT |
| writeable | 0.6.4 | Unicode-3.0 |
| yoke | 0.8.4 | Unicode-3.0 |
| yoke-derive | 0.8.4 | Unicode-3.0 |
| zerofrom | 0.1.8 | Unicode-3.0 |
| zerofrom-derive | 0.1.8 | Unicode-3.0 |
| zerotrie | 0.2.5 | Unicode-3.0 |
| zerovec | 0.11.9 | Unicode-3.0 |
| zerovec-derive | 0.11.7 | Unicode-3.0 |
| zmij | 1.0.23 | MIT |
