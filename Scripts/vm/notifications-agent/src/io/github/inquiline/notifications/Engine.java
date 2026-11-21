package io.github.inquiline.notifications;

import android.content.Context;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

/**
 * Brave's ad blocking engine (adblock-rust, MPL-2.0, in libinquiline_adblock.so; source in
 * Scripts/vm/adblock-engine): the one that decides, for the lists on for an app, which requests
 * are ads, what a page hides and which of uBlock's scriptlets run on it. One engine per set of
 * lists, made when an app with that set first asks.
 */
final class Engine {
    static {
        System.loadLibrary("inquiline_adblock");
    }

    private static native long create(String[] lists, boolean[] trusted, String resources);
    private static native void free(long engine);
    private static native String check(long engine, String url, String source, String type, String method);
    private static native String cosmetic(long engine, String url);
    private static native String hidden(long engine, String classes, String ids, String exceptions);

    private final Context context;
    private final Map<Integer, Long> engines = new HashMap<>();
    private String resources;

    Engine(Context context) {
        this.context = context;
    }

    /** Lists changed (fetched again): engines are made anew as they're next asked for. */
    synchronized void reset() {
        for (long engine : engines.values()) free(engine);
        engines.clear();
    }

    private synchronized long engine(int mask) {
        Long existing = engines.get(mask);
        if (existing != null) return existing;
        List<String> texts = new ArrayList<>();
        List<Boolean> trust = new ArrayList<>();
        for (Lists.List list : Lists.active(context)) {
            if ((list.category & mask) == 0) continue;
            try (BufferedReader in = Lists.open(context, list)) {
                if (in == null) continue;
                StringBuilder text = new StringBuilder();
                char[] buffer = new char[65536];
                for (int n; (n = in.read(buffer)) > 0; ) text.append(buffer, 0, n);
                texts.add(text.toString());
                trust.add(list.trusted);
            } catch (Exception ignored) {
            }
        }
        boolean[] trusted = new boolean[trust.size()];
        for (int i = 0; i < trusted.length; i++) trusted[i] = trust.get(i);
        long made = create(texts.toArray(new String[0]), trusted, resources());
        engines.put(mask, made);
        return made;
    }

    /** Null to let it through, "" to block it, or a data: address to answer it with. */
    String check(int mask, String url, String source, String type, String method) {
        return check(engine(mask), url, source, type, method);
    }

    /** What the page at `url` hides and runs (see adblock-engine's cosmetic). */
    JSONObject cosmetic(int mask, String url) {
        try {
            return new JSONObject(cosmetic(engine(mask), url));
        } catch (Exception e) {
            return new JSONObject();
        }
    }

    /** The generic rules that hide something among these classes and ids, one per line. */
    String hidden(int mask, String classes, String ids, String exceptions) {
        return hidden(engine(mask), classes, ids, exceptions);
    }

    /**
     * uBlock's scriptlets (assets/scriptlets.json, from uBlock's source) and its stand-ins for
     * blocked requests (assets/redirects), in adblock-rust's resource form.
     */
    private synchronized String resources() {
        if (resources != null) return resources;
        JSONArray all = new JSONArray();
        try {
            JSONObject scriptlets = new JSONObject(asset("scriptlets.json"));
            for (Iterator<String> names = scriptlets.keys(); names.hasNext(); ) {
                String name = names.next();
                JSONObject s = scriptlets.getJSONObject(name);
                JSONObject resource = new JSONObject();
                resource.put("name", name);
                resource.put("aliases", s.optJSONArray("aliases") == null ? new JSONArray() : s.getJSONArray("aliases"));
                resource.put("kind", new JSONObject().put("mime", name.endsWith(".fn") ? "fn/javascript" : "application/javascript"));
                resource.put("content", base64(s.getString("code").getBytes(StandardCharsets.UTF_8)));
                resource.put("dependencies", s.optJSONArray("dependencies") == null ? new JSONArray() : s.getJSONArray("dependencies"));
                if (s.optBoolean("requiresTrust")) resource.put("permission", 1);
                all.put(resource);
            }
            JSONObject redirects = new JSONObject(asset("redirects.json"));
            Map<String, JSONArray> aliases = new HashMap<>();
            for (Iterator<String> names = redirects.keys(); names.hasNext(); ) {
                String name = names.next(), file = redirects.getString(name);
                JSONArray list = aliases.computeIfAbsent(file, k -> new JSONArray());
                if (!name.equals(file)) list.put(name);
            }
            for (Map.Entry<String, JSONArray> entry : aliases.entrySet()) {
                String file = entry.getKey();
                byte[] body;
                try (InputStream in = context.getAssets().open("redirects/" + file)) {
                    body = in.readAllBytes();
                }
                JSONObject resource = new JSONObject();
                resource.put("name", file);
                resource.put("aliases", entry.getValue());
                resource.put("kind", new JSONObject().put("mime", mime(file)));
                resource.put("content", base64(body));
                all.put(resource);
            }
        } catch (Exception e) {
            android.util.Log.w("InquilineAdBlock", "Ad blocking resources: " + e);
        }
        resources = all.toString();
        return resources;
    }

    private String asset(String name) throws java.io.IOException {
        try (InputStream in = context.getAssets().open(name)) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    private static String base64(byte[] data) {
        return Base64.encodeToString(data, Base64.NO_WRAP);
    }

    private static String mime(String file) {
        return file.endsWith(".js") ? "application/javascript" : file.endsWith(".css") ? "text/css"
                : file.endsWith(".json") ? "application/json" : file.endsWith(".gif") ? "image/gif"
                : file.endsWith(".png") ? "image/png" : file.endsWith(".mp4") ? "video/mp4"
                : file.endsWith(".mp3") ? "audio/mp3" : file.endsWith(".xml") ? "text/xml"
                : file.endsWith(".html") ? "text/html" : "text/plain";
    }
}
