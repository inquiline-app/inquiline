package io.github.inquiline.notifications;

import java.io.BufferedReader;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * The network rules of uBlock Origin's lists (EasyList syntax: ||host^, anchors, wildcards,
 * exceptions, and the options third-party, domain= and the request's type), which decide
 * whether a request is an ad. Rules are found by a word in them, as uBlock finds them, so a
 * request is checked against a handful of rules, not all of them.
 */
final class Filters {
    /** What is known about a request: its address, its type and the page that made it. */
    static final class Request {
        final String url;
        final String host;
        final String type;     // script, image, stylesheet, subdocument, xmlhttprequest, media, font, document, other
        final String pageHost; // empty when not known
        final boolean thirdParty;
        /** The categories on for the app asking (Lists bits). */
        int mask = -1;

        Request(String url, String host, String type, String pageHost, boolean thirdParty) {
            this.url = url;
            this.host = host;
            this.type = type;
            this.pageHost = pageHost;
            this.thirdParty = thirdParty;
        }
    }

    private static final class Rule {
        String pattern;          // the address part, lower case
        Pattern regex;           // for /regex/ rules
        boolean hostAnchor;      // ||
        boolean startAnchor;     // |
        boolean endAnchor;       // trailing |
        boolean exception;       // @@
        boolean important;
        int party;               // 0 any, 1 third-party only, 2 first-party only
        String[] types;          // null for any
        String[] notTypes;
        String[] domains;        // page domains it applies on
        String[] notDomains;
        /** The stand-in resource a blocked request gets, from $redirect= and its kin. */
        String redirect;
        /** $redirect-rule=: names the stand-in, without blocking by itself. */
        boolean redirectOnly;
        /** The category of the list it came from. */
        int category;
    }

    private final Map<String, List<Rule>> byHost = new HashMap<>();
    private final Map<String, List<Rule>> byWord = new HashMap<>();
    private final List<Rule> unindexed = new ArrayList<>();
    int count;

    void load(BufferedReader in, int category) throws IOException {
        String line;
        while ((line = in.readLine()) != null) {
            line = line.trim();
            if (line.isEmpty() || line.charAt(0) == '!' || line.charAt(0) == '[') continue;
            if (line.contains("##") || line.contains("#@#") || line.contains("#?#") || line.contains("#$#")
                    || line.contains("#%#") || line.contains("#+js")) continue;
            Rule rule = parse(line);
            if (rule == null) continue;
            rule.category = category;
            add(rule);
            count++;
        }
    }

    private static Rule parse(String line) {
        Rule rule = new Rule();
        if (line.startsWith("@@")) {
            rule.exception = true;
            line = line.substring(2);
        }
        String options = null;
        if (!(line.startsWith("/") && line.endsWith("/"))) {
            int dollar = line.lastIndexOf('$');
            if (dollar >= 0 && dollar < line.length() - 1 && !line.substring(dollar).contains("/")) {
                options = line.substring(dollar + 1);
                line = line.substring(0, dollar);
            }
        }
        if (options != null) {
            List<String> types = new ArrayList<>(), notTypes = new ArrayList<>();
            for (String option : options.split(",")) {
                String o = option.trim().toLowerCase(Locale.ROOT);
                boolean not = o.startsWith("~");
                String name = not ? o.substring(1) : o;
                switch (name) {
                    case "third-party": case "3p": rule.party = not ? 2 : 1; break;
                    case "first-party": case "1p": rule.party = not ? 1 : 2; break;
                    case "important": rule.important = true; break;
                    case "match-case": case "all": break;
                    case "script": case "image": case "stylesheet": case "subdocument": case "xmlhttprequest":
                    case "media": case "font": case "other": case "ping": case "websocket": case "object":
                        (not ? notTypes : types).add(name);
                        break;
                    case "css": (not ? notTypes : types).add("stylesheet"); break;
                    case "frame": (not ? notTypes : types).add("subdocument"); break;
                    case "xhr": (not ? notTypes : types).add("xmlhttprequest"); break;
                    case "doc": case "document": if (!not) types.add("document"); break;
                    default:
                        if (name.startsWith("domain=") || name.startsWith("from=")) {
                            List<String> yes = new ArrayList<>(), no = new ArrayList<>();
                            for (String d : name.substring(name.indexOf('=') + 1).split("\\|")) {
                                if (d.startsWith("~")) no.add(d.substring(1)); else yes.add(d);
                            }
                            rule.domains = yes.isEmpty() ? null : yes.toArray(new String[0]);
                            rule.notDomains = no.isEmpty() ? null : no.toArray(new String[0]);
                        } else if (name.startsWith("redirect=") || name.startsWith("redirect-rule=")) {
                            String resource = option.trim().substring(option.indexOf('=') + 1);
                            int priority = resource.indexOf(':');
                            rule.redirect = priority > 0 ? resource.substring(0, priority) : resource;
                            rule.redirectOnly = name.startsWith("redirect-rule=");
                        } else if (name.equals("empty")) {
                            rule.redirect = "empty";
                        } else if (name.equals("mp4") || name.equals("media")) {
                            if (name.equals("mp4")) rule.redirect = "noop-1s.mp4";
                            else (not ? notTypes : types).add("media");
                        } else {
                            // Options this proxy can't honour (csp, removeparam, header, popup...): the rule is left out.
                            return null;
                        }
                }
            }
            rule.types = types.isEmpty() ? null : types.toArray(new String[0]);
            rule.notTypes = notTypes.isEmpty() ? null : notTypes.toArray(new String[0]);
        }
        if (line.length() > 2 && line.startsWith("/") && line.endsWith("/")) {
            try {
                rule.regex = Pattern.compile(line.substring(1, line.length() - 1), Pattern.CASE_INSENSITIVE);
            } catch (Exception e) {
                return null;
            }
            rule.pattern = "";
            return rule;
        }
        if (line.startsWith("||")) {
            rule.hostAnchor = true;
            line = line.substring(2);
        } else if (line.startsWith("|")) {
            rule.startAnchor = true;
            line = line.substring(1);
        }
        if (line.endsWith("|")) {
            rule.endAnchor = true;
            line = line.substring(0, line.length() - 1);
        }
        while (line.startsWith("*")) line = line.substring(1);
        while (line.endsWith("*") && !line.isEmpty()) line = line.substring(0, line.length() - 1);
        if (line.isEmpty() && !rule.hostAnchor && rule.domains == null && rule.types == null) return null;
        rule.pattern = line.toLowerCase(Locale.ROOT);
        return rule;
    }

