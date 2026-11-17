package io.github.inquiline.notifications;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/**
 * The ad blocker's lists: those uBlock Origin uses by default, AdGuard's Turkish one and
 * AdGuard's for the ads in apps and games. Each
 * comes with the helper, and is fetched again from its source once a day, as uBlock fetches
 * them: sites such as YouTube change every week and so do the rules for them. Fetching sends
 * nothing about the user; a list that can't be fetched stays as it was.
 */
final class Lists {
    /** What a list blocks, which the user turns on or off for each app (one bit each). */
    static final int ADS = 1, PRIVACY = 2, MALWARE = 4, COOKIES = 8, SOCIAL = 16, ANNOYANCES = 32;
    static final String[] NAMES = {"ads", "privacy", "malware", "cookies", "social", "annoyances"};
    /** On when an app's ads are first blocked, as uBlock's lists are by default. */
    static final int DEFAULT = ADS | PRIVACY | MALWARE;

    static final class List {
        final String file;
        final String source;
        /** uBlock's own lists, which alone may use its "trusted" scriptlets. */
        final boolean trusted;
        final int category;

        List(String file, String source, boolean trusted, int category) {
            this.file = file;
            this.source = source;
            this.trusted = trusted;
            this.category = category;
        }
    }

    /** The categories named in "ads,privacy", as bits. */
    static int mask(String names) {
        int mask = 0;
        for (String name : names.split(",")) {
            for (int i = 0; i < NAMES.length; i++) if (NAMES[i].equals(name.trim())) mask |= 1 << i;
        }
        return mask;
    }

    static String names(int mask) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < NAMES.length; i++) {
            if ((mask & (1 << i)) == 0) continue;
            if (out.length() > 0) out.append(',');
            out.append(NAMES[i]);
        }
        return out.toString();
    }

    private static final String UASSETS = "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/";
    private static final String FANBOY = "https://secure.fanboy.co.nz/";
    static final List[] ALL = {
        new List("easylist.txt", "https://easylist.to/easylist/easylist.txt", false, ADS),
        new List("ublock-filters.txt", UASSETS + "filters.txt", true, ADS),
        new List("ublock-quick-fixes.txt", UASSETS + "quick-fixes.txt", true, ADS),
        // Exceptions that keep sites working: with every category, as uBlock always has it.
        new List("ublock-unbreak.txt", UASSETS + "unbreak.txt", true, ADS | PRIVACY | MALWARE | COOKIES | SOCIAL | ANNOYANCES),
        new List("adguard-turkish.txt", "https://filters.adtidy.org/extension/ublock/filters/13.txt", false, ADS),
        // The ad networks of apps and games (AppLovin, Mintegral, Unity, ironSource...).
        new List("adguard-mobile.txt", "https://filters.adtidy.org/extension/ublock/filters/11.txt", false, ADS),
        new List("easyprivacy.txt", "https://easylist.to/easylist/easyprivacy.txt", false, PRIVACY),
        new List("ublock-privacy.txt", UASSETS + "privacy.txt", true, PRIVACY),
        new List("ublock-badware.txt", UASSETS + "badware.txt", true, MALWARE),
        new List("easylist-cookies.txt", FANBOY + "fanboy-cookiemonster_ubo.txt", false, COOKIES),
        new List("ublock-cookies.txt", UASSETS + "annoyances-cookies.txt", true, COOKIES),
        new List("easylist-social.txt", "https://easylist.to/easylist/fanboy-social.txt", false, SOCIAL),
        new List("easylist-newsletters.txt", FANBOY + "fanboy-newsletter_ubo.txt", false, ANNOYANCES),
        new List("ublock-annoyances.txt", UASSETS + "annoyances-others.txt", true, ANNOYANCES),
    };

    private static final long DAY = 24L * 60 * 60 * 1000;

    /** The fetched copy when there is one, else the one that came with the helper. */
    static BufferedReader open(Context context, List list) throws java.io.IOException {
        File fetched = new File(new File(context.getFilesDir(), "lists"), list.file);
        InputStream in = fetched.exists() ? new FileInputStream(fetched) : context.getAssets().open(list.file);
        return new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
    }

    /** Fetches lists more than a day old; returns whether any changed. */
    static boolean update(Context context) {
        File dir = new File(context.getFilesDir(), "lists");
        dir.mkdirs();
        boolean changed = false;
        for (List list : ALL) {
            File target = new File(dir, list.file);
            if (target.exists() && System.currentTimeMillis() - target.lastModified() < DAY) continue;
            File part = new File(dir, list.file + ".part");
            try {
                HttpURLConnection connection = (HttpURLConnection) new URL(list.source).openConnection();
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(30000);
                connection.setRequestProperty("User-Agent", "Inquiline");
                if (connection.getResponseCode() != 200) continue;
                try (InputStream in = connection.getInputStream(); OutputStream out = new java.io.FileOutputStream(part)) {
                    in.transferTo(out);
                }
                // A list is text with rules; anything else (an error page) is not taken.
                String start = new String(java.nio.file.Files.readAllBytes(part.toPath()), 0,
                        (int) Math.min(part.length(), 200), StandardCharsets.UTF_8);
                if (part.length() > 1000 && (start.startsWith("!") || start.startsWith("["))) {
                    changed |= part.renameTo(target);
                } else {
                    part.delete();
                }
            } catch (Exception e) {
                part.delete();
            }
        }
        return changed;
    }
}
