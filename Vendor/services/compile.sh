# Inquiline: precompiles Android's system server jars against the patched services.jar, with the
# filters and class loader contexts the image used, into a copy of /system/framework/oat/arm64.
set -e
O=/data/local/tmp/oat-arm64; rm -rf $O; cp -a /system/framework/oat/arm64 $O
BOOT=/apex/com.android.art/javalib/boot.art:/system/framework/boot-framework.art
compile() { # jar context filter output [profile]
  /apex/com.android.art/bin/dex2oat64 --dex-file=$1 --dex-location=$1 --oat-file=$4.odex ${5:+--profile-file=$5} \
    --instruction-set=arm64 --instruction-set-variant=generic --instruction-set-features=default \
    --class-loader-context="$2" --compiler-filter=$3 --compilation-reason=prebuilt \
    --runtime-arg -Xbootclasspath:$BOOTCLASSPATH --boot-image=$BOOT -j6 >/dev/null 2>&1 || echo "FAILED $1"
}
name() { echo "$1" | sed 's|^/||; s|/|@|g'; }
prev=""
for jar in $(echo $SYSTEMSERVERCLASSPATH | tr ':' ' '); do
  if [ "$jar" = /system/framework/services.jar ]; then
    # With the image's profile, carried over to the patched jar (build-services.sh), whose dex
    # checksums the profile names.
    rm -f $O/services.art
    compile $jar "PCL[$prev]" speed-profile $O/services /data/local/tmp/inquiline-services.prof
  elif [ -n "$prev" ]; then
    compile $jar "PCL[$prev]" speed $O/$(name $jar)@classes
  fi
  prev="$prev:$jar"; prev=${prev#:}
done
for jar in $(echo $STANDALONE_SYSTEMSERVER_JARS | tr ':' ' '); do
  compile $jar "PCL[];PCL[$prev]" speed $O/$(name $jar)@classes
done
du -sh $O
