package io.github.inquiline.notifications;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * The ad blocker's proxy, which Android hands the chosen apps' web traffic (AdBlock sets it on
 * their VPN). It opens each HTTPS connection with a certificate for the site from this Mac's own
 * authority, looks at every request as a browser's ad blocker does, answers ads with nothing and
 * passes the rest on to the site over its own HTTPS connection. An app that won't accept the
 * certificate (it pins its own) gets its connections to that site passed through unopened.
 */
final class Proxy {
    static final int PORT = 8899;

    interface Filter {
        /** Whether the request for `url` is an ad; `headers` are the request's own. */
        boolean blocks(String url, String host, String headers);
    }

    private final Certs certs;
    private final Filter filter;
    private final ExecutorService connections = Executors.newCachedThreadPool();
    private final Map<String, SSLContext> contexts = new ConcurrentHashMap<>();
    private final Set<String> pinned = ConcurrentHashMap.newKeySet();
    private ServerSocket server;

    Proxy(Certs certs, Filter filter) {
        this.certs = certs;
        this.filter = filter;
    }

    void start() throws IOException {
        server = new ServerSocket();
        server.setReuseAddress(true);
        // Every address of this Android: the VPN's own, which only the chosen apps reach, doesn't
        // exist until the VPN does. Nothing outside Android can reach it, behind the engine's NAT.
        server.bind(new InetSocketAddress(PORT));
        Thread accept = new Thread(() -> {
            while (!server.isClosed()) {
                try {
                    Socket client = server.accept();
                    connections.execute(() -> handle(client));
                } catch (IOException e) {
                    return;
                }
            }
        }, "adblock-proxy");
        accept.start();
    }

    private void handle(Socket client) {
        try (Socket c = client) {
            InputStream in = c.getInputStream();
            byte[] head = readHead(in);
            if (head == null) return;
            String text = new String(head, StandardCharsets.ISO_8859_1);
            String[] line = text.substring(0, text.indexOf("\r\n")).split(" ");
            if (line.length < 3) return;
            if (line[0].equals("CONNECT")) {
                String target = line[1];
                int colon = target.lastIndexOf(':');
                String host = colon > 0 ? target.substring(0, colon) : target;
                int port = colon > 0 ? Integer.parseInt(target.substring(colon + 1)) : 443;
                if (filter.blocks("https://" + host + "/", host, "")) {
                    c.getOutputStream().write("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".getBytes(StandardCharsets.ISO_8859_1));
                    return;
                }
                c.getOutputStream().write("HTTP/1.1 200 Connection Established\r\n\r\n".getBytes(StandardCharsets.ISO_8859_1));
                if (port != 443 || pinned.contains(host)) {
                    tunnel(c, host, port);
                } else {
                    open(c, host, port);
                }
            } else {
                plain(c, head, text, line);
            }
        } catch (Exception ignored) {
        }
    }

    /** An HTTPS connection the proxy opens and looks into. */
    private void open(Socket client, String host, int port) throws Exception {
        SSLSocket app;
        try {
            SSLSocket wrapped = (SSLSocket) context(host).getSocketFactory().createSocket(client, host, port, false);
            wrapped.setUseClientMode(false);
            SSLParameters parameters = wrapped.getSSLParameters();
            parameters.setApplicationProtocols(new String[] {"http/1.1"});
            wrapped.setSSLParameters(parameters);
            wrapped.startHandshake();
            app = wrapped;
        } catch (IOException e) {
            // The app pins its own certificate: its next connections pass unopened.
            pinned.add(host);
            return;
        }
        try (SSLSocket site = (SSLSocket) SSLSocketFactory.getDefault().createSocket(host, port)) {
            SSLParameters parameters = site.getSSLParameters();
            parameters.setApplicationProtocols(new String[] {"http/1.1"});
            site.setSSLParameters(parameters);
            site.startHandshake();
            exchange(app, site, "https://" + host);
        } finally {
            app.close();
        }
    }

    private SSLContext context(String host) throws Exception {
        SSLContext existing = contexts.get(host);
        if (existing != null) return existing;
        KeyStore store = KeyStore.getInstance(KeyStore.getDefaultType());
        store.load(null, null);
        store.setKeyEntry("site", certs.siteKey.getPrivate(), new char[0],
                new Certificate[] {certs.forHost(host), certs.authority});
        KeyManagerFactory keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        keys.init(store, new char[0]);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(keys.getKeyManagers(), null, null);
        contexts.put(host, context);
        return context;
    }

    /** Requests and answers on one connection, each request looked at first. */
    private void exchange(Socket app, Socket site, String origin) throws IOException {
        InputStream fromApp = app.getInputStream(), fromSite = site.getInputStream();
        OutputStream toApp = app.getOutputStream(), toSite = site.getOutputStream();
        while (true) {
            byte[] request = readHead(fromApp);
            if (request == null) return;
            String head = new String(request, StandardCharsets.ISO_8859_1);
            String[] line = head.substring(0, head.indexOf("\r\n")).split(" ");
            String method = line[0];
            String host = origin.substring(origin.indexOf("//") + 2);
            if (filter.blocks(origin + line[1], host, head)) {
                skipBody(fromApp, head, true, method);
                toApp.write("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".getBytes(StandardCharsets.ISO_8859_1));
                toApp.flush();
                continue;
            }
            toSite.write(request);
            copyBody(fromApp, toSite, head, true, method);
            toSite.flush();
            byte[] response;
            String answer;
            int status;
            do {
                response = readHead(fromSite);
                if (response == null) return;
                answer = new String(response, StandardCharsets.ISO_8859_1);
                status = Integer.parseInt(answer.substring(9, 12));
                toApp.write(response);
                toApp.flush();
            } while (status == 100);
            if (status == 101) {
                pipe(app, site);
                return;
            }
            boolean bodiless = method.equals("HEAD") || status == 204 || status == 304 || (status >= 100 && status < 200);
            if (!bodiless && !copyBody(fromSite, toApp, answer, false, method)) return;
            toApp.flush();
            if (header(answer, "connection").equalsIgnoreCase("close")) return;
        }
    }

