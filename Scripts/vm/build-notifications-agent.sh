#!/bin/bash
# Builds Vendor/inquiline-notifications.apk from Scripts/vm/notifications-agent: the small app inside
# Android that hands its notifications to Inquiline (NotificationBridge.swift), which installs it.
# Needs Android's build-tools 36 and platform 36 in $ANDROID_HOME and a JDK 17.
# Updates must keep the same signature, so it's signed with notifications-agent/agent.jks, made once.
set -euo pipefail
cd "$(dirname "$0")/../.."
ANDROID_HOME=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}
export PATH="$JAVA_HOME/bin:$PATH"
TOOLS="$ANDROID_HOME/build-tools/36.0.0"
PLATFORM="$ANDROID_HOME/platforms/android-36/android.jar"
SRC=Scripts/vm/notifications-agent
KEY=$SRC/agent.jks
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
if [ ! -f "$KEY" ]; then
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KEY" -storepass inquiline -keypass inquiline -alias agent \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Inquiline" >/dev/null 2>&1
fi
mkdir -p "$OUT/classes"
"$JAVA_HOME/bin/javac" --release 17 -classpath "$PLATFORM" -d "$OUT/classes" $(find "$SRC/src" -name '*.java')
"$TOOLS/d8" --release --min-api 35 --lib "$PLATFORM" --output "$OUT" $(find "$OUT/classes" -name '*.class')
"$TOOLS/aapt2" link -o "$OUT/unsigned.apk" -I "$PLATFORM" --manifest "$SRC/AndroidManifest.xml" -A "$SRC/assets"
(cd "$OUT" && zip -q unsigned.apk classes.dex)
"$TOOLS/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$TOOLS/apksigner" sign --v4-signing-enabled false --ks "$KEY" --ks-pass pass:inquiline \
    --out Vendor/inquiline-notifications.apk "$OUT/aligned.apk"
echo "Built Vendor/inquiline-notifications.apk"
