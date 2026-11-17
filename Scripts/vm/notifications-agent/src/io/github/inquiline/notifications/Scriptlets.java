package io.github.inquiline.notifications;

import java.io.BufferedReader;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * uBlock Origin's "+js(...)" rules: its own small scripts (scriptlets.json, from uBlock's source),
 * run first on a page as uBlock runs them, to take ads out of what the page loads (YouTube's
 * video ads among them) and quiet sites that fight ad blockers.
 */
final class Scriptlets {
    private static final class Library {
        final Map<String, JSONObject> byName = new HashMap<>();
        final Map<String, String> aliases = new HashMap<>();
    }

    private final Library library = new Library();
    /** By page domain, each call as its arguments (name first). */
    private final Map<String, List<List<String>>> byDomain = new HashMap<>();
    private final Map<String, Set<String>> exceptions = new HashMap<>();

    Scriptlets(String json) throws Exception {
        JSONObject all = new JSONObject(json);
        for (java.util.Iterator<String> it = all.keys(); it.hasNext(); ) {
            String name = it.next();
            JSONObject entry = all.getJSONObject(name);
            library.byName.put(name, entry);
            JSONArray aliases = entry.getJSONArray("aliases");
            for (int i = 0; i < aliases.length(); i++) library.aliases.put(aliases.getString(i), name);
        }
    }

    /** Rules from one list; only uBlock's own lists may use its "trusted" scriptlets, as in uBlock. */
    void load(BufferedReader in, boolean trusted, int category) throws IOException {
        String line;
        while ((line = in.readLine()) != null) {
            line = line.trim();
            int at = line.indexOf("#@#+js(");
            boolean exception = at >= 0;
            if (!exception) at = line.indexOf("##+js(");
            if (at <= 0 && !exception || !line.endsWith(")")) continue;
            String inner = line.substring(at + (exception ? 7 : 6), line.length() - 1);
            List<String> args = split(inner);
            String key = null;
            if (!args.isEmpty()) {
                String name = resolve(args.get(0));
                if (name == null) continue;
                JSONObject entry = library.byName.get(name);
                if (entry.optBoolean("requiresTrust") && !trusted) continue;
                args.set(0, name);
                key = String.join("\u0000", args);
            }
            for (String domain : line.substring(0, at).split(",")) {
                domain = domain.trim();
                if (domain.isEmpty() || domain.startsWith("~")) continue;
                if (exception) {
                    exceptions.computeIfAbsent(domain, k -> new HashSet<>()).add(key == null ? "" : key);
                } else if (key != null) {
                    List<String> tagged = new ArrayList<>(args);
                    tagged.add(String.valueOf(category));
                    byDomain.computeIfAbsent(domain, k -> new ArrayList<>()).add(tagged);
                }
            }
        }
    }

    /** A scriptlet's name in the library, by any of its names, with or without ".js". */
    private String resolve(String token) {
        String name = token.endsWith(".js") ? token : token + ".js";
        if (library.byName.containsKey(name)) return name;
        String alias = library.aliases.get(name);
        if (alias == null) alias = library.aliases.get(token);
        return alias;
    }

    /** The arguments of +js(...), split at commas uBlock's way: "\," is a comma inside one. */
    private static List<String> split(String inner) {
        List<String> args = new ArrayList<>();
        StringBuilder current = new StringBuilder();
        for (int i = 0; i < inner.length(); i++) {
            char c = inner.charAt(i);
            if (c == '\\' && i + 1 < inner.length() && inner.charAt(i + 1) == ',') {
                current.append(',');
                i++;
            } else if (c == ',') {
                args.add(unquote(current.toString().trim()));
                current.setLength(0);
            } else {
                current.append(c);
            }
        }
        if (current.length() > 0 || !args.isEmpty()) args.add(unquote(current.toString().trim()));
        return args;
    }

    private static String unquote(String s) {
        if (s.length() >= 2) {
            char q = s.charAt(0);
            if ((q == '\'' || q == '"' || q == '`') && s.charAt(s.length() - 1) == q) return s.substring(1, s.length() - 1);
        }
        return s;
    }

    /** The script for a page on `host`, or empty when no rule applies there. */
    String script(String host, int mask) {
        Map<String, List<String>> calls = new LinkedHashMap<>();
        Set<String> excepted = new HashSet<>();
        for (String domain : Hosts.domainsOf(host)) {
            List<List<String>> rules = byDomain.get(domain);
            if (rules != null) {
                for (List<String> tagged : rules) {
                    if ((Integer.parseInt(tagged.get(tagged.size() - 1)) & mask) == 0) continue;
                    List<String> args = tagged.subList(0, tagged.size() - 1);
                    calls.putIfAbsent(String.join("\u0000", args), args);
                }
            }
            Set<String> not = exceptions.get(domain);
            if (not != null) excepted.addAll(not);
        }
        if (excepted.contains("")) return "";
        calls.keySet().removeAll(excepted);
        if (calls.isEmpty()) return "";
        Map<String, String> functions = new LinkedHashMap<>();
        StringBuilder invocations = new StringBuilder();
        for (List<String> args : calls.values()) {
            JSONObject entry = library.byName.get(args.get(0));
            if (entry == null || !"MAIN".equals(entry.optString("world", "MAIN")) && !"ISOLATED".equals(entry.optString("world"))) continue;
            addWithDependencies(args.get(0), functions);
            JSONArray json = new JSONArray();
            for (int i = 1; i < args.size(); i++) json.put(args.get(i));
            String list = json.toString();
            invocations.append("try{").append(entry.optString("fn")).append("(...").append(list).append(")}catch(e){}\n");
        }
        StringBuilder code = new StringBuilder("(function(){\nconst scriptletGlobals={};\n");
        for (String fn : functions.values()) code.append(fn).append('\n');
        return code.append(invocations).append("})();").toString();
    }

    private void addWithDependencies(String name, Map<String, String> functions) {
        if (functions.containsKey(name)) return;
        JSONObject entry = library.byName.get(name);
        if (entry == null) return;
        functions.put(name, entry.optString("code"));
        JSONArray deps = entry.optJSONArray("dependencies");
        if (deps == null) return;
        for (int i = 0; i < deps.length(); i++) addWithDependencies(deps.optString(i), functions);
    }
}
