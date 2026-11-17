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
    private final List<String> generic = new ArrayList<>();
    private final Map<String, List<String>> byDomain = new HashMap<>();
    private final Map<String, Set<String>> exceptions = new HashMap<>();
    private String genericCss;

    void load(BufferedReader in) throws IOException {
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
                if (!exception) generic.add(selector);
                continue;
            }
            for (String domain : domains.split(",")) {
                domain = domain.trim();
                if (domain.isEmpty() || domain.startsWith("~")) continue;
                if (exception) {
                    exceptions.computeIfAbsent(domain, k -> new HashSet<>()).add(selector);
                } else {
                    byDomain.computeIfAbsent(domain, k -> new ArrayList<>()).add(selector);
                }
            }
        }
        genericCss = null;
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
    String css(String host) {
        Set<String> excepted = new HashSet<>();
        Set<String> own = new LinkedHashSet<>();
        for (String h = host; ; ) {
            List<String> rules = byDomain.get(h);
            if (rules != null) own.addAll(rules);
            Set<String> not = exceptions.get(h);
            if (not != null) excepted.addAll(not);
            int dot = h.indexOf('.');
            if (dot < 0) break;
            h = h.substring(dot + 1);
        }
        StringBuilder css = new StringBuilder();
        if (excepted.isEmpty()) {
            css.append(genericCss());
        } else {
            appendRules(css, generic, excepted);
        }
        appendRules(css, own, excepted);
        return css.toString();
    }

    private synchronized String genericCss() {
        if (genericCss == null) {
            StringBuilder css = new StringBuilder();
            appendRules(css, generic, Set.of());
            genericCss = css.toString();
        }
        return genericCss;
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
