package io.github.inquiline.notifications;

import android.app.usage.StorageStats;
import android.app.usage.StorageStatsManager;
import android.content.Context;
import android.os.Looper;
import android.os.UserHandle;
import android.os.storage.StorageManager;

/**
 * What an app takes on Android's storage, as Settings > Apps > Storage shows it: the app, its
 * data and its cache, in bytes, on one line. Run by Inquiline as root with app_process:
 *   app_process / io.github.inquiline.notifications.Sizes <package>
 */
public final class Sizes {
    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        Object thread = Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
        Context system = (Context) thread.getClass().getMethod("getSystemContext").invoke(thread);
        StorageStatsManager stats = system.getSystemService(StorageStatsManager.class);
        StorageStats s = stats.queryStatsForPackage(StorageManager.UUID_DEFAULT, args[0], UserHandle.getUserHandleForUid(0));
        // Android counts the cache within the data; shown apart, as Settings does.
        System.out.println(s.getAppBytes() + " " + (s.getDataBytes() - s.getCacheBytes()) + " " + s.getCacheBytes());
    }
}
