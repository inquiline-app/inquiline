package io.github.inquiline.notifications;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.RemoteInput;
import android.content.Intent;
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
 * Inquiline may send back {"reply": key, "text": ...}, which answers it as a phone's reply box
 * does. Opening a notification's screen is Open's, which Android allows only to a privileged
 * process.
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
                try {
                    JSONObject command = new JSONObject(line);
                    if (command.has("reply")) reply(command.getString("reply"), command.getString("text"));
                } catch (org.json.JSONException ignored) {
                }
            }
        } catch (IOException ignored) {
        } finally {
            clients.remove(out);
            try { socket.close(); } catch (IOException ignored) { }
        }
    }

    /** The notification's own reply action: what a phone sends when you answer from it. */
    private static Notification.Action replyAction(Notification n) {
        if (n.actions == null) return null;
        Notification.Action found = null;
        for (Notification.Action action : n.actions) {
            RemoteInput[] inputs = action.getRemoteInputs();
            if (inputs == null || action.actionIntent == null) continue;
            for (RemoteInput input : inputs) {
                if (!input.getAllowFreeFormInput()) continue;
                if (action.getSemanticAction() == Notification.Action.SEMANTIC_ACTION_REPLY) return action;
                if (found == null) found = action;
            }
        }
        return found;
    }

    /** Answers a notification as its reply box on a phone does. */
    private void reply(String key, String text) {
        StatusBarNotification[] active;
        try {
            active = getActiveNotifications(new String[] { key });
        } catch (RuntimeException e) {
            return;
        }
        if (active == null || active.length == 0) return;
        Notification.Action action = replyAction(active[0].getNotification());
        if (action == null) return;
        Intent intent = new Intent();
        Bundle results = new Bundle();
        for (RemoteInput input : action.getRemoteInputs()) {
            if (input.getAllowFreeFormInput()) results.putCharSequence(input.getResultKey(), text);
        }
        RemoteInput.addResultsToIntent(action.getRemoteInputs(), intent, results);
        RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT);
        try {
            action.actionIntent.send(this, 0, intent);
        } catch (PendingIntent.CanceledException ignored) {
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
            message.put("replies", replyAction(n) != null);
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
