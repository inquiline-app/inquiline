package io.github.inquiline.notifications;

import android.app.ActivityOptions;
import android.app.PendingIntent;
import android.app.Presentation;
import android.appwidget.AppWidgetHost;
import android.appwidget.AppWidgetHostView;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProviderInfo;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
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
import android.util.Base64;
import android.util.SizeF;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.PixelCopy;
import android.view.View;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/**
 * Hosts the widgets placed on the Mac's desktop, as a phone's home screen hosts those on it:
 * each is bound to this helper, kept up to date by its app, and laid out at its size on the
 * Mac on a screen of its own that nobody sees. Each new picture of it goes to Inquiline as a
 * PNG, at most once a second; the Mac's clicks and scrolls come back as touches.
 *
 * As a phone's home screen draws its widgets only while its screen is on, these screens are on
 * only while Android's is: with them off, Android sleeps as it would with none. A widget that
 * gets news while Android sleeps (an alarm woke it) is drawn once, and its screen goes off again;
 * the Mac shows the last picture meanwhile.
 *
 * What a tap starts in the widget's own app (a mail, the app itself) opens in that app's Mac
 * window, as from a notification: the helper tells Inquiline, which opens the window and starts
 * Launch on its display, from where the app's own action runs there. Taps that work in place (play, a checkbox,
 * refresh) run at once. Reaching the tap's action takes two members Android keeps for its own
 * launchers, which Inquiline lets the helper use (hidden_api_blacklist_exemptions).
 *
 * Inquiline is the one that knows which widgets are on the Mac, and the Android id each one
 * has; after Android restarts it places them again under those ids, so a widget keeps what it
 * was set up with, and the helper lets go of any it no longer shows (prune). A widget its app
 * must set up first gets its setup screen opened in the app's window, as a phone's home screen
 * opens it when the widget is dropped there.
 */
final class WidgetHost {
    interface Sink {
        void send(JSONObject message);
    }

    private static final int HOST_ID = 0x1d9e7;
    /** Twice a point per dp, as the Mac's Retina screens draw. */
    private static final int DENSITY = 320;
    private static final long MIN_INTERVAL = 1000;

    private static final class Placed {
        int id;
        VirtualDisplay display;
        ImageReader reader;
        Presentation presentation;
        AppWidgetHostView view;
        long lastSent;
        /** Drawn once while Android's screen is off; its screen goes off after this picture. */
        boolean once;
        int width, height;
        boolean sendQueued;
        Bitmap latest;
        long touchDown;
    }

    private final Context context;
    private final Sink sink;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Handler frames;
    private final AppWidgetHost host;
    private final AppWidgetManager manager;
    private final Map<String, Placed> placed = Collections.synchronizedMap(new HashMap<>());
    /** Taps that open an app, until Inquiline says the display of its window. */
    private final Map<String, PendingIntent> opening = Collections.synchronizedMap(new HashMap<>());
    private final Map<String, Intent> openingFill = Collections.synchronizedMap(new HashMap<>());
    /** Android's screen, which the widgets' own follow; on the main thread. */
    private boolean screenOn;
    /** The host, for Launch, which runs in the same process. */
    static volatile WidgetHost current;

    WidgetHost(Context context, Sink sink) {
        this.context = context;
        this.sink = sink;
        HandlerThread thread = new HandlerThread("inquiline-widgets");
        thread.start();
        frames = new Handler(thread.getLooper());
        manager = AppWidgetManager.getInstance(context);
        host = new AppWidgetHost(context, HOST_ID) {
            @Override
            protected AppWidgetHostView onCreateView(Context context, int id, AppWidgetProviderInfo info) {
                return new AppWidgetHostView(context) {
                    @Override
                    public void updateAppWidget(android.widget.RemoteViews views) {
                        super.updateAppWidget(views);
                        drawOnce(getAppWidgetId());
                    }
                };
            }
        };
        screenOn = context.getSystemService(android.os.PowerManager.class).isInteractive();
        android.content.IntentFilter screen = new android.content.IntentFilter(Intent.ACTION_SCREEN_ON);
        screen.addAction(Intent.ACTION_SCREEN_OFF);
        context.registerReceiver(new android.content.BroadcastReceiver() {
            @Override
            public void onReceive(Context ignored, Intent intent) {
                screenOn = Intent.ACTION_SCREEN_ON.equals(intent.getAction());
                synchronized (placed) {
                    for (Placed widget : placed.values()) {
                        widget.once = false;
                        light(widget, screenOn);
                    }
                }
            }
        }, screen, null, main);
        host.startListening();
        current = this;
    }

