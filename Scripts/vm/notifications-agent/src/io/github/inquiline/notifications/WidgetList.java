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
 * its preview picture as PNG in base64 when it has one, and whether it must be set up first.
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
                JSONObject widget = new JSONObject();
                if (mustConfigure) widget.put("configure", true);
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
                String preview = preview(system, info, density);
                if (preview != null) widget.put("preview", preview);
                out.put(widget);
            }
        }
        System.out.println(out.toString());
        System.out.flush();
        // Binder threads would keep the process alive.
        System.exit(0);
    }

    /**
     * The picture a phone's widget picker shows: the widget's preview picture; else its preview
     * layout (Android 12 on), laid out at its default size; else its app's icon.
     */
    private static String preview(Context system, AppWidgetProviderInfo info, float density) {
        Drawable picture = info.loadPreviewImage(system, 320);
        if (picture != null) return png(picture);
        if (info.previewLayout != 0) {
            try {
                Context app = system.createPackageContext(info.provider.getPackageName(),
                        Context.CONTEXT_INCLUDE_CODE | Context.CONTEXT_IGNORE_SECURITY);
                android.view.View view = android.view.LayoutInflater.from(app).inflate(info.previewLayout, null);
                int width = Math.round(Math.max(info.minWidth, info.targetCellWidth * 90 * density - 10 * density));
                int height = Math.round(Math.max(info.minHeight, info.targetCellHeight * 90 * density - 10 * density));
                view.measure(android.view.View.MeasureSpec.makeMeasureSpec(width, android.view.View.MeasureSpec.EXACTLY),
                        android.view.View.MeasureSpec.makeMeasureSpec(height, android.view.View.MeasureSpec.EXACTLY));
                view.layout(0, 0, width, height);
                Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
                view.draw(new Canvas(bitmap));
                return png(bitmap);
            } catch (Exception | LinkageError ignored) {
                // Its own views, which only its app can draw: its icon stands in.
            }
        }
        Drawable icon = info.loadIcon(system, 320);
        return icon == null ? null : png(icon);
    }

    private static String png(Bitmap bitmap) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
        return Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP);
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
