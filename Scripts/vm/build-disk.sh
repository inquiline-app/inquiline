#!/bin/sh
# Builds the Android VM's disk from nothing, so it holds nothing from the machine
# that built it. Run as root in a Fedora guest with the same kernel, the guest GPU
# libraries in $1 (libdrm.so from Mesa, vulkan.gfxstream.so from build-guest-vulkan.sh and
# audio.primary.redroid.so from build-guest-audio.sh),
# the Redroid image in podman, and the empty target disk at $2.
set -eu

LIBS=$1
TARGET=$2
ROOT=/mnt/inquiline-disk
RELEASES=https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64
IMAGE=docker.io/redroid/redroid:15.0.0_64only-latest
KERNEL=$(uname -r)
MODULES="virtio_balloon nft_compat virtio_net virtio_gpu overlay loop dm_verity fuse veth bridge tun nf_tables nft_ct nft_fib_inet
nft_fib_ipv4 nft_fib_ipv6 nft_masq nft_chain_nat nf_nat nf_conntrack ip_tables ip6_tables iptable_nat
iptable_filter iptable_mangle ip6table_nat ip6table_filter xt_MASQUERADE xt_nat xt_comment xt_addrtype
xt_conntrack xt_mark xt_multiport xt_tcpudp erofs squashfs uhid virtio_snd"

mkfs.ext4 -q -F -L inquiline "$TARGET"
mkdir -p "$ROOT"
mount "$TARGET" "$ROOT"
trap 'umount -lR "$ROOT" 2>/dev/null || true' EXIT

MINIROOT=$(curl -fsSL "$RELEASES/latest-releases.yaml" | sed -n 's/.*file: \(alpine-minirootfs-.*\.tar\.gz\)/\1/p' | head -1)
curl -fsSL "$RELEASES/$MINIROOT" | tar -xz -C "$ROOT"
echo "base: $MINIROOT"

cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
mount -t proc proc "$ROOT/proc"
mount --bind /dev "$ROOT/dev"
chroot "$ROOT" /sbin/apk add --no-cache -q podman socat kmod iptables samba-server
umount "$ROOT/proc" "$ROOT/dev"
rm -rf "$ROOT/var/cache/apk"/*

# Kernel modules, unpacked. Everything else the kernel needs is built in.
TREE="$ROOT/lib/modules/$KERNEL"
mkdir -p "$TREE"
for module in $MODULES; do
    modprobe -D "$module" 2>/dev/null | sed -n 's/^insmod //p' | awk '{print $1}'
done | sort -u | while read -r file; do
    relative=${file#/usr/lib/modules/$KERNEL/}
    relative=${relative#/lib/modules/$KERNEL/}
    mkdir -p "$TREE/$(dirname "$relative")"
    xz -dc "$file" > "$TREE/${relative%.xz}"
done
cp "/usr/lib/modules/$KERNEL/modules.builtin" "/usr/lib/modules/$KERNEL/modules.builtin.modinfo" \
    "/usr/lib/modules/$KERNEL/modules.order" "$TREE/"
chroot "$ROOT" /sbin/depmod "$KERNEL"

mkdir -p "$ROOT/var/inquiline"
cp "$LIBS"/*.so "$ROOT/var/inquiline/"
chmod 644 "$ROOT"/var/inquiline/*.so
# Vulkan goes to the Mac through gfxstream, GLES is Android's own ANGLE on that Vulkan,
# and buffers come from minigbm (gralloc.cros), which the gfxstream driver understands.
cat > "$ROOT/var/inquiline/gpu_config.sh" <<'EOF'
#!/system/bin/sh
chmod 666 /dev/dri/renderD128 /dev/dri/card0
setprop ro.hardware.gralloc cros
setprop ro.hardware.vulkan gfxstream
setprop ro.hardware.egl angle
setprop persist.graphics.egl angle
# MoltenVK has everything GLES 3.2 needs except custom border colors, so ANGLE stops at 3.1
# unless told otherwise. Only clamp-to-border with an arbitrary color is then missing.
setprop debug.angle.feature_overrides_enabled exposeNonConformantExtensionsAndVersions:exposeES32ForTesting
EOF
chmod 755 "$ROOT/var/inquiline/gpu_config.sh"
# What Android tells apps and the Play Store must match what it has, or the Play Store offers
# games that then fail, and hides ones that would run. The image claims GLES 3.2, which ANGLE
# now gives, but also the Extension Pack, which needs custom border colors, and only Vulkan 1.1.
cat > "$ROOT/var/inquiline/vulkan-version.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- Inquiline: gfxstream gives Vulkan 1.3 (0x00403000). -->
<permissions>
    <feature name="android.hardware.vulkan.version" version="4206592" />
</permissions>
EOF
cat > "$ROOT/var/inquiline/product-build.prop" <<'EOF'
# Inquiline: the name Google Play and accounts show for this Android, "Inquiline Mac".
####################################
# from generate_common_build_props
# These properties identify this partition image.
####################################
ro.product.product.brand=Inquiline
ro.product.product.device=redroid_arm64_only
ro.product.product.manufacturer=Inquiline
ro.product.product.model=Mac
ro.product.product.name=redroid_arm64_only
ro.product.build.date=Thu Jun 26 22:56:34 CST 2025
ro.product.build.date.utc=1750949794
ro.product.build.fingerprint=redroid/redroid_arm64_only/redroid_arm64_only:15/BP1A.250505.005.D1/eng.root:userdebug/test-keys
ro.product.build.id=BP1A.250505.005.D1
ro.product.build.tags=test-keys
ro.product.build.type=userdebug
ro.product.build.version.incremental=eng.root
ro.product.build.version.release=15
ro.product.build.version.release_or_codename=15
ro.product.build.version.sdk=35
ro.product.build.version.sdk_minor=0
####################################
# from variable ADDITIONAL_PRODUCT_PROPERTIES
####################################
ro.product.build.16k_page.enabled=false
ro.product.page_size=4096
ro.build.characteristics=default
ro.product.ab_ota_partitions=
ro.product.cpu.pagesize.max=16384
# Value overridden by post_process_props.py. Original value: default
ro.dalvik.vm.enable_uffd_gc=true
####################################
# from variable PRODUCT_PRODUCT_PROPERTIES
####################################
persist.wm.extensions.enabled=true
# end of file

EOF
cat > "$ROOT/var/inquiline/touchscreen.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- Inquiline: a touchscreen with up to ten fingers at once, as the Mac's trackpad (pinch,
     rotate) and keyboard controls give, so Play Store lists games that need several. -->
<permissions>
    <feature name="android.hardware.touchscreen" />
    <feature name="android.hardware.touchscreen.multitouch" />
    <feature name="android.hardware.touchscreen.multitouch.distinct" />
    <feature name="android.hardware.touchscreen.multitouch.jazzhand" />
    <feature name="android.hardware.faketouch" />
    <feature name="android.hardware.faketouch.multitouch.distinct" />
    <feature name="android.hardware.faketouch.multitouch.jazzhand" />
</permissions>
EOF
cat > "$ROOT/var/inquiline/gyroscope.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- Inquiline: a gyroscope declared, as the accelerometer and compass are, so Play Store lists
     games that use one for optional tilt aiming. A Mac has none; an app finds no sensor and
     leaves tilt off. -->
<permissions>
    <feature name="android.hardware.sensor.gyroscope" />
</permissions>
EOF
cat > "$ROOT/var/inquiline/no-aep.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- Inquiline: no Android Extension Pack, which needs custom border colors. -->
<permissions />
EOF

cat > "$ROOT/etc/inittab" <<'EOF'
::sysinit:/usr/local/bin/inquiline-boot
::respawn:/usr/local/bin/inquiline-android
::respawn:/bin/busybox mdev -df
::respawn:/usr/bin/socat TCP-LISTEN:5555,fork,reuseaddr TCP:10.88.0.2:5555
::respawn:/usr/bin/socat TCP-LISTEN:5000,bind=0.0.0.0,reuseaddr SYSTEM:/usr/local/bin/inquiline-poweroff
::respawn:/usr/sbin/smbd --foreground --no-process-group
::shutdown:/usr/local/bin/inquiline-stop
EOF
mkdir -p "$ROOT/usr/local/bin"
cat > "$ROOT/usr/local/bin/inquiline-boot" <<'EOF'
#!/bin/sh
mount -o remount,rw /
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp
mount -t cgroup2 cgroup2 /sys/fs/cgroup
mount --make-rshared /
hostname inquiline
modprobe loop max_loop=64
for module in virtio_balloon dm_verity overlay virtio_gpu virtio_net veth bridge fuse nf_tables nft_compat nft_chain_nat nft_masq nft_ct \
    xt_MASQUERADE xt_nat xt_comment xt_addrtype xt_conntrack xt_tcpudp xt_mark xt_multiport uhid virtio_snd; do modprobe "$module"; done
# The sound card, which QEMU plays on the Mac, for Android's audio server (group audio, 1005).
chgrp -R 1005 /dev/snd && chmod 660 /dev/snd/*
# Game controllers on the Mac reach Android as HID devices that scrcpy's server, running
# as Android's system user, creates here.
chmod 666 /dev/uhid
mkdir -p /run/inquiline-input
ip link set lo up
ip link set eth0 up
udhcpc -q -f -n -i eth0 -s /usr/share/udhcpc/default.script
sysctl -qw net.ipv4.ip_forward=1
# The unpacked disk loses some of its holes, and QEMU turns this back into them.
fstrim / &
EOF
# Android's files for Finder (see AndroidFiles.swift). Samba resolves this machine's name,
# which takes seconds without an entry.
echo "127.0.0.1 inquiline" >> "$ROOT/etc/hosts"
cat > "$ROOT/etc/samba/smb.conf" <<'EOF'
[global]
	server string = Inquiline
	server role = standalone server
	map to guest = bad user
	disable netbios = yes
	smb ports = 445
	load printers = no
	disable spoolss = yes
	logging = file
	max log size = 100
	nt acl support = no
	ea support = yes
	vfs objects = catia fruit streams_xattr
	fruit:metadata = stream
	fruit:posix_rename = yes
	fruit:delete_empty_adfiles = yes
	veto files = /.DS_Store/
	delete veto files = yes
[Android]
	path = /var/inquiline/files
	guest ok = yes
	read only = no
	force user = root
	inherit owner = unix only
	create mask = 0660
	directory mask = 0771
EOF
cat > "$ROOT/usr/local/bin/inquiline-android" <<'EOF'
#!/bin/sh
A=/var/inquiline
mkdir -p $A/data $A/files
podman rm -f redroid >/dev/null 2>&1
# Google Play, if the user added it: Android's product and system_ext folders with Google's files merged in.
G=$A/data/inquiline-gapps
EXTRA=""
[ -d $G/product ] && EXTRA="-v $G/product:/system/product -v $G/system_ext:/system/system_ext"
# podman's default of 2048 tasks counts threads, and a large game with Android's own
# services passes it: the game then can't start a thread and crashes.
exec podman run --rm $EXTRA --name redroid --ip 10.88.0.2 --privileged --pull=never --shm-size=65536000 --pids-limit=-1 \
  --device /dev/mapper/control:/dev/device-mapper -v $A/data:/data -v $A/files:/data/inquiline-files:rshared \
  -v /run/inquiline-input:/dev/input -v $A/gpu_config.sh:/vendor/bin/gpu_config.sh:ro \
  -v $A/libdrm.so:/vendor/lib64/libdrm.so:ro -v $A/vulkan.gfxstream.so:/vendor/lib64/hw/vulkan.gfxstream.so:ro \
  -v $A/audio.primary.redroid.so:/vendor/lib64/hw/audio.primary.redroid.so:ro \
  -v $A/vulkan-version.xml:/vendor/etc/permissions/android.hardware.vulkan.version-1_1.xml:ro \
  -v $A/no-aep.xml:/vendor/etc/permissions/android.hardware.opengles.aep.xml:ro \
  -v $A/touchscreen.xml:/vendor/etc/permissions/android.hardware.touchscreen.xml:ro \
  -v $A/gyroscope.xml:/vendor/etc/permissions/android.hardware.sensor.gyroscope.xml:ro \
  -v $A/product-build.prop:/system/product/etc/build.prop:ro \
  docker.io/redroid/redroid:15.0.0_64only-latest androidboot.redroid_gpu_mode=host androidboot.use_memfd=1 \
  androidboot.redroid_width=810 androidboot.redroid_height=1440 androidboot.redroid_dpi=320 androidboot.redroid_fps=60
EOF
cat > "$ROOT/usr/local/bin/inquiline-input" <<'EOF'
#!/bin/sh
# mdev runs this for each input event device the kernel adds or removes, such as a game
# controller from the Mac. Android finds them in /run/inquiline-input, which it sees as
# /dev/input: unlike the kernel's own folder, it stays when the last device goes. The nodes
# are as Android's ueventd would make them, in group input (1004).
D=/run/inquiline-input
NODE=$D/${MDEV##*/} # MDEV is input/eventN
case "$ACTION" in
add)
    IFS=: read -r major minor < "/sys$DEVPATH/dev"
    rm -f "$NODE"
    # Android opens it the moment it appears, before it could be given to group input.
    mknod -m 666 "$NODE" c "$major" "$minor" && chgrp 1004 "$NODE" && chmod 660 "$NODE"
    ;;
