package io.github.inquiline.notifications;

import android.content.Context;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Between Android's GPS (Vendor/gnss, a service of its own) and the Mac: the GPS says when
 * Android wants fixes, which goes on to Inquiline, and Inquiline's fixes from Core Location go
 * back to it. The GPS connects to a socket in this app's own folder, which no other app can
 * reach, so no app can make up where the Mac is.
 *   GPS -> here:  "start <ms>", "stop"
 *   here -> GPS:  "fix <lat> <lon> <alt> <hacc> <vacc> <speed> <bearing>" (NaN when unknown)
 *   here -> Mac:  {"location": "start"} or {"location": "stop"}
 *   Mac -> here:  {"location": {"lat", "lon", "alt"?, "hacc"?, "vacc"?, "speed"?, "bearing"?}}
 */
final class Location {
    interface Sink {
        void send(JSONObject message);
    }

    private final Sink sink;
    private volatile OutputStream gps;
    /** Whether Android wants fixes, as the GPS said last; told again to a Mac that connects. */
    private volatile boolean wanted;

    Location(Context context, Sink sink) {
        this.sink = sink;
        Thread accept = new Thread(() -> serve(new File(context.getFilesDir(), "gnss.sock")), "inquiline-gnss");
        accept.setDaemon(true);
        accept.start();
    }

    /** A Mac connected: it's told whether Android wants fixes now. */
    void connected() {
        if (wanted) tellMac(true);
    }

    /** A fix from the Mac, for the GPS. */
    void fix(JSONObject fix) {
        OutputStream out = gps;
        if (out == null) return;
        String line = "fix " + number(fix, "lat") + " " + number(fix, "lon") + " " + number(fix, "alt") + " "
                + number(fix, "hacc") + " " + number(fix, "vacc") + " " + number(fix, "speed") + " "
                + number(fix, "bearing") + "\n";
        try {
            out.write(line.getBytes(StandardCharsets.US_ASCII));
            out.flush();
        } catch (IOException ignored) {
        }
    }

    private static String number(JSONObject object, String key) {
        double value = object.optDouble(key, Double.NaN);
        return Double.isNaN(value) ? "nan" : Double.toString(value);
    }

    private void tellMac(boolean on) {
        try {
            sink.send(new JSONObject().put("location", on ? "start" : "stop"));
        } catch (org.json.JSONException ignored) {
        }
    }

    private void serve(File path) {
        LocalServerSocket server;
        try {
            path.delete();
            LocalSocket bound = new LocalSocket(LocalSocket.SOCKET_STREAM);
            bound.bind(new LocalSocketAddress(path.getPath(), LocalSocketAddress.Namespace.FILESYSTEM));
            server = new LocalServerSocket(bound.getFileDescriptor());
        } catch (IOException e) {
            android.util.Log.w("InquilineLocation", "No socket for the GPS", e);
            return;
        }
        while (true) {
            try (LocalSocket socket = server.accept()) {
                // Root alone besides this app can reach the folder; only the GPS, as root, is let in.
                if (socket.getPeerCredentials().getUid() != 0) continue;
                gps = socket.getOutputStream();
                BufferedReader in = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII));
                String line;
                while ((line = in.readLine()) != null) {
                    boolean on = line.startsWith("start");
                    if (on == wanted) continue;
                    wanted = on;
                    tellMac(on);
                }
            } catch (IOException ignored) {
            } finally {
                gps = null;
                if (wanted) {
                    wanted = false;
                    tellMac(false);
                }
            }
        }
    }
}
