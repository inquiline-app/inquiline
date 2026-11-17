package io.github.inquiline.notifications;

import java.util.ArrayList;
import java.util.List;

/** The names a page's rules may give its host by, as uBlock matches them. */
final class Hosts {
    /**
     * The host and every domain it is under, and each of those as an "entity" with any ending
     * (google.* for www.google.com.tr): uBlock's rules name sites both ways.
     */
    static List<String> domainsOf(String host) {
        List<String> out = new ArrayList<>();
        String[] labels = host.split("\\.");
        for (int i = 0; i < labels.length; i++) {
            StringBuilder name = new StringBuilder();
            for (int j = i; j < labels.length; j++) {
                if (j > i) name.append('.');
                name.append(labels[j]);
                if (j < labels.length - 1) out.add(name + ".*");
            }
            out.add(name.toString());
        }
        return out;
    }
}
