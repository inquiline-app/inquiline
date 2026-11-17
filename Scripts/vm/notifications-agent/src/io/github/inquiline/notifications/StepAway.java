package io.github.inquiline.notifications;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/**
 * A plain screen over an app, as when a phone's user steps out to the Bluetooth settings to
 * connect a controller: the app beneath stops, and starts again when this goes. Inquiline
 * opens it on an app's display when a controller connects to the Mac while the app runs,
 * holding the window's last picture meanwhile, and opens it again to send it away once the
 * app has stopped. Games that start listening for controllers only as they start (Google's
 * Paddleboat does) then hear of the controller plugged in after.
 */
public final class StepAway extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        leave();
    }

    /** It never stays behind: should it be left in any other way, it goes too. */
    @Override
    protected void onStop() {
        super.onStop();
        if (!isFinishing()) leave();
    }

    private void leave() {
        finish();
        overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0);
    }
}
