package io.github.inquiline.notifications;

import java.io.BufferedReader;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * uBlock Origin's hiding rules (##selector): the boxes ads leave behind on a page, hidden as
 * uBlock hides them, with a style added to the page. Rules only uBlock's own engine can apply
 * (procedural ones such as :has-text, and scriptlets) are left out.
 */
final class Cosmetics {
    /** Selectors by the category of their list (Lists bits). */
    private final Map<Integer, List<String>> generic = new HashMap<>();
    private final Map<String, List<String[]>> byDomain = new HashMap<>();
    private final Map<String, Set<String>> exceptions = new HashMap<>();
    private final Map<Integer, String> genericCss = new HashMap<>();

    void load(BufferedReader in, int category) throws IOException {
        String line;
        while ((line = in.readLine()) != null) {
            line = line.trim();
            if (line.isEmpty() || line.charAt(0) == '!') continue;
            int at = line.indexOf("#@#");
            boolean exception = at >= 0;
            if (!exception) at = line.indexOf("##");
            if (at < 0) continue;
            String selector = line.substring(at + (exception ? 3 : 2));
            if (selector.isEmpty() || selector.startsWith("+js") || selector.startsWith("^") || !standard(selector)) continue;
            String domains = line.substring(0, at);
            if (domains.isEmpty()) {
                if (!exception) generic.computeIfAbsent(category, k -> new ArrayList<>()).add(selector);
                continue;
            }
            for (String domain : domains.split(",")) {
                domain = domain.trim();
                if (domain.isEmpty() || domain.startsWith("~")) continue;
                if (exception) {
                    exceptions.computeIfAbsent(domain, k -> new HashSet<>()).add(selector);
                } else {
                    byDomain.computeIfAbsent(domain, k -> new ArrayList<>()).add(new String[] {selector, String.valueOf(category)});
                }
            }
        }
        synchronized (genericCss) {
            genericCss.clear();
        }
    }

    /** Selectors a browser applies itself: none of uBlock's own procedural ones. */
    private static boolean standard(String selector) {
        for (String own : new String[] {":has-text(", ":upward(", ":xpath(", ":matches-", ":min-text-length(", ":watch-attr(",
                ":remove(", ":style(", ":others(", ":if(", ":if-not(", ":-abp-", ":contains(", ":nth-ancestor(", ":remove-attr(",
                ":remove-class(", ":shadow", "{"}) {
            if (selector.contains(own)) return false;
        }
        return true;
    }

    /** The style for a page on `host`: its own rules and the generic ones, less its exceptions. */
    String css(String host, int mask) {
        Set<String> excepted = new HashSet<>();
        Set<String> own = new LinkedHashSet<>();
        for (String h : Hosts.domainsOf(host)) {
            List<String[]> rules = byDomain.get(h);
            if (rules != null) {
                for (String[] rule : rules) if ((Integer.parseInt(rule[1]) & mask) != 0) own.add(rule[0]);
            }
            Set<String> not = exceptions.get(h);
            if (not != null) excepted.addAll(not);
        }
        StringBuilder css = new StringBuilder();
        if (excepted.isEmpty()) {
            css.append(genericCss(mask));
        } else {
            appendRules(css, genericFor(mask), excepted);
        }
        appendRules(css, own, excepted);
        return css.toString();
    }

    private List<String> genericFor(int mask) {
        List<String> out = new ArrayList<>();
        for (Map.Entry<Integer, List<String>> entry : generic.entrySet()) {
            if ((entry.getKey() & mask) != 0) out.addAll(entry.getValue());
        }
        return out;
    }

    private String genericCss(int mask) {
        synchronized (genericCss) {
            String css = genericCss.get(mask);
            if (css == null) {
                StringBuilder out = new StringBuilder();
                appendRules(out, genericFor(mask), Set.of());
                css = out.toString();
                genericCss.put(mask, css);
            }
            return css;
        }
    }

    /**
     * One rule per selector: a selector the browser doesn't know makes it drop only that rule,
     * not the others with it.
     */
    private static void appendRules(StringBuilder css, Iterable<String> selectors, Set<String> excepted) {
        for (String selector : selectors) {
            if (excepted.contains(selector)) continue;
            css.append(selector).append("{display:none!important}\n");
        }
    }
}