    private void add(Rule rule) {
        if (rule.hostAnchor && rule.regex == null) {
            int end = 0;
            String p = rule.pattern;
            while (end < p.length() && (Character.isLetterOrDigit(p.charAt(end)) || p.charAt(end) == '.' || p.charAt(end) == '-')) end++;
            String name = p.substring(0, end);
            boolean wholeHost = end == p.length() || p.charAt(end) == '^' || p.charAt(end) == '/';
            if (wholeHost && name.indexOf('.') > 0 && !name.endsWith(".")) {
                byHost.computeIfAbsent(name, k -> new ArrayList<>()).add(rule);
                return;
            }
        }
        String word = rule.regex == null ? bestWord(rule.pattern) : null;
        if (word != null) {
            byWord.computeIfAbsent(word, k -> new ArrayList<>()).add(rule);
        } else {
            unindexed.add(rule);
        }
    }

    /** The longest run of letters and digits not touching a wildcard: every address the rule matches holds it. */
    private static String bestWord(String pattern) {
        String best = null;
        int i = 0;
        while (i < pattern.length()) {
            if (!Character.isLetterOrDigit(pattern.charAt(i))) {
                i++;
                continue;
            }
            int start = i;
            while (i < pattern.length() && Character.isLetterOrDigit(pattern.charAt(i))) i++;
            boolean starBefore = start > 0 && pattern.charAt(start - 1) == '*';
            boolean starAfter = i < pattern.length() && pattern.charAt(i) == '*';
            if (!starBefore && !starAfter && i - start >= 3 && (best == null || i - start > best.length())) {
                best = pattern.substring(start, i);
            }
        }
        return best;
    }

    /** A blocked request's fate: the stand-in to answer with ("" for none), and the category that blocked it. */
    static final class Decision {
        final String redirect;
        final int category;

        Decision(String redirect, int category) {
            this.redirect = redirect;
            this.category = category;
        }
    }

    /**
     * What becomes of the request: null to let it through, else what blocked it and the
     * stand-in resource to answer it with, as uBlock answers some blocked scripts.
     */
    Decision decide(Request r) {
        Rule blocking = blockingRule(r);
        if (blocking == null) return null;
        String url = r.url.toLowerCase(Locale.ROOT), host = r.host.toLowerCase(Locale.ROOT);
        String redirect = null;
        for (List<Rule> rules : candidates(url, host)) {
            for (Rule rule : rules) {
                if (rule.redirect == null || rule.exception || (rule.category & r.mask) == 0 || !applies(rule, r)
                        || !matches(rule, url, host)) continue;
                redirect = rule.redirect;
            }
        }
        return new Decision(redirect == null ? "" : redirect, blocking.category);
    }

    /** The rule lists a request's address can match: by its host and its domains, by its words. */
    private List<List<Rule>> candidates(String url, String host) {
        List<List<Rule>> out = new ArrayList<>();
        for (String h = host; ; ) {
            List<Rule> rules = byHost.get(h);
            if (rules != null) out.add(rules);
            int dot = h.indexOf('.');
            if (dot < 0) break;
            h = h.substring(dot + 1);
        }
        int i = 0;
        while (i < url.length()) {
            if (!Character.isLetterOrDigit(url.charAt(i))) {
                i++;
                continue;
            }
            int start = i;
            while (i < url.length() && Character.isLetterOrDigit(url.charAt(i))) i++;
            if (i - start >= 3) {
                List<Rule> rules = byWord.get(url.substring(start, i));
                if (rules != null) out.add(rules);
            }
        }
        out.add(unindexed);
        return out;
    }

