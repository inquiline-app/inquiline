package io.github.inquiline.notifications;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Takes the Mac's region ("TR"), whose regional ad blocking list joins those of the Mac's
 * languages. A broadcast, not the ad blocker's service: Inquiline sends it whether or not
 * any app has ads blocked, and the service may only start once the VPN is allowed.
 *   am broadcast -n io.github.inquiline.notifications/.Region --es region TR
 */
public final class Region extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String region = intent.getStringExtra("region");
        if (region != null && region.matches("[A-Z]{2}") && Lists.setRegion(context, region)) AdBlock.listsChanged();
    }
}
