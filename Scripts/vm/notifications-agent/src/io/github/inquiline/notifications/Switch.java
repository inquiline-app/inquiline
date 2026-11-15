package io.github.inquiline.notifications;

import android.os.IBinder;

/**
 * Turns an app's notifications on or off as the switch in Android's Settings does, through
 * NotificationManagerService, which takes the permission away without ending the app (taking
 * it with `pm revoke` ends it). Run by Inquiline as root with app_process:
 *   app_process / io.github.inquiline.notifications.Switch <package> <uid> <on|off>
 */
public final class Switch {
    public static void main(String[] args) throws Exception {
        String pkg = args[0];
        int uid = Integer.parseInt(args[1]);
        boolean enabled = "on".equals(args[2]);
        if (!enabled) {
            // NotificationManagerService ends the app too; Android keeps a way that doesn't.
            IBinder permissions = (IBinder) Class.forName("android.os.ServiceManager")
                    .getMethod("getService", String.class).invoke(null, "permissionmgr");
            Object permissionManager = Class.forName("android.permission.IPermissionManager$Stub")
                    .getMethod("asInterface", IBinder.class).invoke(null, permissions);
            permissionManager.getClass()
                    .getMethod("revokePostNotificationPermissionWithoutKillForTest", String.class, int.class)
                    .invoke(permissionManager, pkg, uid / 100000);
            System.out.println("ok");
            return;
        }
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "notification");
        Object manager = Class.forName("android.app.INotificationManager$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
        manager.getClass().getMethod("setNotificationsEnabledForPackage", String.class, int.class, boolean.class)
                .invoke(manager, pkg, uid, enabled);
        System.out.println("ok");
    }
}