    /** Whether the request is to be blocked. */
    boolean blocks(Request r) {
        return blockingRule(r) != null;
    }

    /** The rule that blocks the request, or null when none does (or an exception lets it through). */
    private Rule blockingRule(Request r) {
        String url = r.url.toLowerCase(Locale.ROOT);
        Rule blocking = null;
        // Rules for the request's host and the domains it is under.
        String host = r.host.toLowerCase(Locale.ROOT);
        for (String h = host; ; ) {
            blocking = check(byHost.get(h), r, url, host, blocking);
            if (blocking != null && blocking.important) return blocking;
            int dot = h.indexOf('.');
            if (dot < 0) break;
            h = h.substring(dot + 1);
        }
        // Rules found by a word of the address.
        int i = 0;
        while (i < url.length()) {
            if (!Character.isLetterOrDigit(url.charAt(i))) {
                i++;
                continue;
            }
            int start = i;
            while (i < url.length() && Character.isLetterOrDigit(url.charAt(i))) i++;
            if (i - start >= 3) {
                blocking = check(byWord.get(url.substring(start, i)), r, url, host, blocking);
                if (blocking != null && blocking.important) return blocking;
            }
        }
        blocking = check(unindexed, r, url, host, blocking);
        return blocking != null && !blocking.exception ? blocking : null;
    }

    /** The deciding rule so far: a block, overridden by an exception, unless the block is important. */
    private Rule check(List<Rule> rules, Request r, String url, String host, Rule current) {
        if (rules == null) return current;
        for (Rule rule : rules) {
            if (rule.redirectOnly || (rule.category & r.mask) == 0) continue;
            if (current != null && current.exception && !rule.important) continue;
            if (!applies(rule, r) || !matches(rule, url, host)) continue;
            if (rule.exception) {
                if (current == null || !current.important) current = rule;
            } else if (current == null || rule.important) {
                current = rule;
            }
        }
        return current;
    }

    private static boolean applies(Rule rule, Request r) {
        if (rule.party == 1 && !r.thirdParty) return false;
        if (rule.party == 2 && r.thirdParty) return false;
        if (rule.types != null && !contains(rule.types, r.type)) return false;
        if (rule.types == null && r.type.equals("document")) return false;
        if (rule.notTypes != null && contains(rule.notTypes, r.type)) return false;
        if (rule.domains != null && !onDomain(rule.domains, r.pageHost)) return false;
        if (rule.notDomains != null && onDomain(rule.notDomains, r.pageHost)) return false;
        return true;
    }

    private static boolean contains(String[] values, String value) {
        for (String v : values) if (v.equals(value)) return true;
        return false;
    }

    private static boolean onDomain(String[] domains, String host) {
        if (host.isEmpty()) return false;
        for (String d : domains) {
            if (host.equals(d) || host.endsWith("." + d)) return true;
        }
        return false;
    }

    private static boolean matches(Rule rule, String url, String host) {
        if (rule.regex != null) return rule.regex.matcher(url).find();
        String p = rule.pattern;
        if (rule.hostAnchor) {
            // At the start of the host or of one of its labels.
            int hostStart = url.indexOf("://") + 3;
            for (int at = hostStart; at < hostStart + host.length(); at++) {
                if (at == hostStart || url.charAt(at - 1) == '.') {
                    if (match(p, 0, url, at, rule.endAnchor)) return true;
                }
            }
            return false;
        }
        if (rule.startAnchor) return match(p, 0, url, 0, rule.endAnchor);
        for (int at = 0; at <= url.length(); at++) {
            if (match(p, 0, url, at, rule.endAnchor)) return true;
        }
        return false;
    }

    /** The pattern from `pi` against the address from `ui`: * is anything, ^ a separator or the end. */
    private static boolean match(String p, int pi, String u, int ui, boolean toEnd) {
        while (pi < p.length()) {
            char c = p.charAt(pi);
            if (c == '*') {
                for (int at = ui; at <= u.length(); at++) {
                    if (match(p, pi + 1, u, at, toEnd)) return true;
                }
                return false;
            }
            if (c == '^') {
                if (ui == u.length()) {
                    pi++;
                    continue;
                }
                char x = u.charAt(ui);
                if (Character.isLetterOrDigit(x) || x == '_' || x == '-' || x == '.' || x == '%') return false;
            } else if (ui >= u.length() || u.charAt(ui) != c) {
                return false;
            }
            pi++;
            ui++;
        }
        return !toEnd || ui == u.length();
    }
}