    /** Plain HTTP, sent to the proxy with the whole address. */
    private void plain(Socket client, byte[] request, String head, String[] line) throws Exception {
        String url = line[1];
        if (!url.startsWith("http://")) return;
        String rest = url.substring(7);
        int slash = rest.indexOf('/');
        String hostPort = slash < 0 ? rest : rest.substring(0, slash);
        String path = slash < 0 ? "/" : rest.substring(slash);
        int colon = hostPort.lastIndexOf(':');
        String host = colon > 0 ? hostPort.substring(0, colon) : hostPort;
        int port = colon > 0 ? Integer.parseInt(hostPort.substring(colon + 1)) : 80;
        OutputStream toApp = client.getOutputStream();
        if (filter.blocks(url, host, head)) {
            skipBody(client.getInputStream(), head, true, line[0]);
            toApp.write("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".getBytes(StandardCharsets.ISO_8859_1));
            return;
        }
        try (Socket site = new Socket(host, port)) {
            String rewritten = line[0] + " " + path + " " + line[2] + head.substring(head.indexOf("\r\n"));
            byte[] first = rewritten.getBytes(StandardCharsets.ISO_8859_1);
            site.getOutputStream().write(first);
            copyBody(client.getInputStream(), site.getOutputStream(), head, true, line[0]);
            // The rest of this connection, as the site answers.
            pipe(client, site);
        }
    }

    /** Bytes both ways until either side closes. */
    private void pipe(Socket a, Socket b) {
        Thread back = new Thread(() -> copyAll(b, a));
        back.start();
        copyAll(a, b);
        try {
            back.join();
        } catch (InterruptedException ignored) {
        }
    }

    private static void copyAll(Socket from, Socket to) {
        byte[] buffer = new byte[16384];
        try {
            InputStream in = from.getInputStream();
            OutputStream out = to.getOutputStream();
            int n;
            while ((n = in.read(buffer)) > 0) {
                out.write(buffer, 0, n);
                out.flush();
            }
        } catch (IOException ignored) {
        }
        try {
            to.shutdownOutput();
        } catch (Exception ignored) {
        }
    }

    private void tunnel(Socket client, String host, int port) throws IOException {
        try (Socket site = new Socket(host, port)) {
            pipe(client, site);
        }
    }

    static String header(String head, String name) {
        for (String line : head.split("\r\n")) {
            int colon = line.indexOf(':');
            if (colon > 0 && line.substring(0, colon).trim().equalsIgnoreCase(name)) return line.substring(colon + 1).trim();
        }
        return "";
    }

    private static byte[] readHead(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int state = 0;
        while (true) {
            int b = in.read();
            if (b < 0) return null;
            out.write(b);
            state = (b == '\r' && (state == 0 || state == 2)) ? state + 1 : (b == '\n' && (state == 1 || state == 3)) ? state + 1 : 0;
            if (state == 4) return out.toByteArray();
            if (out.size() > 65536) return null;
        }
    }

    private static void skipBody(InputStream in, String head, boolean request, String method) throws IOException {
        copyBody(in, OutputStream.nullOutputStream(), head, request, method);
    }

    /** One message's body, as its head frames it. Returns false when it ends with the connection. */
    private static boolean copyBody(InputStream in, OutputStream out, String head, boolean request, String method) throws IOException {
        if (header(head, "transfer-encoding").toLowerCase(Locale.ROOT).contains("chunked")) {
            while (true) {
                String size = readLine(in, out);
                if (size == null) return false;
                int semi = size.indexOf(';');
                long length = Long.parseLong((semi >= 0 ? size.substring(0, semi) : size).trim(), 16);
                if (length == 0) {
                    // Trailers, then the blank line.
                    while (true) {
                        String trailer = readLine(in, out);
                        if (trailer == null || trailer.isEmpty()) return trailer != null;
                    }
                }
                copyExactly(in, out, length + 2);
            }
        }
        String length = header(head, "content-length");
        if (!length.isEmpty()) {
            copyExactly(in, out, Long.parseLong(length));
            return true;
        }
        if (request) return true;
        // An answer without a length ends with the connection.
        byte[] buffer = new byte[16384];
        int n;
        while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
        return false;
    }

    private static String readLine(InputStream in, OutputStream out) throws IOException {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        int previous = -1;
        while (true) {
            int b = in.read();
            if (b < 0) return null;
            out.write(b);
            if (previous == '\r' && b == '\n') {
                byte[] bytes = line.toByteArray();
                return new String(bytes, 0, bytes.length - 1, StandardCharsets.ISO_8859_1);
            }
            line.write(b);
            previous = b;
        }
    }

    private static void copyExactly(InputStream in, OutputStream out, long count) throws IOException {
        byte[] buffer = new byte[16384];
        while (count > 0) {
            int n = in.read(buffer, 0, (int) Math.min(buffer.length, count));
            if (n < 0) throw new IOException("ended early");
            out.write(buffer, 0, n);
            count -= n;
        }
    }
}
