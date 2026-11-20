package io.github.inquiline.notifications;

import android.app.ActivityOptions;
import android.content.Context;
import android.content.pm.LauncherApps;
import android.content.pm.ShortcutInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.os.Process;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * An app's shortcuts, as holding its icon on a phone's home screen shows them ("New message",
 * a frequent chat), for its Dock menu on the Mac; and opening one, on the display of the app's
 * Inquiline window. Run by Inquiline as root with app_process:
 *   app_process / io.github.inquiline.notifications.Shortcuts list <package>
 *   app_process / io.github.inquiline.notifications.Shortcuts open <package> <id in hex> <display>
 * list prints one JSON array, in the app's own order: each shortcut's id, label and icon as PNG
 * in base64. It runs as Android's system user, as Open does.
 */
public final class Shortcuts {
    /** As many as a phone's launcher shows. */
    private static final int MOST = 5;

    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        // Android's system user, whose package Android's shortcut service takes the caller for,
        // and which Android lets open an app's screen from the background.
        android.system.Os.setgid(1000);
        android.system.Os.setuid(1000);
        Object thread = Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
        Context system = (Context) thread.getClass().getMethod("getSystemContext").invoke(thread);
        LauncherApps launcher = system.getSystemService(LauncherApps.class);
        String packageName = args[1];
        if ("open".equals(args[0])) {
            // The id comes as hex, safe through Android's shell whatever it holds.
            byte[] bytes = new byte[args[2].length() / 2];
            for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) Integer.parseInt(args[2].substring(2 * i, 2 * i + 2), 16);
            String id = new String(bytes, java.nio.charset.StandardCharsets.UTF_8);
            int display = Integer.parseInt(args[3]);
            ActivityOptions options = ActivityOptions.makeBasic();
            if (display > 0) options.setLaunchDisplayId(display);
            launcher.startShortcut(packageName, id, null, options.toBundle(), Process.myUserHandle());
            System.out.println("ok");
        } else {
            LauncherApps.ShortcutQuery query = new LauncherApps.ShortcutQuery();
            query.setPackage(packageName);
            query.setQueryFlags(LauncherApps.ShortcutQuery.FLAG_MATCH_MANIFEST
                    | LauncherApps.ShortcutQuery.FLAG_MATCH_DYNAMIC);
            List<ShortcutInfo> found = launcher.getShortcuts(query, Process.myUserHandle());
            List<ShortcutInfo> shown = new ArrayList<>();
            if (found != null) {
                // The app's own order: those from its manifest first, each kind by its rank.
                for (ShortcutInfo info : found) if (info.isDeclaredInManifest() && info.isEnabled()) shown.add(info);
                List<ShortcutInfo> dynamic = new ArrayList<>();
                for (ShortcutInfo info : found) if (info.isDynamic() && info.isEnabled()) dynamic.add(info);
                shown.sort((a, b) -> a.getRank() - b.getRank());
                dynamic.sort((a, b) -> a.getRank() - b.getRank());
                shown.addAll(dynamic);
            }
            JSONArray out = new JSONArray();
            float density = system.getResources().getDisplayMetrics().density;
            for (ShortcutInfo info : shown) {
                if (out.length() == MOST) break;
                CharSequence label = info.getShortLabel() != null ? info.getShortLabel() : info.getLongLabel();
                if (label == null) continue;
                JSONObject shortcut = new JSONObject();
                shortcut.put("id", info.getId());
                shortcut.put("label", label.toString());
                String icon = icon(launcher, info, density);
                if (icon != null) shortcut.put("icon", icon);
                out.put(shortcut);
            }
            System.out.println(out.toString());
        }
        System.out.flush();
        // Binder threads would keep the process alive.
        System.exit(0);
    }

    /** The shortcut's icon, 64 pixels square, as PNG in base64. */
    private static String icon(LauncherApps launcher, ShortcutInfo info, float density) {
        try {
            Drawable drawable = launcher.getShortcutIconDrawable(info, (int) (density * 160));
            if (drawable == null) return null;
            Bitmap bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888);
            drawable.setBounds(0, 0, 64, 64);
            drawable.draw(new Canvas(bitmap));
            ByteArrayOutputStream png = new ByteArrayOutputStream();
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, png);
            return Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP);
        } catch (Exception e) {
            return null;
        }
    }
}
