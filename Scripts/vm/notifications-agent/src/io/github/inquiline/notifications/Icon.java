package io.github.inquiline.notifications;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.graphics.drawable.AdaptiveIconDrawable;
import android.graphics.drawable.Drawable;
import android.os.Looper;

import java.io.BufferedOutputStream;
import java.io.OutputStream;

/**
 * Writes an app's icon to standard output as a PNG of 1024 pixels, filled to its edges, for its
 * Mac app's icon, which macOS shapes itself. An adaptive icon gives its layers' visible part,
 * the middle 72 of 108 dp, as Android's own launchers show it; an older, plain icon is cut to
 * what it draws, without the transparent margin around it. Run as root with app_process:
 *   app_process / io.github.inquiline.notifications.Icon <package>
 */
public final class Icon {
    private static final int SIZE = 1024;

    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        Object thread = Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
        Context system = (Context) thread.getClass().getMethod("getSystemContext").invoke(thread);
        // The sharpest the app has, as for a phone's densest screen: a Mac icon is 1024 pixels.
        android.content.pm.PackageManager packages = system.getPackageManager();
        android.content.pm.ApplicationInfo app = packages.getApplicationInfo(args[0], 0);
        Drawable icon = app.icon != 0
                ? packages.getResourcesForApplication(app).getDrawableForDensity(app.icon, android.util.DisplayMetrics.DENSITY_XXXHIGH, null)
                : packages.getApplicationIcon(app);

        Bitmap bitmap = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        if (icon instanceof AdaptiveIconDrawable) {
            AdaptiveIconDrawable adaptive = (AdaptiveIconDrawable) icon;
            int layer = SIZE * 108 / 72, offset = (SIZE - layer) / 2;
            for (Drawable part : new Drawable[] {adaptive.getBackground(), adaptive.getForeground()}) {
                if (part != null) {
                    part.setBounds(offset, offset, offset + layer, offset + layer);
                    part.draw(canvas);
                }
            }
        } else {
            Bitmap plain = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888);
            icon.setBounds(0, 0, SIZE, SIZE);
            icon.draw(new Canvas(plain));
            Rect drawn = drawnPart(plain);
            canvas.drawBitmap(plain, drawn, new Rect(0, 0, SIZE, SIZE), null);
        }
        OutputStream out = new BufferedOutputStream(System.out);
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        out.flush();
    }

    /** Where the icon draws anything: its transparent margin left out. */
    private static Rect drawnPart(Bitmap bitmap) {
        int left = SIZE, top = SIZE, right = 0, bottom = 0;
        for (int y = 0; y < SIZE; y += 2) {
            for (int x = 0; x < SIZE; x += 2) {
                if ((bitmap.getPixel(x, y) >>> 24) > 16) {
                    left = Math.min(left, x);
                    top = Math.min(top, y);
                    right = Math.max(right, x + 2);
                    bottom = Math.max(bottom, y + 2);
                }
            }
        }
        return right > left && bottom > top ? new Rect(left, top, right, bottom) : new Rect(0, 0, SIZE, SIZE);
    }
}
