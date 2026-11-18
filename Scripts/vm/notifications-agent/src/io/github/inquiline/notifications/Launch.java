package io.github.inquiline.notifications;

import android.app.Activity;
import android.os.Bundle;

/**
 * What a widget's tap opens, run from the app's own Mac window. Android lets a widget's tap open
 * an app only from a screen the user sees, as a phone's home screen is when it's tapped; the
 * helper has none, as its widgets' screens are its own. So Inquiline starts this on the display of
 * the app's window, where it shows for a moment, seen through: the tap's action runs from it
 * there, and it goes.
 *   su 0 am start --display <display> -n io.github.inquiline.notifications/.Launch --es key <widget>
 */
public final class Launch extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        overridePendingTransition(0, 0);
    }

    @Override
    protected void onResume() {
        super.onResume();
        String key = getIntent().getStringExtra("key");
        int display = getDisplay().getDisplayId();
        // Once it shows, it counts as seen.
        getWindow().getDecorView().post(() -> {
            WidgetHost host = WidgetHost.current;
            if (host != null && key != null) host.launch(key, display);
            finish();
            overridePendingTransition(0, 0);
        });
    }
}
