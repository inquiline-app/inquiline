package io.github.inquiline.notifications;

import android.app.Presentation;
import android.appwidget.AppWidgetHost;
import android.appwidget.AppWidgetHostView;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProviderInfo;
import android.content.ComponentName;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.graphics.drawable.ColorDrawable;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.ImageReader;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.view.PixelCopy;
import android.util.Base64;
import android.util.SizeF;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/**
 * Hosts the widgets placed on the Mac, as a phone's home screen hosts those on it: each is bound
 * to this helper, kept up to date by its app, and laid out at the size of its Mac widget on a
 * screen of its own that nobody sees. Each new picture of it goes to Inquiline as a PNG, at most
 * once a second, as the Mac only redraws widgets now and then anyway.
 *
 * Inquiline is the one that knows which widgets are on the Mac; after Android restarts it places
 * them again, so the host starts empty each time.
 */
final class WidgetHost {
    interface Sink {
        void send(JSONObject message);
    }

    private static final int HOST_ID = 0x1d9e7;
    /** Twice a point per dp, as the Mac's Retina screens draw widgets. */
    private static final int DENSITY = 320;
    private static final long MIN_INTERVAL = 1000;

    private static final class Placed {
        int id;
        VirtualDisplay display;
        ImageReader reader;
        Presentation presentation;
        long lastSent;
        int width, height;
        boolean sendQueued;
        Bitmap latest;
    }

    private final Context context;
    private final Sink sink;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Handler frames;
    private final AppWidgetHost host;
    private final AppWidgetManager manager;
    private final Map<String, Placed> placed = Collections.synchronizedMap(new HashMap<>());

    WidgetHost(Context context, Sink sink) {
        this.context = context;
        this.sink = sink;
        HandlerThread thread = new HandlerThread("inquiline-widgets");
        thread.start();
        frames = new Handler(thread.getLooper());
        manager = AppWidgetManager.getInstance(context);
        host = new AppWidgetHost(context, HOST_ID);
        // What a previous run bound is let go: Inquiline places what the Mac shows again.
        host.deleteHost();
        host.startListening();
    }

    /** Shows the provider's widget at this size in dp, under the Mac's key for it. */
    void place(String key, String provider, int widthDp, int heightDp) {
        main.post(() -> {
            removeNow(key);
            ComponentName component = ComponentName.unflattenFromString(provider);
            if (component == null) return;
            int id = host.allocateAppWidgetId();
            Bundle options = sizeOptions(widthDp, heightDp);
            if (!manager.bindAppWidgetIdIfAllowed(id, component, options)) {
                host.deleteAppWidgetId(id);
                android.util.Log.w("InquilineWidgets", "Not allowed to show " + provider);
                return;
            }
            AppWidgetProviderInfo info = manager.getAppWidgetInfo(id);
            int width = widthDp * DENSITY / 160, height = heightDp * DENSITY / 160;
            Placed widget = new Placed();
            widget.id = id;
            // The screen's own pictures aren't read: the widget's window is copied after each frame
            // it draws (PixelCopy), which also works where the screen's buffers can't be read.
            widget.reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2);
            widget.width = width;
            widget.height = height;
            DisplayManager displays = context.getSystemService(DisplayManager.class);
            widget.display = displays.createVirtualDisplay("inquiline-widget", width, height, DENSITY,
                    widget.reader.getSurface(), 0);
            Context display = context.createDisplayContext(widget.display.getDisplay());
            AppWidgetHostView view = host.createView(display, id, info);
            view.updateAppWidgetSize(options, Collections.singletonList(new SizeF(widthDp, heightDp)));
            widget.presentation = new Presentation(display, widget.display.getDisplay());
            widget.presentation.getWindow().setBackgroundDrawable(new ColorDrawable(0));
            widget.presentation.setContentView(view);
            widget.presentation.getWindow().addOnFrameMetricsAvailableListener(
                    (window, metrics, dropped) -> copy(key, widget), frames);
            widget.presentation.show();
            placed.put(key, widget);
            android.util.Log.i("InquilineWidgets", "Showing a widget at " + widthDp + "x" + heightDp + " dp");
        });
    }

    void remove(String key) {
        main.post(() -> removeNow(key));
    }

    /** On the main thread. */
    private void removeNow(String key) {
        Placed widget = placed.remove(key);
        if (widget == null) return;
        widget.presentation.dismiss();
        widget.display.release();
        widget.reader.close();
        host.deleteAppWidgetId(widget.id);
    }

    private static Bundle sizeOptions(int widthDp, int heightDp) {
        Bundle options = new Bundle();
        options.putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, widthDp);
        options.putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, widthDp);
        options.putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, heightDp);
        options.putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, heightDp);
        java.util.ArrayList<SizeF> sizes = new java.util.ArrayList<>();
        sizes.add(new SizeF(widthDp, heightDp));
        options.putParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, sizes);
        return options;
    }

    /** A frame the widget drew: copied, kept, and sent now or once a second has passed. */
    private void copy(String key, Placed widget) {
        if (placed.get(key) != widget) return;
        Bitmap picture = Bitmap.createBitmap(widget.width, widget.height, Bitmap.Config.ARGB_8888);
        PixelCopy.request(widget.presentation.getWindow(), picture, result -> {
            if (result != PixelCopy.SUCCESS) {
                android.util.Log.w("InquilineWidgets", "Copy failed: " + result);
                return;
            }
            widget.latest = picture;
            if (widget.sendQueued) return;
            long wait = widget.lastSent + MIN_INTERVAL - SystemClock.uptimeMillis();
            widget.sendQueued = true;
            frames.postDelayed(() -> send(key, widget), Math.max(0, wait));
        }, frames);
    }

    private void send(String key, Placed widget) {
        widget.sendQueued = false;
        if (placed.get(key) != widget || widget.latest == null) return;
        widget.lastSent = SystemClock.uptimeMillis();
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        widget.latest.compress(Bitmap.CompressFormat.PNG, 100, bytes);
        try {
            JSONObject message = new JSONObject();
            message.put("widget", key);
            message.put("png", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP));
            sink.send(message);
        } catch (org.json.JSONException ignored) {
        }
    }
}
