#!/bin/bash
# Builds Vendor/inquiline-framework-overlay.apk from Scripts/vm/framework-overlay: changes to
# Android's own settings, which build-disk.sh puts in /vendor/overlay, as a phone maker's are.
# Needs Android's build-tools 36 and platform 36 in $ANDROID_HOME and a JDK.
set -euo pipefail
cd "$(dirname "$0")/../.."
ANDROID_HOME=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
TOOLS="$ANDROID_HOME/build-tools/36.0.0"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
"$TOOLS/aapt2" compile --dir Scripts/vm/framework-overlay/res -o "$OUT/res.zip"
"$TOOLS/aapt2" link -o "$OUT/unsigned.apk" -I "$ANDROID_HOME/platforms/android-36/android.jar" \
    --manifest Scripts/vm/framework-overlay/AndroidManifest.xml "$OUT/res.zip"
"$TOOLS/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
# A partition's overlay needn't be signed by anyone in particular, only signed: a key made for each build.
keytool -genkeypair -keystore "$OUT/key.jks" -storepass inquiline -keypass inquiline -alias overlay \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Inquiline" >/dev/null 2>&1
"$TOOLS/apksigner" sign --v4-signing-enabled false --ks "$OUT/key.jks" --ks-pass pass:inquiline --out Vendor/inquiline-framework-overlay.apk "$OUT/aligned.apk"
echo "Built Vendor/inquiline-framework-overlay.apk"
