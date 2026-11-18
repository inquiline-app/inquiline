package io.github.inquiline.notifications;

import android.os.IBinder;

/**
 * Brings an app's task into focus, as touching its screen does on a phone, so Android's
 * assistant reads that app: Inquiline runs it with app_process before the assistant opens.
 *   app_process / io.github.inquiline.notifications.Focus <task>
 */
public final class Focus {
    public static void main(String[] args) throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "activity_task");
        Object tasks = Class.forName("android.app.IActivityTaskManager$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
        tasks.getClass().getMethod("setFocusedTask", int.class).invoke(tasks, Integer.parseInt(args[0]));
    }
}