remove)
    rm -f "$NODE"
    ;;
esac
EOF
cat > "$ROOT/etc/mdev.conf" <<'EOF'
# Inquiline runs mdev only to hand input devices to Android (see inquiline-input).
# The kernel's devtmpfs makes every node in /dev, so mdev makes none.
input/event[0-9]+ 0:0 600 ! */usr/local/bin/inquiline-input
.* 0:0 600 !
EOF
cat > "$ROOT/usr/local/bin/inquiline-poweroff" <<'EOF'
#!/bin/sh
/bin/busybox poweroff
EOF
cat > "$ROOT/usr/local/bin/inquiline-stop" <<'EOF'
#!/bin/sh
podman stop -t 5 redroid >/dev/null 2>&1
sync
mount -o remount,ro / 2>/dev/null
sync
EOF
chmod 755 "$ROOT"/usr/local/bin/*
ln -sf /bin/busybox "$ROOT/sbin/init"

mkdir -p "$ROOT/etc/containers"
cat > "$ROOT/etc/containers/policy.json" <<'EOF'
{"default":[{"type":"insecureAcceptAnything"}]}
EOF
cat > "$ROOT/etc/containers/storage.conf" <<'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF

[ -s /etc/containers/policy.json ] || cp "$ROOT/etc/containers/policy.json" /etc/containers/policy.json
# Flattened, because deleting files in a new image layer wouldn't make it smaller.
# Android here only ever sees QEMU's virtual GPU, drawn with Mesa's virgl driver.
ENTRYPOINT=$(podman inspect --format '{{json .Config.Entrypoint}}' "$IMAGE")
CONTAINER=$(podman create "$IMAGE")
FILES=$(podman mount "$CONTAINER")
rm -f "$FILES"/vendor/lib64/hw/vulkan.*.so "$FILES"/system/fonts/NotoSerifCJK-Regular.ttc
podman export "$CONTAINER" | podman --root "$ROOT/var/lib/containers/storage" --runroot /tmp/inquiline-runroot \
    --storage-driver overlay import -q --change "ENTRYPOINT $ENTRYPOINT" - "$IMAGE"
podman umount "$CONTAINER" >/dev/null
podman rm "$CONTAINER" >/dev/null
umount "$ROOT"/var/lib/containers/storage/overlay 2>/dev/null || true
# Its database records this machine's paths. Podman makes a new one on first use.
rm -rf "$ROOT/var/lib/containers/storage/libpod" "$ROOT"/var/lib/containers/storage/db.sql*
rm -f "$ROOT/etc/resolv.conf"
du -sh "$ROOT" "$ROOT/lib/modules" "$ROOT/var/lib/containers" "$ROOT/usr"
sync
fstrim "$ROOT"
