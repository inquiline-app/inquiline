package io.github.inquiline.notifications;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.media.audiofx.Equalizer;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/**
 * Android's equalizer on all its sound, as the sound settings of many phones have it: off, one
 * of its own presets, or the user's five bands. Inquiline's sound popover sets it:
 *   su 0 am broadcast -n io.github.inquiline.notifications/.Sound --es eq "off" | "preset <n>" | "bands <b1> … <b5>"
 * (band levels in millibels). The choice is kept in files/eq and set again when the helper
 * starts, as Android forgets effects when it restarts.
 */
public final class Sound extends BroadcastReceiver {
    private static Equalizer equalizer;

    @Override
    public void onReceive(Context context, Intent intent) {
        String choice = intent.getStringExtra("eq");
        if (choice == null) return;
        try {
            Files.write(file(context).toPath(), choice.getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {
        }
        apply(context);
    }

    static File file(Context context) {
        return new File(context.getFilesDir(), "eq");
    }

    /** What files/eq says, on all of Android's sound. */
    static synchronized void apply(Context context) {
        String choice = "off";
        try {
            choice = new String(Files.readAllBytes(file(context).toPath()), StandardCharsets.UTF_8).trim();
        } catch (Exception ignored) {
        }
        try {
            if (choice.equals("off")) {
                if (equalizer != null) equalizer.setEnabled(false);
                return;
            }
            if (equalizer == null) equalizer = new Equalizer(0, 0);
            String[] parts = choice.split(" ");
            if (parts[0].equals("preset")) {
                equalizer.usePreset(Short.parseShort(parts[1]));
            } else if (parts[0].equals("bands")) {
                for (short band = 0; band < equalizer.getNumberOfBands() && band + 1 < parts.length; band++) {
                    equalizer.setBandLevel(band, Short.parseShort(parts[band + 1]));
                }
            }
            equalizer.setEnabled(true);
        } catch (Exception e) {
            android.util.Log.w("InquilineSound", "No equalizer", e);
        }
    }
}
