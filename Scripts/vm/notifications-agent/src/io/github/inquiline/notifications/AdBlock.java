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

    static Set<String> chosen(Context context) {
        Set<String> packages = new TreeSet<>();
        try {
            for (String line : Files.readAllLines(listFile(context).toPath())) {
                if (!line.isBlank()) packages.add(line.trim());
            }
        } catch (Exception ignored) {
        }
        return packages;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED);
        Set<String> packages = chosen(this);
        if (intent != null) {
            if (intent.getStringExtra("add") != null) packages.add(intent.getStringExtra("add"));
            if (intent.getStringExtra("remove") != null) packages.remove(intent.getStringExtra("remove"));
        }
        try {
            Files.write(listFile(this).toPath(), packages);
        } catch (Exception ignored) {
        }
        restart(packages);
        return START_STICKY;
    }

    private Notification notification() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("adblock", "Ad blocking", NotificationManager.IMPORTANCE_MIN));
        return new Notification.Builder(this, "adblock").setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentTitle("Ad blocking").build();
    }

    private synchronized void restart(Set<String> packages) {
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

    /** The proxy, with this installation's authority to open connections with (Certs.ofInstallation). */
    private boolean startProxy() {
        if (proxy != null) return true;
        try {
            Filters rules = new Filters();
            Cosmetics hiding = new Cosmetics();
            for (String list : new String[] {"easylist.txt", "easyprivacy.txt", "ublock-filters.txt", "adguard-turkish.txt"}) {
                try (BufferedReader in = new BufferedReader(new InputStreamReader(getAssets().open(list), StandardCharsets.UTF_8))) {
                    rules.load(in);
                }
                try (BufferedReader in = new BufferedReader(new InputStreamReader(getAssets().open(list), StandardCharsets.UTF_8))) {
                    hiding.load(in);
                }
            }
            android.util.Log.i("InquilineAdBlock", "Ad blocking rules: " + rules.count);
            java.util.concurrent.atomic.AtomicInteger blockedCount = new java.util.concurrent.atomic.AtomicInteger();
            Proxy started = new Proxy(Certs.ofInstallation(getFilesDir()), new Proxy.Filter() {
                @Override
                public boolean blocks(String url, String host, String headers) {
                    boolean blocked = isBlocked(host) || rules.blocks(request(url, host, headers));
                    // How many, never which: what an app asks for is the user's own business.
                    if (blocked && blockedCount.incrementAndGet() % 25 == 0) {
                        android.util.Log.i("InquilineAdBlock", "Ads blocked so far: " + blockedCount.get());
                    }
                    return blocked;
                }

                @Override
                public String css(String host) {
                    return hiding.css(host);
                }
            });
            started.start();
            proxy = started;
            return true;
        } catch (Exception e) {
            android.util.Log.w("InquilineAdBlock", "The proxy could not start", e);
            return false;
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
            default: type = headers.isEmpty() ? "document" : "other";
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
        if (blocked != null) return;
        Set<String> names = new HashSet<>(100_000);
        try (BufferedReader in = new BufferedReader(new InputStreamReader(getAssets().open("blocklist.txt"), StandardCharsets.UTF_8))) {
            String line;
            while ((line = in.readLine()) != null) {
                if (!line.isEmpty() && line.charAt(0) != '#') names.add(line);
            }
        } catch (Exception ignored) {
        }
        blocked = names;
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
