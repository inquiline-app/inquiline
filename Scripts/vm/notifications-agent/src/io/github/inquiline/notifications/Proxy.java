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
        /** The app on the other end of `app`: its package and the categories on for it (Lists bits). */
        Owner ownerOf(Socket app);

        /**
         * What becomes of the request for `url` (`headers` are its own): null to pass it on, an
         * empty answer to block it, or a stand-in to answer it with.
         */
        Answer decide(String url, String host, String headers, Owner owner);

        /** The style that hides ad boxes on a page from `host`, or empty for none. */
        String css(String host, int mask);

        /** The script uBlock runs first on a page from `host` (its +js rules), or empty for none. */
        String script(String host, int mask);
    }

    /** The app a connection belongs to. */
    static final class Owner {
        final String pkg;
        final int mask;

        Owner(String pkg, int mask) {
            this.pkg = pkg;
            this.mask = mask;
        }
    }

    /** A blocked request's answer: what uBlock gives in place of what was asked for. */
    static final class Answer {
        static final Answer EMPTY = new Answer(new byte[0], null);
        final byte[] body;
        final String type;

        Answer(byte[] body, String type) {
            this.body = body;
            this.type = type;
        }
    }

    private final Certs certs;
    private volatile Filter filter;
    private final ExecutorService connections = Executors.newCachedThreadPool();
    private final Map<String, SSLContext> contexts = new ConcurrentHashMap<>();
    private final Set<String> pinned = ConcurrentHashMap.newKeySet();
    private ServerSocket server;

    Proxy(Certs certs, Filter filter) {
        this.certs = certs;
        this.filter = filter;
    }

    /** New rules, as the lists are updated; connections take them from their next request. */
    void setFilter(Filter filter) {
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
            Owner owner = filter.ownerOf(c);
            int mask = owner.mask;
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
                if (filter.decide("https://" + host + "/", host, "", owner) != null) {
                    c.getOutputStream().write("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".getBytes(StandardCharsets.ISO_8859_1));
                    return;
                }
                c.getOutputStream().write("HTTP/1.1 200 Connection Established\r\n\r\n".getBytes(StandardCharsets.ISO_8859_1));
                if (port != 443 || pinned.contains(host)) {
                    tunnel(c, host, port);
                } else {
                    open(c, host, port, owner);
                }
            } else {
                plain(c, head, text, line, owner);
            }
        } catch (Exception ignored) {
        }
    }

    /** An HTTPS connection the proxy opens and looks into. */
    private void open(Socket client, String host, int port, Owner owner) throws Exception {
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
            // The app refused the certificate, as one that pins its own does: its next connections
            // to the site pass unopened. Other failures, as a connection cut, say nothing of that.
            if (refusedCertificate(e)) pinned.add(host);
            return;
        }
        try (SSLSocket site = (SSLSocket) SSLSocketFactory.getDefault().createSocket(host, port)) {
            SSLParameters parameters = site.getSSLParameters();
            parameters.setApplicationProtocols(new String[] {"http/1.1"});
            site.setSSLParameters(parameters);
            site.startHandshake();
            exchange(app, site, "https://" + host, owner);
        } finally {
            app.close();
        }
    }

    /** Whether the handshake ended with the app's alert that it doesn't trust the certificate. */
    private static boolean refusedCertificate(Throwable e) {
        for (Throwable t = e; t != null; t = t.getCause()) {
            String message = String.valueOf(t.getMessage()).toUpperCase(Locale.ROOT);
            if (message.contains("CERTIFICATE_UNKNOWN") || message.contains("BAD_CERTIFICATE") || message.contains("UNKNOWN_CA")
                    || message.contains("CERTIFICATE_EXPIRED") || message.contains("ACCESS_DENIED")) return true;
        }
        return false;
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
    private void exchange(Socket app, Socket site, String origin, Owner owner) throws IOException {
        int mask = owner.mask;
        InputStream fromApp = app.getInputStream(), fromSite = site.getInputStream();
        OutputStream toApp = app.getOutputStream(), toSite = site.getOutputStream();
        while (true) {
            byte[] request = readHead(fromApp);
            if (request == null) return;
            String head = new String(request, StandardCharsets.ISO_8859_1);
            String[] line = head.substring(0, head.indexOf("\r\n")).split(" ");
            String method = line[0];
            String host = origin.substring(origin.indexOf("//") + 2);
            Answer blocked = filter.decide(origin + line[1], host, head, owner);
            if (blocked != null) {
                skipBody(fromApp, head, true, method);
                toApp.write(answerHead(blocked).getBytes(StandardCharsets.ISO_8859_1));
                toApp.write(blocked.body);
                toApp.flush();
                continue;
            }
            // A page, which gets the style that hides ad boxes: asked for in an encoding this proxy reads.
            boolean page = isPage(head);
            if (page) request = withHeader(head, "Accept-Encoding", "gzip, deflate").getBytes(StandardCharsets.ISO_8859_1);
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
                if (status == 100) {
                    toApp.write(response);
                    toApp.flush();
                }
            } while (status == 100);
            if (page && status == 200 && !method.equals("HEAD")
                    && header(answer, "content-type").toLowerCase(Locale.ROOT).contains("text/html")) {
                String css = filter.css(host, mask), script = filter.script(host, mask);
                byte[] body = readBody(fromSite, answer);
                if (body == null) return;
                byte[] shown = css.isEmpty() && script.isEmpty() ? body : withInjection(body, script, css);
                String out = rebuilt(answer, shown.length, css, script);
                toApp.write(out.getBytes(StandardCharsets.ISO_8859_1));
                toApp.write(shown);
                toApp.flush();
                if (header(answer, "connection").equalsIgnoreCase("close")) return;
                continue;
            }
            toApp.write(response);
            toApp.flush();
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
    private void plain(Socket client, byte[] request, String head, String[] line, Owner owner) throws Exception {
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
        Answer blocked = filter.decide(url, host, head, owner);
        if (blocked != null) {
            skipBody(client.getInputStream(), head, true, line[0]);
            toApp.write(answerHead(blocked).getBytes(StandardCharsets.ISO_8859_1));
            toApp.write(blocked.body);
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

    /** The head of a blocked request's answer: nothing, or a stand-in of its type. */
    private static String answerHead(Answer answer) {
        if (answer.type == null) return "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n";
        return "HTTP/1.1 200 OK\r\nContent-Type: " + answer.type + "\r\nContent-Length: " + answer.body.length
                + "\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n\r\n";
    }

    /** A request for a page: what a browser asks for when it shows one. */
    private static boolean isPage(String head) {
        String dest = header(head, "sec-fetch-dest");
        if (!dest.isEmpty()) return dest.equalsIgnoreCase("document") || dest.equalsIgnoreCase("iframe");
        return header(head, "accept").startsWith("text/html");
    }

    /** The head with `name` set to `value`. */
    private static String withHeader(String head, String name, String value) {
        StringBuilder out = new StringBuilder();
        boolean set = false;
        String[] lines = head.split("\r\n");
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            if (i > 0 && line.isEmpty()) continue;
            int colon = line.indexOf(':');
            if (i > 0 && colon > 0 && line.substring(0, colon).trim().equalsIgnoreCase(name)) {
                if (set) continue;
                line = name + ": " + value;
                set = true;
            }
            out.append(line).append("\r\n");
        }
        if (!set) out.append(name).append(": ").append(value).append("\r\n");
        return out.append("\r\n").toString();
    }

    /** A page's answer head for its new body: its own length, no encoding, and our style allowed. */
    private static String rebuilt(String head, int length, String css, String script) throws IOException {
        StringBuilder out = new StringBuilder();
        String styleHash = css.isEmpty() ? null : "'sha256-" + java.util.Base64.getEncoder().encodeToString(sha256(css)) + "'";
        String scriptHash = script.isEmpty() ? null : "'sha256-" + java.util.Base64.getEncoder().encodeToString(sha256(script)) + "'";
        String[] lines = head.split("\r\n");
        for (int i = 0; i < lines.length; i++) {
            String line = lines[i];
            if (line.isEmpty()) continue;
            int colon = line.indexOf(':');
            String name = colon > 0 ? line.substring(0, colon).trim().toLowerCase(Locale.ROOT) : "";
            if (i > 0 && (name.equals("content-length") || name.equals("transfer-encoding") || name.equals("content-encoding"))) continue;
            if (name.equals("content-security-policy")) {
                String policy = line.substring(colon + 1).trim();
                if (styleHash != null) policy = allowInline(policy, "style", styleHash);
                if (scriptHash != null) policy = allowInline(policy, "script", scriptHash);
                line = "Content-Security-Policy: " + policy;
            }
            out.append(line).append("\r\n");
        }
        out.append("Content-Length: ").append(length).append("\r\n\r\n");
        return out.toString();
    }

    /**
     * A page's content security policy, also allowing our one style or script (`kind`) by its
     * hash. A policy that already allows inline ones is left as it is: a hash in it would end that.
     */
    private static String allowInline(String policy, String kind, String hash) {
        String[] directives = policy.split(";");
        int style = -1, fallback = -1;
        for (int i = 0; i < directives.length; i++) {
            String d = directives[i].trim().toLowerCase(Locale.ROOT);
            if (d.startsWith(kind + "-src-elem ") || d.equals(kind + "-src-elem")) style = i;
            else if ((d.startsWith(kind + "-src ") || d.equals(kind + "-src")) && style < 0) style = i;
            else if (d.startsWith("default-src ")) fallback = i;
        }
        int at = style >= 0 ? style : fallback;
        if (at < 0 || directives[at].contains("'unsafe-inline'") && !directives[at].contains("'nonce-")
                && !directives[at].contains("'sha")) return policy;
        directives[at] = directives[at] + " " + hash;
        return String.join(";", directives);
    }

    private static byte[] sha256(String text) throws IOException {
        try {
            return java.security.MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8));
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IOException(e);
        }
    }

    /** The page with our script and style first in its head, the script before any of the page's own. */
    private static byte[] withInjection(byte[] body, String script, String css) {
        String text = new String(body, StandardCharsets.ISO_8859_1);
        String lower = text.length() > 65536 ? text.substring(0, 65536).toLowerCase(Locale.ROOT) : text.toLowerCase(Locale.ROOT);
        int at = 0;
        int head = lower.indexOf("<head");
        if (head >= 0 && lower.indexOf('>', head) > 0) {
            at = lower.indexOf('>', head) + 1;
        } else {
            int html = lower.indexOf("<html");
            if (html >= 0 && lower.indexOf('>', html) > 0) at = lower.indexOf('>', html) + 1;
        }
        byte[] style = ((script.isEmpty() ? "" : "<script>" + script + "</script>")
                + (css.isEmpty() ? "" : "<style>" + css + "</style>")).getBytes(StandardCharsets.UTF_8);
        byte[] out = new byte[body.length + style.length];
        System.arraycopy(body, 0, out, 0, at);
        System.arraycopy(style, 0, out, at, style.length);
        System.arraycopy(body, at, out, at + style.length, body.length - at);
        return out;
    }

    /** A whole answer's body, its framing and encoding undone; null when the site stops early. */
    private static byte[] readBody(InputStream in, String head) throws IOException {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        if (header(head, "transfer-encoding").toLowerCase(Locale.ROOT).contains("chunked")) {
            while (true) {
                String size = readLine(in, OutputStream.nullOutputStream());
                if (size == null) return null;
                int semi = size.indexOf(';');
                long length = Long.parseLong((semi >= 0 ? size.substring(0, semi) : size).trim(), 16);
                if (length == 0) {
                    while (true) {
                        String trailer = readLine(in, OutputStream.nullOutputStream());
                        if (trailer == null || trailer.isEmpty()) break;
                    }
                    break;
                }
                copyExactly(in, body, length);
                copyExactly(in, OutputStream.nullOutputStream(), 2);
            }
        } else if (!header(head, "content-length").isEmpty()) {
            copyExactly(in, body, Long.parseLong(header(head, "content-length")));
        } else {
            byte[] buffer = new byte[16384];
            int n;
            while ((n = in.read(buffer)) > 0) body.write(buffer, 0, n);
        }
        String encoding = header(head, "content-encoding").toLowerCase(Locale.ROOT);
        InputStream decoded;
        if (encoding.contains("gzip")) decoded = new java.util.zip.GZIPInputStream(new java.io.ByteArrayInputStream(body.toByteArray()));
        else if (encoding.contains("deflate")) decoded = new java.util.zip.InflaterInputStream(new java.io.ByteArrayInputStream(body.toByteArray()));
        else return body.toByteArray();
        ByteArrayOutputStream plain = new ByteArrayOutputStream();
        byte[] buffer = new byte[16384];
        int n;
        while ((n = decoded.read(buffer)) > 0) plain.write(buffer, 0, n);
        return plain.toByteArray();
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
