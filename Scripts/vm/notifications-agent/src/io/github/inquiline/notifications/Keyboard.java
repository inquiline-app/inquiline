package io.github.inquiline.notifications;

import android.os.IBinder;

/**
 * Where a screen's on-screen keyboard shows, as scrcpy sets it for its screens
 * (WindowManager.setDisplayImePolicy): on the screen itself (0, while a phone shows the window
 * and types by touch) or nowhere (2, as Inquiline's windows type with the Mac's keyboard).
 *   app_process / io.github.inquiline.notifications.Keyboard <display> <policy>
 */
public final class Keyboard {
    public static void main(String[] args) throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "window");
        Object windows = Class.forName("android.view.IWindowManager$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
        windows.getClass().getMethod("setDisplayImePolicy", int.class, int.class)
                .invoke(windows, Integer.parseInt(args[0]), Integer.parseInt(args[1]));
    }
}
