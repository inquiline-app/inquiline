package io.github.inquiline.notifications;

import android.content.res.Configuration;
import android.os.LocaleList;

/**
 * Sets Android's languages, in order, as Settings > Languages does, so Android speaks the Mac's.
 * Nothing changes when they're the same: a change makes every open app redraw. Run by Inquiline
 * as Android's shell user with app_process:
 *   app_process / io.github.inquiline.notifications.Languages tr-TR,en-US
 */
public final class Languages {
    public static void main(String[] args) throws Exception {
        LocaleList wanted = LocaleList.forLanguageTags(args[0]);
        Object manager = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
        Configuration current = (Configuration) manager.getClass().getMethod("getConfiguration").invoke(manager);
        if (current.getLocales().equals(wanted)) {
            System.out.println("same");
            return;
        }
        Configuration change = new Configuration();
        change.setLocales(wanted);
        // As Settings marks it: the user chose these, so Android keeps them across restarts.
        Configuration.class.getField("userSetLocale").setBoolean(change, true);
        manager.getClass()
                .getMethod("updatePersistentConfigurationWithAttribution", Configuration.class, String.class, String.class)
                .invoke(manager, change, "com.android.shell", null);
        System.out.println("ok");
    }
}
