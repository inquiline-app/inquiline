package io.github.inquiline.notifications;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashSet;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Blocks ads in the apps the user chose, as phone ad blockers do: a VPN for those apps only,
 * which carries nothing but their name lookups (DNS). A name on the bundled list
 * (assets/blocklist.txt) gets "no such name", so the ad never loads; every other lookup goes on
 * to the network's own DNS server; the apps' other traffic doesn't pass through it at all.
 * Inquiline turns apps on or off with
 *   am start-foreground-service -n io.github.inquiline.notifications/.AdBlock --es add|remove <package>
 * The chosen apps are kept in files/adblock, and the VPN comes back when Android starts (Boot).
 */
public final class AdBlock extends VpnService {
    private static final String DNS = "10.111.222.1";
    private static final String ADDRESS = "10.111.222.2";

    private static Set<String> blocked;
    private ParcelFileDescriptor tun;
    private Thread reader;
    private final ExecutorService lookups = Executors.newFixedThreadPool(8);

    static File listFile(Context context) {
        return new File(context.getFilesDir(), "adblock");
    }

    /** The apps whose ads are blocked, each with the categories on for it (Lists bits). */
    static java.util.Map<String, Integer> chosen(Context context) {
        java.util.Map<String, Integer> apps = new java.util.TreeMap<>();
        try {
            for (String line : Files.readAllLines(listFile(context).toPath())) {
                String[] parts = line.trim().split("\\s+");
                if (parts[0].isEmpty()) continue;
                apps.put(parts[0], parts.length > 1 ? Lists.mask(parts[1]) : Lists.DEFAULT);
            }
        } catch (Exception ignored) {
        }
        return apps;
    }