    /**
     * Shows the provider's widget at this size in dp, under the Mac's key for it: under the
     * Android id it had if that is still its own, else a new one, which Inquiline is told.
     */
    void place(String key, String provider, int widthDp, int heightDp, int knownId) {
        main.post(() -> {
            hide(key);
            ComponentName component = ComponentName.unflattenFromString(provider);
            if (component == null) return;
            Bundle options = sizeOptions(widthDp, heightDp);
            int id = knownId;
            AppWidgetProviderInfo known = id > 0 && contains(host.getAppWidgetIds(), id) ? manager.getAppWidgetInfo(id) : null;
            boolean fresh = known == null || !component.equals(known.provider);
            if (fresh) {
                id = host.allocateAppWidgetId();
                if (!manager.bindAppWidgetIdIfAllowed(id, component, options)) {
                    host.deleteAppWidgetId(id);
                    android.util.Log.w("InquilineWidgets", "Not allowed to show " + provider);
                    return;
                }
            } else {
                manager.updateAppWidgetOptions(id, options);
            }
            AppWidgetProviderInfo info = manager.getAppWidgetInfo(id);
            Placed widget = new Placed();
            widget.id = id;
            widget.width = widthDp * DENSITY / 160;
            widget.height = heightDp * DENSITY / 160;
            // The screen's own pictures aren't read: the widget's window is copied after each frame
            // it draws (PixelCopy), which also works where the screen's buffers can't be read.
            widget.reader = ImageReader.newInstance(widget.width, widget.height, PixelFormat.RGBA_8888, 2);
            DisplayManager displays = context.getSystemService(DisplayManager.class);
            widget.display = displays.createVirtualDisplay("inquiline-widget", widget.width, widget.height, DENSITY,
                    widget.reader.getSurface(), 0);
            Context display = context.createDisplayContext(widget.display.getDisplay());
            widget.view = host.createView(display, id, info);
            handleTaps(key, widget.view);
            widget.view.updateAppWidgetSize(options, Collections.singletonList(new SizeF(widthDp, heightDp)));
            widget.presentation = new Presentation(display, widget.display.getDisplay());
            widget.presentation.getWindow().setBackgroundDrawable(new ColorDrawable(0));
            widget.presentation.setContentView(widget.view);
            widget.presentation.getWindow().addOnFrameMetricsAvailableListener(
                    (window, metrics, dropped) -> copy(key, widget), frames);
            widget.presentation.show();
            placed.put(key, widget);
            // Drawn now in any case; kept on only while Android's screen is.
            widget.once = !screenOn;
            if (!screenOn) light(widget, true);
            if (!fresh) return;
            try {
                JSONObject bound = new JSONObject().put("widgetBound", key).put("id", id);
                // One its app must set up first: its setup screen, in the app's window.
                if (info.configure != null
                        && (info.widgetFeatures & AppWidgetProviderInfo.WIDGET_FEATURE_CONFIGURATION_OPTIONAL) == 0) {
                    bound.put("configure", info.configure.flattenToString()).put("package", info.provider.getPackageName());
                }
                sink.send(bound);
            } catch (org.json.JSONException ignored) {
            }
        });
    }

    private static boolean contains(int[] ids, int id) {
        if (ids == null) return false;
        for (int each : ids) if (each == id) return true;
        return false;
    }

    /** After Inquiline placed all it shows: any other widget this host still has goes. */
    void prune() {
        main.post(() -> {
            int[] ids = host.getAppWidgetIds();
            if (ids == null) return;
            java.util.Set<Integer> shown = new java.util.HashSet<>();
            synchronized (placed) {
                for (Placed widget : placed.values()) shown.add(widget.id);
            }
            for (int id : ids) if (!shown.contains(id)) host.deleteAppWidgetId(id);
        });
    }

