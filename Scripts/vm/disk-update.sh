# Runs on an older or new disk once, after disk-update.tar is unpacked onto it (see
# AndroidRuntime.updateDiskIfNeeded). It holds what unpacking files can't do.
# 20: resize2fs, which inquiline-boot runs, from Alpine's packages, offline and checked
# against the keys the disk already has.
mount -t proc proc /proc 2>/dev/null
apk add --no-network --no-cache -q /var/inquiline/packages/*.apk && rm -rf /var/inquiline/packages
