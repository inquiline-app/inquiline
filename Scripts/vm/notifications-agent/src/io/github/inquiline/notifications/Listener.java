package io.github.inquiline.notifications;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.ActivityOptions;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Hands Android's notifications to Inquiline on the Mac, as one JSON object per line, over the
 * abstract socket "inquiline-notifications". Only adb's shell user may connect, which is how
 * Inquiline reaches it, so no app inside Android can read them from here.
 *
 * What Android shows a phone's user is what the Mac gets: notifications that would alert, from
 * apps the user let post them, and not the ones an app keeps up while it works (music, downloads).
 * Inquiline may send back "open <key>", which runs the notification's own action.
 */
public final class Listener extends NotificationListenerService {
    private static final String SOCKET = "inquiline-notifications";
    private static final int SHELL_UID = 2000;

    private final List<OutputStream> clients = new CopyOnWriteArrayList<>();
    private LocalServerSocket server;

    @Override
    public void onListenerConnected() {
        if (server != null) return;
        try {
            server = new LocalServerSocket(SOCKET);
        } catch (IOException e) {
            return;
        }
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
                if (line.startsWith("open ")) open(line.substring(5));
            }
        } catch (IOException ignored) {
        } finally {
            clients.remove(out);
            try { socket.close(); } catch (IOException ignored) { }
        }
    }

    /** Runs the notification's own action, as tapping it on a phone does, and clears it if it asks. */
    private void open(String key) {
        StatusBarNotification[] active;
        try {
            active = getActiveNotifications(new String[] { key });
        } catch (RuntimeException e) {
            return;
        }
        if (active == null || active.length == 0) return;
        Notification n = active[0].getNotification();
        if (n.contentIntent != null) {
            try {
                ActivityOptions options = ActivityOptions.makeBasic();
                options.setPendingIntentBackgroundActivityStartMode(
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED);
                n.contentIntent.send(this, 0, null, null, null, null, options.toBundle());
            } catch (PendingIntent.CanceledException | RuntimeException ignored) {
            }
        }
        if ((n.flags & Notification.FLAG_AUTO_CANCEL) != 0) {
            try { cancelNotification(key); } catch (RuntimeException ignored) { }
        }
    }

    @Override
    public void onNotificationPosted(StatusBarNotification sbn, RankingMap rankingMap) {
        if (clients.isEmpty() || !shouldShow(sbn, rankingMap)) return;
        Notification n = sbn.getNotification();
        Bundle extras = n.extras;
        CharSequence title = extras.getCharSequence(Notification.EXTRA_TITLE);
        CharSequence text = extras.getCharSequence(Notification.EXTRA_BIG_TEXT);
        if (text == null) text = extras.getCharSequence(Notification.EXTRA_TEXT);
        if (title == null && text == null) return;
        try {
            JSONObject message = new JSONObject();
            message.put("posted", sbn.getKey());
            message.put("package", sbn.getPackageName());
            message.put("title", title == null ? "" : title.toString());
            message.put("text", text == null ? "" : text.toString());
            message.put("silent", (n.flags & Notification.FLAG_ONLY_ALERT_ONCE) != 0);
            send(message);
        } catch (org.json.JSONException ignored) {
        }
    }

    @Override
    public void onNotificationRemoved(StatusBarNotification sbn) {
        if (clients.isEmpty()) return;
        try {
            send(new JSONObject().put("removed", sbn.getKey()));
        } catch (org.json.JSONException ignored) {
        }
    }

    private boolean shouldShow(StatusBarNotification sbn, RankingMap rankingMap) {
        Notification n = sbn.getNotification();
        if (sbn.isOngoing() || (n.flags & Notification.FLAG_FOREGROUND_SERVICE) != 0) return false;
        if ((n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) return false;
        if (getPackageName().equals(sbn.getPackageName())) return false;
        Ranking ranking = new Ranking();
        if (rankingMap != null && rankingMap.getRanking(sbn.getKey(), ranking)) {
            // Silent and minimized ones don't pop up on a phone either.
            if (ranking.getImportance() < NotificationManager.IMPORTANCE_DEFAULT) return false;
            if (ranking.isSuspended()) return false;
        }
        return true;
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
