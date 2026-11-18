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
 * process. The same connection carries Android's GPS to and from the Mac (Location).
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
                    if (command.has("reply")) reply(command.getString("reply"), command.getString("text"));
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

    /**
     * Whether a chat's newest message is the user's own, as when the app adds the user's reply
     * to the conversation: Android's MessagingStyle gives the user's messages no sender.
     */
    private static boolean lastMessageIsMine(Notification n) {
        Notification.MessagingStyle style = null;
        try {
            style = (Notification.MessagingStyle) Notification.MessagingStyle.class
                    .getMethod("extractMessagingStyleFromNotification", Notification.class).invoke(null, n);
        } catch (ReflectiveOperationException | ClassCastException ignored) {
        }
        if (style == null || style.getMessages().isEmpty()) return false;
        Notification.MessagingStyle.Message last = style.getMessages().get(style.getMessages().size() - 1);
        android.app.Person sender = last.getSenderPerson();
        return sender == null || (style.getUser() != null && sender.getName() != null
                && sender.getName().toString().equals(String.valueOf(style.getUser().getName())));
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
            message.put("group", sbn.getGroupKey());
            message.put("package", sbn.getPackageName());
            message.put("title", title == null ? "" : title.toString());
            message.put("text", text == null ? "" : text.toString());
            message.put("silent", (n.flags & Notification.FLAG_ONLY_ALERT_ONCE) != 0);
            message.put("replies", replyAction(n) != null);
            // When the app says this message came: a new message with the same words as the
            // last is new news, an update that keeps it isn't.
            message.put("when", n.when);
            message.put("fromMe", lastMessageIsMine(n));
            send(message);
        } catch (org.json.JSONException ignored) {
        }
    }

    @Override
    public void onNotificationRemoved(StatusBarNotification sbn) {
        if (clients.isEmpty()) return;
        // An app that gathers its notifications into a group takes the single one down and
        // puts the group up: on a phone the group shows on, so the Mac's stays.
        boolean groupRemains = false;
        try {
            StatusBarNotification[] active = getActiveNotifications();
            if (active != null) {
                for (StatusBarNotification other : active) {
                    if (other.getGroupKey().equals(sbn.getGroupKey()) && !other.getKey().equals(sbn.getKey())) {
                        groupRemains = true;
                        break;
                    }
                }
            }
        } catch (RuntimeException ignored) {
        }
        try {
            send(new JSONObject().put("removed", sbn.getKey()).put("group", sbn.getGroupKey())
                    .put("groupRemains", groupRemains));
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
