package io.github.inquiline.notifications;

import android.app.ActivityOptions;
import android.app.PendingIntent;
import android.os.IBinder;
import android.service.notification.StatusBarNotification;

import java.io.BufferedReader;
import java.io.InputStreamReader;

/**
 * Runs a notification's own action, as tapping it on a phone does, on the display of the app's
 * Inquiline window: a chat opens on its conversation, a mail on that mail. Run by Inquiline as
 * root with app_process, which Android lets open an app's screen; the helper's own service,
 * in the background, can't:
 *   app_process / io.github.inquiline.notifications.Open <key>
 * It takes the action at once and says "ready", as opening the app may clear the notification,
 * then reads the display of the app's window on its input and runs the action there.
 */
public final class Open {
    public static void main(String[] args) throws Exception {
        String key = args[0];
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "notification");
        Object manager = Class.forName("android.app.INotificationManager$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
        StatusBarNotification[] active = (StatusBarNotification[]) manager.getClass()
                .getMethod("getActiveNotificationsWithAttribution", String.class, String.class)
                .invoke(manager, "root", null);
        PendingIntent action = null;
        if (active != null) {
            for (StatusBarNotification sbn : active) {
                if (key.equals(sbn.getKey())) action = sbn.getNotification().contentIntent;
            }
        }
        if (action == null) {
            System.out.println("none");
            return;
        }
        System.out.println("ready");
        System.out.flush();
        String line = new BufferedReader(new InputStreamReader(System.in)).readLine();
        if (line == null) return;
        int display = Integer.parseInt(line.trim());
        ActivityOptions options = ActivityOptions.makeBasic();
        if (display > 0) options.setLaunchDisplayId(display);
        options.setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED);
        action.send(options.toBundle());
        System.out.println("ok");
    }
}