    private static volatile java.util.Map<String, Integer> masks = java.util.Map.of();

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED);
        java.util.Map<String, Integer> apps = chosen(this);
        java.util.Set<String> before = new java.util.TreeSet<>(apps.keySet());
        if (intent != null) {
            String add = intent.getStringExtra("add"), remove = intent.getStringExtra("remove");
            if (intent.getStringExtra("reset") != null) Counts.reset(this, intent.getStringExtra("reset"));
            // "package=ads,privacy": that app's categories, each on its own; none leaves the app alone.
            String set = intent.getStringExtra("set");
            if (add != null) apps.putIfAbsent(add, Lists.DEFAULT);
            if (remove != null) apps.remove(remove);
            if (set != null && set.contains("=")) {
                String pkg = set.substring(0, set.indexOf('='));
                int mask = Lists.mask(set.substring(set.indexOf('=') + 1));
                if (mask == 0) apps.remove(pkg); else apps.put(pkg, mask);
            }
        }
        java.util.List<String> lines = new java.util.ArrayList<>();
        for (java.util.Map.Entry<String, Integer> app : apps.entrySet()) lines.add(app.getKey() + " " + Lists.names(app.getValue()));
        try {
            Files.write(listFile(this).toPath(), lines);
        } catch (Exception ignored) {
        }
        masks = apps;
        // Only a change of apps needs the VPN made again; categories apply from the next request.
        if (!before.equals(apps.keySet()) || tun == null) restart(apps.keySet());
        return START_STICKY;
    }

    private Notification notification() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("adblock", "Ad blocking", NotificationManager.IMPORTANCE_MIN));
        return new Notification.Builder(this, "adblock").setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentTitle("Ad blocking").build();
    }

    private synchronized void restart(java.util.Set<String> packages) {
        close();
        if (packages.isEmpty()) {
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return;
        }
        loadList();
        // As a VPN app does before each start: Android then makes it the prepared one, as the
        // user consented (Inquiline gives the consent, appop ACTIVATE_VPN).
        if (VpnService.prepare(this) != null) {
            android.util.Log.w("InquilineAdBlock", "The VPN was not allowed");
            return;
        }
        InetAddress upstream = upstreamDns();
        Builder builder = new Builder().setSession("Ad blocking").setBlocking(true)
                .addAddress(ADDRESS, 32).addDnsServer(DNS).addRoute(DNS, 32);
        // With this Mac's authority, the apps' web traffic goes through the proxy too, which
        // looks into each request.
        if (startProxy()) builder.setHttpProxy(android.net.ProxyInfo.buildDirectProxy(ADDRESS, Proxy.PORT));
        int allowed = 0;
        for (String pkg : packages) {
            try {
                builder.addAllowedApplication(pkg);
                allowed++;
            } catch (PackageManager.NameNotFoundException ignored) {
            }
        }
        if (allowed == 0) return;
        try {
            tun = builder.establish();
        } catch (RuntimeException e) {
            android.util.Log.w("InquilineAdBlock", "The VPN could not start", e);
        }
        if (tun == null) return;
        android.util.Log.i("InquilineAdBlock", "Blocking ads in " + allowed + " apps");
        ParcelFileDescriptor current = tun;
        reader = new Thread(() -> serve(current, upstream), "adblock");
        reader.start();
    }

    private static Proxy proxy;
    private static Thread updates;

    /** Android's languages follow the Mac's; the regional lists follow them. */
    @Override
    public void onConfigurationChanged(android.content.res.Configuration config) {
        super.onConfigurationChanged(config);
        if (updates != null) updates.interrupt();
    }

    /** The proxy, with this installation's authority to open connections with (Certs.ofInstallation). */
    private boolean startProxy() {
        if (proxy != null) return true;
        try {
            Proxy started = new Proxy(Certs.ofInstallation(getFilesDir()), filter());
            started.start();
            proxy = started;
            // The lists, fetched again from their sources once a day; the rules change with them.
            // A change of language wakes it early, for that language's regional list.
            updates = new Thread(() -> {
                while (true) {
                    try {
                        if (Lists.update(this)) {
                            proxy.setFilter(filter());
                            blocked = names();
                        }
                    } catch (Exception e) {
                        android.util.Log.w("InquilineAdBlock", "The lists could not be updated", e);
                    }
                    try {
                        Thread.sleep(6L * 60 * 60 * 1000);
                    } catch (InterruptedException e) {
                        // Looked at again now.
                    }
                }
            }, "adblock-lists");
            updates.setDaemon(true);
            updates.start();
            return true;
        } catch (Exception e) {
            android.util.Log.w("InquilineAdBlock", "The proxy could not start", e);
            return false;
        }
    }


    /** The rules of every list as they are now. */
    private Proxy.Filter filter() throws Exception {
        Filters rules = new Filters();
        Cosmetics hiding = new Cosmetics();
        Scriptlets scripts;
        try (java.io.InputStream in = getAssets().open("scriptlets.json")) {
            scripts = new Scriptlets(new String(in.readAllBytes(), StandardCharsets.UTF_8));
        }
        for (Lists.List list : Lists.active(this)) {
            for (int pass = 0; pass < 3; pass++) {
                try (BufferedReader in = Lists.open(this, list)) {
                    if (in == null) break;
                    if (pass == 0) rules.load(in, list.category);
                    else if (pass == 1) hiding.load(in, list.category);
                    else scripts.load(in, list.trusted, list.category);
                }
            }
        }
        android.util.Log.i("InquilineAdBlock", "Ad blocking rules: " + rules.count);
        return new Proxy.Filter() {
            @Override
            public Proxy.Owner ownerOf(java.net.Socket app) {
                return owner(app);
            }

            @Override
            public Proxy.Answer decide(String url, String host, String headers, Proxy.Owner owner) {
                // uBlock's lists alone: the address list, for apps' own name lookups, would also cut
                // services uBlock leaves alone on purpose, as sites' cookie consent.
                Filters.Request request = request(url, host, headers);
                request.mask = owner.mask;
                Filters.Decision decision = rules.decide(request);
                if (decision == null) return null;
                // How many, never which: what an app asks for is the user's own business.
                Counts.add(AdBlock.this, owner.pkg, decision.category & owner.mask);
                String redirect = decision.redirect;
                return redirect.isEmpty() || redirect.equals("empty") ? Proxy.Answer.EMPTY : standIn(redirect);
            }

            @Override
            public String css(String host, int mask) {
                return hiding.css(host, mask);
            }

            @Override
            public String script(String host, int mask) {
                return scripts.script(host, mask);
            }
        };
    }

    /**
     * The app on the other end of a proxy connection and the categories on for it: Android tells
     * a VPN app which app owns a connection, and the user chose them for that app.
     */
    private Proxy.Owner owner(java.net.Socket app) {
        try {
            android.net.ConnectivityManager connectivity = getSystemService(android.net.ConnectivityManager.class);
            int uid = connectivity.getConnectionOwnerUid(android.system.OsConstants.IPPROTO_TCP,
                    (java.net.InetSocketAddress) app.getRemoteSocketAddress(), (java.net.InetSocketAddress) app.getLocalSocketAddress());
            String[] packages = getPackageManager().getPackagesForUid(uid);
            if (packages != null) {
                for (String pkg : packages) {
                    Integer mask = masks.get(pkg);
                    if (mask != null && mask != 0) return new Proxy.Owner(pkg, mask);
                }
            }
        } catch (Exception ignored) {
        }
        return new Proxy.Owner("", Lists.DEFAULT);
    }

    private static org.json.JSONObject standIns;

    /** uBlock's stand-in resource of that name (assets/redirects), or an empty answer without one. */
    private Proxy.Answer standIn(String name) {
        try {
            synchronized (AdBlock.class) {
                if (standIns == null) {
                    try (java.io.InputStream in = getAssets().open("redirects.json")) {
                        standIns = new org.json.JSONObject(new String(in.readAllBytes(), StandardCharsets.UTF_8));
                    }
                }
            }
            String file = standIns.optString(name, standIns.optString(name + ".js", ""));
            if (file.isEmpty()) return Proxy.Answer.EMPTY;
            byte[] body;
            try (java.io.InputStream in = getAssets().open("redirects/" + file)) {
                body = in.readAllBytes();
            }
            String type = file.endsWith(".js") ? "application/javascript" : file.endsWith(".css") ? "text/css"
                    : file.endsWith(".json") ? "application/json" : file.endsWith(".gif") ? "image/gif"
                    : file.endsWith(".png") ? "image/png" : file.endsWith(".mp4") ? "video/mp4"
                    : file.endsWith(".mp3") ? "audio/mpeg" : file.endsWith(".xml") ? "text/xml" : "text/plain";
            return new Proxy.Answer(body, type);
        } catch (Exception e) {
            return Proxy.Answer.EMPTY;
        }
    }

    /** A request as the rules see it, from what a browser says in its headers about it. */
    private static Filters.Request request(String url, String host, String headers) {
        String dest = Proxy.header(headers, "sec-fetch-dest").toLowerCase();
        String type;
        switch (dest) {
            case "script": type = "script"; break;
            case "image": type = "image"; break;
            case "style": type = "stylesheet"; break;
            case "iframe": case "frame": case "embed": case "object": type = "subdocument"; break;
            case "font": type = "font"; break;
            case "audio": case "video": case "track": type = "media"; break;
            case "document": type = "document"; break;
            case "empty": type = "xmlhttprequest"; break;
            // Also a whole connection to a host (CONNECT), whose requests aren't seen yet: a host only
            // ads come from is blocked there, as for an app that won't let its connections be opened.
            default: type = "other";
        }
        String page = Proxy.header(headers, "origin");
        if (page.isEmpty() || page.equals("null")) page = Proxy.header(headers, "referer");
        String pageHost = hostOf(page);
        String site = Proxy.header(headers, "sec-fetch-site").toLowerCase();
        boolean thirdParty = site.isEmpty()
                ? !pageHost.isEmpty() && !baseDomain(pageHost).equals(baseDomain(host))
                : site.equals("cross-site");
        return new Filters.Request(url, host, type, pageHost, thirdParty);
    }

    private static String hostOf(String url) {
        int start = url.indexOf("://");
        if (start < 0) return "";
        String rest = url.substring(start + 3);
        int end = 0;
        while (end < rest.length() && rest.charAt(end) != '/' && rest.charAt(end) != ':' && rest.charAt(end) != '?') end++;
        return rest.substring(0, end).toLowerCase();
    }

    /** The site a host belongs to: its last two labels, or three under a country's own (com.tr, co.uk). */
    private static String baseDomain(String host) {
        String[] labels = host.split("\\.");
        int n = labels.length;
        if (n <= 2) return host;
        boolean countrySecond = labels[n - 1].length() == 2
                && java.util.Set.of("com", "co", "net", "org", "gov", "edu", "ac", "gen", "web", "biz", "info", "ne", "or", "go")
                        .contains(labels[n - 2]);
        int keep = countrySecond ? 3 : 2;
        return String.join(".", java.util.Arrays.copyOfRange(labels, n - keep, n));
    }

    private void close() {
        if (tun != null) {
            try {
                tun.close();
            } catch (Exception ignored) {
            }
            tun = null;
        }
        if (reader != null) reader.interrupt();
    }

    @Override
    public void onDestroy() {
        close();
        lookups.shutdownNow();
    }

    private void loadList() {
        if (blocked == null) blocked = names();
    }

    /**
     * The names whose lookups fail: the hosts list, and every whole domain the app ad networks'
     * list (AdGuard Mobile, "||name^") blocks. Ad SDKs fetch their ads over connections the
     * proxy doesn't see; the lookup is where they can be stopped, before an ad wins an auction
     * and opens over the app with nothing to show.
     */
    private Set<String> names() {
        Set<String> names = new HashSet<>(100_000);
        for (Lists.List list : Lists.ALL) {
            if (!list.file.equals("adguard-mobile.txt")) continue;
            try (BufferedReader in = Lists.open(this, list)) {
                String line;
                while (in != null && (line = in.readLine()) != null) {
                    if (line.startsWith("||") && line.endsWith("^") && line.matches("\\|\\|[a-z0-9.-]+\\^")) {
                        names.add(line.substring(2, line.length() - 1));
                    }
                }
            } catch (Exception ignored) {
            }
        }
        try (BufferedReader in = new BufferedReader(new InputStreamReader(getAssets().open("blocklist.txt"), StandardCharsets.UTF_8))) {
            String line;
            while ((line = in.readLine()) != null) {
                if (!line.isEmpty() && line.charAt(0) != '#') names.add(line);
            }
        } catch (Exception ignored) {
        }
        return names;
    }

    /** The network's own DNS server, from before this VPN. */
    private InetAddress upstreamDns() {
        ConnectivityManager connectivity = getSystemService(ConnectivityManager.class);
        for (Network network : connectivity.getAllNetworks()) {
            NetworkCapabilities caps = connectivity.getNetworkCapabilities(network);
            if (caps == null || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue;
            LinkProperties link = connectivity.getLinkProperties(network);
            if (link == null) continue;
            for (InetAddress server : link.getDnsServers()) {
                if (server instanceof Inet4Address) return server;
            }
        }
        try {
            return InetAddress.getByName("8.8.8.8");
        } catch (Exception e) {
            return null;
        }
    }

    /** Whether the name, or a domain it is under, is on the list. */
    private static boolean isBlocked(String name) {
        Set<String> names = blocked;
        if (names == null) return false;
        String current = name.toLowerCase();
        while (true) {
            if (names.contains(current)) return true;
            int dot = current.indexOf('.');
            if (dot < 0) return false;
            current = current.substring(dot + 1);
        }
    }

    private void serve(ParcelFileDescriptor tun, InetAddress upstream) {
        FileInputStream in = new FileInputStream(tun.getFileDescriptor());
        FileOutputStream out = new FileOutputStream(tun.getFileDescriptor());
        byte[] buffer = new byte[32767];
        while (!Thread.currentThread().isInterrupted()) {
            int length;
            try {
                length = in.read(buffer);
            } catch (Exception e) {
                return;
            }
            if (length <= 0) continue;
            byte[] packet = java.util.Arrays.copyOf(buffer, length);
            // IPv4, UDP, to port 53.
            if ((packet[0] >> 4) != 4 || packet[9] != 17) continue;
            int ip = (packet[0] & 0xF) * 4;
            if (length < ip + 8 + 12 || port(packet, ip + 2) != 53) continue;
            byte[] query = java.util.Arrays.copyOfRange(packet, ip + 8, length);
            String name = questionName(query);
            if (name != null && isBlocked(name)) {
                write(out, answer(packet, ip, noSuchName(query)));
                continue;
            }
            lookups.execute(() -> {
                try (DatagramSocket socket = new DatagramSocket()) {
                    protect(socket);
                    socket.setSoTimeout(5000);
                    socket.send(new DatagramPacket(query, query.length, upstream, 53));
                    byte[] reply = new byte[4096];
                    DatagramPacket received = new DatagramPacket(reply, reply.length);
                    socket.receive(received);
                    write(out, answer(packet, ip, java.util.Arrays.copyOf(reply, received.getLength())));
                } catch (Exception ignored) {
                }
            });
        }
    }

    private static synchronized void write(FileOutputStream out, byte[] packet) {
        try {
            out.write(packet);
        } catch (Exception ignored) {
        }
    }

    private static int port(byte[] b, int at) {
        return ((b[at] & 0xFF) << 8) | (b[at + 1] & 0xFF);
    }

    private static String questionName(byte[] query) {
        StringBuilder name = new StringBuilder();
        int at = 12;
        while (at < query.length) {
            int label = query[at] & 0xFF;
            if (label == 0) return name.toString();
            if (label > 63 || at + 1 + label > query.length) return null;
            if (name.length() > 0) name.append('.');
            name.append(new String(query, at + 1, label, StandardCharsets.US_ASCII));
            at += 1 + label;
        }
        return null;
    }

    /** The query sent back as the answer "no such name". */
    private static byte[] noSuchName(byte[] query) {
        byte[] reply = query.clone();
        reply[2] = (byte) (0x80 | (query[2] & 0x01)); // a response; recursion desired, as asked
        reply[3] = (byte) (0x80 | 3);                 // recursion available; no such name
        return reply;
    }

    /** An IPv4 packet carrying `dns` back from the DNS server to whoever asked. */
    private static byte[] answer(byte[] request, int ip, byte[] dns) {
        byte[] packet = new byte[20 + 8 + dns.length];
        packet[0] = 0x45;
        int total = packet.length;
        packet[2] = (byte) (total >> 8);
        packet[3] = (byte) total;
        packet[8] = 64;
        packet[9] = 17;
        System.arraycopy(request, 16, packet, 12, 4); // from the DNS server
        System.arraycopy(request, 12, packet, 16, 4); // to the app
        int sum = 0;
        for (int i = 0; i < 20; i += 2) sum += ((packet[i] & 0xFF) << 8) | (packet[i + 1] & 0xFF);
        while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
        sum = ~sum & 0xFFFF;
        packet[10] = (byte) (sum >> 8);
        packet[11] = (byte) sum;
        packet[20] = request[ip + 2];
        packet[21] = request[ip + 3];
        packet[22] = request[ip];
        packet[23] = request[ip + 1];
        int udp = 8 + dns.length;
        packet[24] = (byte) (udp >> 8);
        packet[25] = (byte) udp;
        // A UDP checksum of zero means none, which IPv4 allows.
        System.arraycopy(dns, 0, packet, 28, dns.length);
        return packet;
    }
}
