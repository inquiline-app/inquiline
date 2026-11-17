package io.github.inquiline.notifications;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Brings ad blocking back as Android starts, and after Inquiline updates the helper, for the apps that had it. */
public final class Boot extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!AdBlock.chosen(context).isEmpty()) {
            context.startForegroundService(new Intent(context, AdBlock.class));
        }
    }
}
