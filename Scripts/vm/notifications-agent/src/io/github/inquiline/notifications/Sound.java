package io.github.inquiline.notifications;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.media.audiofx.Equalizer;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/**
 * Android's own sound effects on all its sound, as the sound settings of many phones have them:
 * its equalizer (off, one of its presets, or the user's five bands), bass boost, surround
 * (its virtualizer) and loudness. Inquiline's sound popover sets them:
 *   su 0 am broadcast -n io.github.inquiline.notifications/.Sound --es eq "off" | "preset <n>" | "bands <b1> … <b5>"
 *   su 0 am broadcast -n io.github.inquiline.notifications/.Sound --es effects "<bass> <surround> <loudness>"
 * (band levels in millibels; the others from 0 to 100). The choices are kept in files/eq and
 * files/effects and set again when the helper starts, as Android forgets effects on a restart.
 */
public final class Sound extends BroadcastReceiver {
    private static Equalizer equalizer;
    private static android.media.audiofx.BassBoost bass;
    private static android.media.audiofx.Virtualizer surround;
    private static android.media.audiofx.LoudnessEnhancer loudness;

    @Override
    public void onReceive(Context context, Intent intent) {
        for (String name : new String[] { "eq", "effects" }) {
            String choice = intent.getStringExtra(name);
            if (choice == null) continue;
            try {
                Files.write(new File(context.getFilesDir(), name).toPath(), choice.getBytes(StandardCharsets.UTF_8));
            } catch (Exception ignored) {
            }
        }
        apply(context);
    }

    static File file(Context context) {
        return new File(context.getFilesDir(), "eq");
    }

    /** What files/eq and files/effects say, on all of Android's sound. */
    static synchronized void apply(Context context) {
        applyEqualizer(context);
        int[] levels = { 0, 0, 0 };
        try {
            String[] parts = new String(Files.readAllBytes(new File(context.getFilesDir(), "effects").toPath()),
                    StandardCharsets.UTF_8).trim().split(" ");
            for (int i = 0; i < 3 && i < parts.length; i++) levels[i] = Math.max(0, Math.min(100, Integer.parseInt(parts[i])));
        } catch (Exception ignored) {
        }
        try {
            if (levels[0] > 0 && bass == null) bass = new android.media.audiofx.BassBoost(0, 0);
            if (bass != null) {
                bass.setStrength((short) (levels[0] * 10));
                bass.setEnabled(levels[0] > 0);
            }
            if (levels[1] > 0 && surround == null) surround = new android.media.audiofx.Virtualizer(0, 0);
            if (surround != null) {
                surround.setStrength((short) (levels[1] * 10));
                surround.setEnabled(levels[1] > 0);
            }
            // Up to 10 dB louder, for apps and videos that play quiet.
            if (levels[2] > 0 && loudness == null) loudness = new android.media.audiofx.LoudnessEnhancer(0);
            if (loudness != null) {
                loudness.setTargetGain(levels[2] * 10);
                loudness.setEnabled(levels[2] > 0);
            }
        } catch (Exception e) {
            android.util.Log.w("InquilineSound", "No sound effect", e);
        }
    }

    private static void applyEqualizer(Context context) {
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
