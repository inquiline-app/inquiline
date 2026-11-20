package io.github.inquiline.notifications;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.service.notification.NotificationListenerService;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * The helper's link with Inquiline on the Mac, one JSON object per line over the abstract socket
 * "inquiline-notifications". Only adb's shell user may connect, which is how Inquiline reaches it.
 * It carries Android's GPS to and from the Mac (Location) and the Mac's desktop widgets
 * (WidgetHost). It is a notification listener so that Android keeps it running, as it does a
 * phone's companion apps; Android's notifications themselves reach the Mac through KDE Connect.
 */
public final class Listener extends NotificationListenerService {
    private static final String SOCKET = "inquiline-notifications";
    private static final int SHELL_UID = 2000;

    private final List<OutputStream> clients = new CopyOnWriteArrayList<>();
    private LocalServerSocket server;
    private Location location;
    /** The widgets on the Mac's desktop, hosted in this process, which Android keeps running. */
    private WidgetHost widgets;

    @Override
    public void onListenerConnected() {
        if (server != null) return;
        try {
            server = new LocalServerSocket(SOCKET);
        } catch (IOException e) {
            return;
        }
        location = new Location(this, this::send);
        widgets = new WidgetHost(this, this::send);
        Sound.apply(this);
        Thread accept = new Thread(this::acceptClients, "inquiline-accept");
        accept.setDaemon(true);
        accept.start();
    }

    private void acceptClients() {
        while (true) {
            final LocalSocket socket;
            try {
                socket = server.accept();
            } catch (IOException e) {
                return;
            }
            try {
                int uid = socket.getPeerCredentials().getUid();
                if (uid != SHELL_UID && uid != 0) {
                    socket.close();
                    continue;
                }
                final OutputStream out = socket.getOutputStream();
                clients.add(out);
                location.connected();
                Thread reader = new Thread(() -> readCommands(socket, out), "inquiline-client");
                reader.setDaemon(true);
                reader.start();
            } catch (IOException e) {
                try { socket.close(); } catch (IOException ignored) { }
            }
        }
    }

    private void readCommands(LocalSocket socket, OutputStream out) {
        try (BufferedReader in = new BufferedReader(
                new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = in.readLine()) != null) {
                try {
                    JSONObject command = new JSONObject(line);
                    JSONObject fix = command.optJSONObject("location");
                    if (fix != null) location.fix(fix);
                    // The Mac's desktop widgets: sizes and points in points, which are dp here.
                    if (command.has("placeWidget")) {
                        widgets.place(command.getString("placeWidget"), command.getString("provider"),
                                command.getInt("width"), command.getInt("height"), command.optInt("id", 0));
                    }
                    if (command.has("resizeWidget")) {
                        widgets.resize(command.getString("resizeWidget"), command.getInt("width"), command.getInt("height"));
                    }
                    if (command.has("removeWidget")) widgets.remove(command.getString("removeWidget"));
                    if (command.has("pruneWidgets")) widgets.prune();
                    if (command.has("touchWidget")) {
                        widgets.touch(command.getString("touchWidget"), command.getString("action"),
                                (float) command.getDouble("x"), (float) command.getDouble("y"));
                    }
                    if (command.has("scrollWidget")) {
                        widgets.scroll(command.getString("scrollWidget"), (float) command.getDouble("x"),
                                (float) command.getDouble("y"), (float) command.getDouble("lines"));
                    }

                } catch (org.json.JSONException ignored) {
                }
            }
        } catch (IOException ignored) {
        } finally {
            clients.remove(out);
            try { socket.close(); } catch (IOException ignored) { }
        }
    }

    private void send(JSONObject message) {
        byte[] line = (message.toString() + "\n").getBytes(StandardCharsets.UTF_8);
        for (OutputStream out : clients) {
            try {
                out.write(line);
                out.flush();
            } catch (IOException e) {
                clients.remove(out);
            }
        }
    }
}
