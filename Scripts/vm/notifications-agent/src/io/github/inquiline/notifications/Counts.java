package io.github.inquiline.notifications;

import android.content.Context;

import java.io.File;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * How many requests the ad blocker blocked in each app, by category, from the first until the
 * user resets them, as uBlock counts all it has blocked. Only numbers: never what was asked for.
 * Kept in files/adblock-counts, a line "package category count" each, for Inquiline to show.
 */
final class Counts {
    private static final Map<String, long[]> counts = new TreeMap<>();
    private static boolean loaded;
    private static boolean writing;

    static synchronized void add(Context context, String pkg, int categories) {
        if (pkg.isEmpty() || categories == 0) return;
        load(context);
        long[] app = counts.computeIfAbsent(pkg, k -> new long[Lists.NAMES.length]);
        for (int i = 0; i < Lists.NAMES.length; i++) {
            if ((categories & (1 << i)) != 0) {
                app[i]++;
                break;
            }
        }
        // Written a moment later, once for a burst of blocks: a page blocks dozens at once.
        if (!writing) {
            writing = true;
            new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(() -> write(context), 500);
        }
    }

    static synchronized void reset(Context context, String pkg) {
        load(context);
        counts.remove(pkg);
        save(context);
    }

    private static synchronized void write(Context context) {
        writing = false;
        save(context);
    }

    private static void load(Context context) {
        if (loaded) return;
        loaded = true;
        try {
            for (String line : Files.readAllLines(file(context).toPath())) {
                String[] parts = line.trim().split(" ");
                if (parts.length != 3) continue;
                long[] app = counts.computeIfAbsent(parts[0], k -> new long[Lists.NAMES.length]);
                for (int i = 0; i < Lists.NAMES.length; i++) if (Lists.NAMES[i].equals(parts[1])) app[i] = Long.parseLong(parts[2]);
            }
        } catch (Exception ignored) {
        }
    }

    private static void save(Context context) {
        List<String> lines = new ArrayList<>();
        for (Map.Entry<String, long[]> app : counts.entrySet()) {
            for (int i = 0; i < Lists.NAMES.length; i++) {
                if (app.getValue()[i] > 0) lines.add(app.getKey() + " " + Lists.NAMES[i] + " " + app.getValue()[i]);
            }
        }
        try {
            File target = file(context), part = new File(target.getPath() + ".part");
            Files.write(part.toPath(), lines);
            part.renameTo(target);
        } catch (Exception ignored) {
        }
    }

    private static File file(Context context) {
        return new File(context.getFilesDir(), "adblock-counts");
    }
}