    /** The Mac's widget took a new size: the same widget lays itself out again at it. */
    void resize(String key, int widthDp, int heightDp) {
        main.post(() -> {
            Placed widget = placed.get(key);
            if (widget == null) return;
            int width = widthDp * DENSITY / 160, height = heightDp * DENSITY / 160;
            if (width == widget.width && height == widget.height) return;
            ImageReader old = widget.reader;
            widget.reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2);
            widget.width = width;
            widget.height = height;
            widget.display.resize(width, height, DENSITY);
            if (screenOn || widget.once) widget.display.setSurface(widget.reader.getSurface());
            old.close();
            Bundle options = sizeOptions(widthDp, heightDp);
            manager.updateAppWidgetOptions(widget.id, options);
            widget.view.updateAppWidgetSize(options, Collections.singletonList(new SizeF(widthDp, heightDp)));
            if (!screenOn) {
                widget.once = true;
                light(widget, true);
            }
        });
    }

    /** Taken off the Mac: the widget goes, and its app is told, as when one is removed on a phone. */
    void remove(String key) {
        main.post(() -> {
            Placed widget = hide(key);
            if (widget != null) host.deleteAppWidgetId(widget.id);
        });
    }

    /** A click's touch, at a point in dp: "down", "move" or "up". */
    void touch(String key, String action, float xDp, float yDp) {
        main.post(() -> {
            Placed widget = placed.get(key);
            if (widget == null) return;
            long now = SystemClock.uptimeMillis();
            int kind;
            switch (action) {
                case "down": kind = MotionEvent.ACTION_DOWN; widget.touchDown = now; break;
                case "move": kind = MotionEvent.ACTION_MOVE; break;
                case "up": kind = MotionEvent.ACTION_UP; break;
                default: return;
            }
            MotionEvent event = MotionEvent.obtain(widget.touchDown, now, kind, xDp * DENSITY / 160, yDp * DENSITY / 160, 0);
            event.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            widget.presentation.getWindow().getDecorView().dispatchTouchEvent(event);
            event.recycle();
        });
    }

    /** A scroll of the trackpad or wheel over a point, in lines: lists in the widget scroll. */
    void scroll(String key, float xDp, float yDp, float lines) {
        main.post(() -> {
            Placed widget = placed.get(key);
            if (widget == null) return;
            MotionEvent.PointerProperties[] properties = { new MotionEvent.PointerProperties() };
            properties[0].id = 0;
            properties[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;
            MotionEvent.PointerCoords[] coords = { new MotionEvent.PointerCoords() };
            coords[0].x = xDp * DENSITY / 160;
            coords[0].y = yDp * DENSITY / 160;
            coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, lines);
            long now = SystemClock.uptimeMillis();
            MotionEvent event = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1, properties, coords,
                    0, 0, 1, 1, 0, 0, InputDevice.SOURCE_MOUSE, 0);
            widget.presentation.getWindow().getDecorView().dispatchGenericMotionEvent(event);
            event.recycle();
        });
    }

    /** From Launch, on the display of the app's Mac window: the tap's action runs there. */
    void launch(String key, int display) {
        PendingIntent action = opening.remove(key);
        Intent fill = openingFill.remove(key);
        if (action == null) return;
        main.post(() -> {
            ActivityOptions options = ActivityOptions.makeBasic();
            if (display > 0) options.setLaunchDisplayId(display);
            options.setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED);
            try {
                action.send(context, 0, fill, null, null, null, action.isActivity() ? options.toBundle() : null);
            } catch (PendingIntent.CanceledException ignored) {
            }
            try {
                sink.send(new JSONObject().put("widgetDone", key));
            } catch (org.json.JSONException ignored) {
            }
        });
    }

    /**
     * Taps on the widget: those that open an activity wait for the app's Mac window; the rest
     * run at once, as on a phone. Without the launcher's members, taps run as Android would run
     * them, on the widget's own screen, which nobody sees; so the app opens there.
     */
    private void handleTaps(String key, AppWidgetHostView view) {
        try {
            Class<?> handlerClass = Class.forName("android.widget.RemoteViews$InteractionHandler");
            java.lang.reflect.Method launchOptions = android.widget.RemoteViews.RemoteResponse.class
                    .getMethod("getLaunchOptions", View.class);
            Object handler = java.lang.reflect.Proxy.newProxyInstance(handlerClass.getClassLoader(),
                    new Class<?>[] { handlerClass }, (proxy, method, args) -> {
                        if (!"onInteraction".equals(method.getName())) return null;
                        View clicked = (View) args[0];
                        PendingIntent action = (PendingIntent) args[1];
                        android.util.Pair<?, ?> pair = (android.util.Pair<?, ?>) launchOptions.invoke(args[2], clicked);
                        Intent fill = (Intent) pair.first;
                        // Every tap runs from Launch, a screen the user sees, as a phone's taps
                        // come from its home screen in front: Android then lets what it starts
                        // run on in the background, as music does. One that opens the app runs
                        // on the app's window; any other on the widget's own screen.
                        opening.put(key, action);
                        if (fill != null) openingFill.put(key, fill); else openingFill.remove(key);
                        Placed widget = placed.get(key);
                        sink.send(new JSONObject().put("widgetOpen", key).put("package", action.getCreatorPackage())
                                .put("activity", action.isActivity())
                                .put("display", widget == null ? 0 : widget.display.getDisplay().getDisplayId()));
                        return true;
                    });
            AppWidgetHostView.class.getMethod("setInteractionHandler", handlerClass).invoke(view, handler);
        } catch (Exception e) {
            android.util.Log.w("InquilineWidgets", "Taps open apps on the widget's own screen", e);
        }
    }

    /** Its screen goes; the widget, under its id, stays its app's. On the main thread. */
    private Placed hide(String key) {
        Placed widget = placed.remove(key);
        if (widget == null) return null;
        widget.presentation.dismiss();
        widget.display.release();
        widget.reader.close();
        return widget;
    }

    /** A widget's screen on or off: without its surface it's off, and Android may sleep. */
    private static void light(Placed widget, boolean on) {
        widget.display.setSurface(on ? widget.reader.getSurface() : null);
    }

    /** News for a widget while Android's screen is off: its screen comes on for one picture. */
    private void drawOnce(int id) {
        main.post(() -> {
            if (screenOn) return;
            synchronized (placed) {
                for (Placed widget : placed.values()) {
                    if (widget.id != id) continue;
                    widget.once = true;
                    light(widget, true);
                }
            }
        });
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
            if (result != PixelCopy.SUCCESS) return;
            widget.latest = picture;
            if (widget.once) {
                widget.once = false;
                main.post(() -> { if (!screenOn) light(widget, false); });
            }
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
