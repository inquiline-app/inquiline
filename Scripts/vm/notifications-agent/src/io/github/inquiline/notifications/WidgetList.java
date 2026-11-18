package io.github.inquiline.notifications;

import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProviderInfo;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.List;

/**
 * The widgets an app offers, as a phone's widget picker lists them, for Inquiline to offer the
 * same in the Mac's widget gallery. Run with app_process:
 *   app_process / io.github.inquiline.notifications.WidgetList <package>
 * Prints one JSON array: each widget's provider, name, smallest and resizable size in dp, and
 * its preview picture as PNG in base64 when it has one. Widgets that must be set up before they
 * show anything (a configuration screen that isn't optional) are left out for now.
 */
public final class WidgetList {
    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        Object thread = Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
        Context system = (Context) thread.getClass().getMethod("getSystemContext").invoke(thread);
        AppWidgetManager manager = AppWidgetManager.getInstance(system);
        List<AppWidgetProviderInfo> providers = manager.getInstalledProvidersForPackage(args[0], null);
        JSONArray out = new JSONArray();
        if (providers != null) {
            for (AppWidgetProviderInfo info : providers) {
                boolean mustConfigure = info.configure != null
                        && (info.widgetFeatures & AppWidgetProviderInfo.WIDGET_FEATURE_CONFIGURATION_OPTIONAL) == 0;
                if (mustConfigure) continue;
                JSONObject widget = new JSONObject();
                widget.put("provider", info.provider.flattenToString());
                widget.put("label", info.loadLabel(system.getPackageManager()));
                float density = system.getResources().getDisplayMetrics().density;
                widget.put("minWidth", Math.round(info.minWidth / density));
                widget.put("minHeight", Math.round(info.minHeight / density));
                widget.put("minResizeWidth", Math.round(info.minResizeWidth / density));
                widget.put("minResizeHeight", Math.round(info.minResizeHeight / density));
                widget.put("resizeMode", info.resizeMode);
                widget.put("maxResizeWidth", Math.round(info.maxResizeWidth / density));
                widget.put("maxResizeHeight", Math.round(info.maxResizeHeight / density));
                // The home screen cells it asks for (Android 12 on); 0 when it doesn't say.
                widget.put("targetCellWidth", info.targetCellWidth);
                widget.put("targetCellHeight", info.targetCellHeight);
                Drawable preview = info.loadPreviewImage(system, 320);
                if (preview != null) widget.put("preview", png(preview));
                out.put(widget);
            }
        }
        System.out.println(out.toString());
        System.out.flush();
        // Binder threads would keep the process alive.
        System.exit(0);
    }

    private static String png(Drawable drawable) {
        int width = Math.max(1, Math.min(drawable.getIntrinsicWidth(), 1024));
        int height = Math.max(1, Math.min(drawable.getIntrinsicHeight(), 1024));
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        drawable.setBounds(0, 0, width, height);
        drawable.draw(new Canvas(bitmap));
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
        return Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP);
    }
}
