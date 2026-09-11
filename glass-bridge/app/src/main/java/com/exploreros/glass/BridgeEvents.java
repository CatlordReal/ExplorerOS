package com.exploreros.glass;

import com.exploreros.glass.core.ProtocolMessage;
import com.exploreros.glass.ancs.AncsNotifications;
import com.exploreros.glass.ams.AmsState;
import java.util.LinkedHashMap;

/** Process-local session observer. No notification content is persisted or logged. */
final class BridgeEvents {
    interface Listener { void onStatus(String status); void onMessage(ProtocolMessage message); void onBleCandidate(String name, String address); void onNotification(AncsNotifications.Notification value); void onRemoved(long uid); void onMedia(AmsState.Snapshot value); void onCleared(); void onCompanionCleared(); void onBleCleared(); void onInvalidated(long uid); void onPhoneActions(boolean available); void onVoice(String state); }
    static final class Presentation {
        final long token; final ProtocolMessage message; final AncsNotifications.Notification notification;
        Presentation(long token, ProtocolMessage message, AncsNotifications.Notification notification) { this.token = token; this.message = message; this.notification = notification; }
    }
    private static Presentation pending;
    private static long presentationToken, setupUntil;
    static synchronized boolean foreground() { return listener != null; }
    static synchronized void enteringSetup() { setupUntil = android.os.SystemClock.elapsedRealtime() + 300000; }
    static synchronized void leavingSetup() { setupUntil = 0; }
    static synchronized boolean setupActive() { return android.os.SystemClock.elapsedRealtime() < setupUntil; }
    static synchronized long preparePresentation(ProtocolMessage message, AncsNotifications.Notification notification) { pending = new Presentation(++presentationToken, message, notification); return presentationToken; }
    static synchronized Presentation claimPresentation(long token) { if (pending == null || pending.token != token) return null; Presentation result = pending; pending = null; return result; }
    static synchronized Presentation resolvePresentation(Presentation value) { if (value == null) return null; if (value.notification != null) { AncsNotifications.Notification current = notifications.get(value.notification.uid); return current == null ? null : new Presentation(value.token, null, current); } return card == null ? null : new Presentation(value.token, card, null); }
    static synchronized void detach(Listener value) { if (listener == value) listener = null; }
    static synchronized void cancelPresentation() { pending = null; }
    private static Listener listener;
    private static String status = "Pair iPhone", voice = "";
    private static ProtocolMessage card; private static String cardTransport;
    private static AmsState.Snapshot media; private static boolean phoneActions;
    private static final LinkedHashMap<Long, AncsNotifications.Notification> notifications = new LinkedHashMap<Long, AncsNotifications.Notification>();
    static synchronized void set(Listener value) { listener = value; if (value != null) { value.onStatus(status); value.onVoice(voice); if (card != null) value.onMessage(card); for (AncsNotifications.Notification n : notifications.values()) value.onNotification(n); if (media != null) value.onMedia(media); value.onPhoneActions(phoneActions); } }
    static synchronized void voice(String state) { voice = state; if (listener != null) listener.onVoice(state); }
    static synchronized void phoneActions(boolean available) { phoneActions = available; if (listener != null) listener.onPhoneActions(available); }
    static synchronized void status(String value) { status = value; if (listener != null) listener.onStatus(value); }
    static synchronized void message(ProtocolMessage value, String transport) { if ("card".equals(value.type) || "navigation".equals(value.type)) { card = value; cardTransport = transport; } else if ("navigation.stop".equals(value.type)) card = null; if (listener != null) listener.onMessage(value); }
    static synchronized void candidate(String name, String address) { if (listener != null) listener.onBleCandidate(name, address); }
    static synchronized void notification(AncsNotifications.Notification value) { notifications.put(value.uid, value); if (listener != null) listener.onNotification(value); }
    static synchronized void invalidated(long uid) { if (pending != null && pending.notification != null && pending.notification.uid == uid) pending = null; notifications.remove(uid); if (listener != null) listener.onInvalidated(uid); }
    static synchronized void removed(long uid) { if (pending != null && pending.notification != null && pending.notification.uid == uid) pending = null; notifications.remove(uid); if (listener != null) listener.onRemoved(uid); }
    static synchronized void media(AmsState.Snapshot value) { media = value; if (listener != null) listener.onMedia(value); }
    static synchronized void notificationsCleared() { for (Long uid : new java.util.ArrayList<Long>(notifications.keySet())) removed(uid); }
    static synchronized boolean companionCleared(String transport) { if (!transport.equals(cardTransport)) return false; if (pending != null && pending.message != null) pending = null; card = null; cardTransport = null; if (listener != null) listener.onCompanionCleared(); return true; }
    static synchronized void bleCleared() { companionCleared("ble"); notificationsCleared(); media = null; if (pending != null && pending.notification != null) pending = null; if (listener != null) listener.onBleCleared(); }
    static synchronized void cleared() { voice(""); pending = null; card = null; cardTransport = null; media = null; phoneActions = false; notifications.clear(); if (listener != null) listener.onCleared(); }
}
