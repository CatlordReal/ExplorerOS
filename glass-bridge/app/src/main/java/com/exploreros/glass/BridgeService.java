package com.exploreros.glass;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.SystemClock;
import com.exploreros.glass.ble.ExplorerBleClient;
import com.exploreros.glass.hfp.StockVoiceAdapter;
import com.exploreros.glass.ancs.AncsNotifications;
import com.exploreros.glass.ams.AmsState;
import com.exploreros.glass.integration.IntegrationPolicy;
import com.exploreros.glass.core.ProtocolException;
import com.exploreros.glass.core.PhoneActions;
import com.exploreros.glass.core.ProtocolMessage;
import com.exploreros.glass.core.MediaTransfer;
import com.exploreros.glass.media.MediaUploader;

/** Paired, opt-out foreground integration. Never starts device discovery at boot. */
public final class BridgeService extends Service {
    static final String ACTION_BACKGROUND = "com.exploreros.glass.BACKGROUND", ACTION_OPEN = "com.exploreros.glass.OPEN", ACTION_BACKGROUND_CHANGED = "com.exploreros.glass.BACKGROUND_CHANGED";
    static final String ACTION_VOICE_CANCEL = "com.exploreros.glass.VOICE_CANCEL";
    static final String ACTION_PHONE = "com.exploreros.glass.PHONE", EXTRA_PHONE_ACTION = "phone_action";
    static final String ACTION_MEDIA = "com.exploreros.glass.MEDIA", ACTION_NOTIFICATION = "com.exploreros.glass.NOTIFICATION", EXTRA_UID = "uid", EXTRA_COMMAND = "command";
    static final String ACTION_SCAN = "com.exploreros.glass.SCAN", ACTION_CONNECT = "com.exploreros.glass.CONNECT", ACTION_INPUT = "com.exploreros.glass.INPUT", ACTION_REVOKE = "com.exploreros.glass.REVOKE", ACTION_REKEY = "com.exploreros.glass.REKEY", ACTION_MEDIA_SYNC = "com.exploreros.glass.MEDIA_SYNC", EXTRA_ADDRESS = "address", EXTRA_GESTURE = "gesture", EXTRA_KEY = "key", EXTRA_ENABLED = "enabled";
    static final IntegrationPolicy presentation = new IntegrationPolicy();
    private final IntegrationPolicy.Reconnect reconnect = new IntegrationPolicy.Reconnect();
    private final Handler main = new Handler();
    private StockVoiceAdapter voice;
    private TcpBridge tcp; private ExplorerBleClient ble; private MediaUploader uploader; private int generation; private boolean closing;
    private final Runnable retry = new Runnable() { public void run() { if (closing || ble == null || !backgroundAllowed()) return; if (!ble.reconnectSaved(PairingStore.bleAddress(BridgeService.this))) scheduleReconnect(); } };
    static void start(Context context, String action) { Intent intent = new Intent(context, BridgeService.class).setAction(action); if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent); else context.startService(intent); }
    private boolean backgroundAllowed() { return IntegrationPolicy.backgroundAllowed(PairingStore.has(this), PairingStore.backgroundEnabled(this)); }
    private int restartMode() { return backgroundAllowed() ? START_STICKY : START_NOT_STICKY; }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_BACKGROUND : intent.getAction();
        if (ACTION_REVOKE.equals(action)) { PairingStore.revoke(this); closeBridges(); stopSelf(); return START_NOT_STICKY; }
        if (ACTION_BACKGROUND_CHANGED.equals(action)) { closeBridges(); if (!backgroundAllowed()) { stopSelf(); return START_NOT_STICKY; } }
        if ((intent == null || ACTION_BACKGROUND.equals(action)) && !backgroundAllowed()) { closeBridges(); stopSelf(); return START_NOT_STICKY; }
        if (ACTION_REKEY.equals(action)) {
            closeBridges(); try { PairingStore.clearBleAddress(this); PairingStore.save(this, intent.getStringExtra(EXTRA_KEY)); } catch (ProtocolException e) { BridgeEvents.status("Pairing key invalid"); stopSelf(); return START_NOT_STICKY; }
        }
        if (ACTION_VOICE_CANCEL.equals(action)) { if (voice != null) voice.cancel(); return restartMode(); }
        if (tcp == null) startBridge();
        if (ACTION_MEDIA_SYNC.equals(action)) {
            boolean enabled = intent != null && intent.getBooleanExtra(EXTRA_ENABLED, false);
            // Disable uploader first: it can send media.cancel while TCP still advertises sender capability.
            if (uploader != null) uploader.enabled(enabled);
            PairingStore.cameraSyncEnabled(this, enabled);
            if (tcp != null) tcp.setMediaSyncEnabled(enabled);
            if (uploader != null) uploader.peerReady(tcp != null && tcp.mediaReceiveAvailable());
            BridgeEvents.status(enabled ? "Camera sync enabled" : "Camera sync disabled");
            return restartMode();
        }
        if (ble != null && intent != null) {
            if (ACTION_SCAN.equals(action)) { main.removeCallbacks(retry); reconnect.reset(); ble.startInitialScan(); }
            else if (ACTION_CONNECT.equals(action)) { main.removeCallbacks(retry); reconnect.reset(); String address = intent.getStringExtra(EXTRA_ADDRESS); PairingStore.saveBleAddress(this, address); ble.connect(address); }
            else if (ACTION_INPUT.equals(action)) input(intent.getStringExtra(EXTRA_GESTURE));
            else if (ACTION_PHONE.equals(action)) phoneAction(intent.getStringExtra(EXTRA_PHONE_ACTION));
            else if (ACTION_MEDIA.equals(action)) ble.mediaAction(intent.getIntExtra(EXTRA_COMMAND, -1));
            else if (ACTION_NOTIFICATION.equals(action)) ble.notificationAction(intent.getLongExtra(EXTRA_UID, -1), intent.getIntExtra(EXTRA_COMMAND, -1));
        }
        return restartMode();
    }
    private void startBridge() {
        if (!PairingStore.has(this)) { BridgeEvents.status("Pairing key required"); stopSelf(); return; }
        closing = false; final int currentGeneration = ++generation; reconnect.reset();
        BridgeEvents.status(CapabilityDiagnostics.startup(this));
        try {
            final byte[] key = PairingStore.get(this); startForeground(41, notification());
            voice = new StockVoiceAdapter(this, main, new StockVoiceAdapter.Events() { public void voice(String state) { if (!closing && generation == currentGeneration) BridgeEvents.voice(state); } });
            tcp = new TcpBridge(key, new TcpBridge.Callbacks() {
                @Override public void closed() { dispatch(currentGeneration, new Runnable() { public void run() { if (uploader != null) uploader.disconnected(); if (BridgeEvents.companionCleared("tcp")) presentation.navigationStopped(); updatePhoneAvailability(); } }); }
                @Override public void status(final String value) { dispatch(currentGeneration, new Runnable() { public void run() { BridgeEvents.status(value); } }); }
                @Override public void received(final ProtocolMessage message) { dispatch(currentGeneration, new Runnable() { public void run() { receive(message, "tcp"); } }); }
            }); tcp.setMediaSyncEnabled(PairingStore.cameraSyncEnabled(this)); tcp.start();
            uploader = new MediaUploader(this, new MediaUploader.Callbacks() {
                @Override public boolean transportReady() { return tcp != null && tcp.mediaReceiveAvailable(); }
                @Override public boolean send(ProtocolMessage message) { return tcp != null && tcp.sendMedia(message); }
                @Override public boolean completed(String sha256) { return PairingStore.mediaCompleted(BridgeService.this, sha256); }
                @Override public void recordCompleted(String sha256) throws ProtocolException { PairingStore.recordMediaCompleted(BridgeService.this, sha256); }
                @Override public void status(String value) { if (!closing) BridgeEvents.status(value); }
            }); uploader.enabled(PairingStore.cameraSyncEnabled(this));
            ble = new ExplorerBleClient(this, key, new ExplorerBleClient.Callbacks() {
                private boolean active() { return !closing && generation == currentGeneration; }
                @Override public void status(String value) { if (active()) BridgeEvents.status(value); }
                @Override public void candidate(String name, String address) { if (active()) BridgeEvents.candidate(name, address); }
                @Override public void received(ProtocolMessage message) { if (active()) receive(message, "ble"); }
                @Override public void notification(AncsNotifications.Notification value) { if (active()) { BridgeEvents.notification(value); present(null, value); } }
                @Override public void removed(long uid) { if (active()) BridgeEvents.removed(uid); }
                @Override public void invalidated(long uid) { if (active()) BridgeEvents.invalidated(uid); }
                @Override public void media(AmsState.Snapshot value) { if (active()) BridgeEvents.media(value); }
                @Override public void cleared() { if (active()) { BridgeEvents.bleCleared(); updatePhoneAvailability(); } }
                @Override public void notificationsCleared() { if (active()) BridgeEvents.notificationsCleared(); }
                @Override public void capabilities(boolean ancs, boolean ams) { if (active()) { if (tcp != null) tcp.setBluetoothCapabilities(ancs, ams); BridgeEvents.status("ANCS " + (ancs ? "ready" : "unavailable") + " · AMS " + (ams ? "ready" : "unavailable")); } }
                @Override public void disconnected() { if (active()) scheduleReconnect(); }
                @Override public void authenticated() { if (active()) { main.removeCallbacks(retry); reconnect.reset(); } }
            });
            if (!ble.reconnectSaved(PairingStore.bleAddress(this))) scheduleReconnect();
        } catch (ProtocolException e) { BridgeEvents.status("Pairing key invalid"); stopSelf(); }
    }
    private void dispatch(final int expected, final Runnable action) { main.post(new Runnable() { public void run() { if (!closing && generation == expected && PairingStore.has(BridgeService.this)) action.run(); } }); }
    private void scheduleReconnect() { main.removeCallbacks(retry); long delay = reconnect.next(PairingStore.has(this), PairingStore.backgroundEnabled(this), PairingStore.bleAddress(this) != null); if (delay >= 0) main.postDelayed(retry, delay); else if (PairingStore.bleAddress(this) != null) BridgeEvents.status("BLE paused · reconnect in Setup"); }
    private void receive(ProtocolMessage message, String transport) {
        if (MediaTransfer.knownType(message.type)) { if ("tcp".equals(transport) && uploader != null) uploader.inbound(message); return; }
        BridgeEvents.message(message, transport);
        if ("capabilities".equals(message.type)) { updatePhoneAvailability(); if ("tcp".equals(transport) && uploader != null) uploader.peerReady(tcp != null && tcp.mediaReceiveAvailable()); }
        if ("navigation.stop".equals(message.type)) presentation.navigationStopped(); else present(message, null);
    }
    private void present(ProtocolMessage message, AncsNotifications.Notification note) {
        String type = note == null ? message.type : "ancs";
        if (!presentation.present(PairingStore.has(this), PairingStore.backgroundEnabled(this), BridgeEvents.foreground(), BridgeEvents.setupActive(), true, type, note != null && note.newlyAdded, note == null ? 0 : note.flags, SystemClock.elapsedRealtime())) return;
        long token = BridgeEvents.preparePresentation(message, note);
        Intent card = new Intent(this, GlassActivity.class).setAction(GlassActivity.ACTION_PRESENT).putExtra(GlassActivity.EXTRA_PRESENTATION, token).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS);
        try { startActivity(card); } catch (RuntimeException e) { BridgeEvents.cancelPresentation(); BridgeEvents.status("Open Explorer Link setup to view card"); }
    }
    private void updatePhoneAvailability() { BridgeEvents.phoneActions((tcp != null && tcp.phoneActionsAvailable()) || (ble != null && ble.phoneActionsAvailable())); }
    private void phoneAction(String action) {
        if (!PhoneActions.valid(action)) { BridgeEvents.status("Phone action unavailable"); return; }
        // Never retry on another transport after a write attempt: delivery could already have occurred.
        boolean sent;
        if (tcp != null && tcp.phoneActionsAvailable()) sent = tcp.sendPhoneAction(action);
        else if (ble != null && ble.phoneActionsAvailable()) sent = ble.sendPhoneAction(action);
        else { BridgeEvents.status("Phone actions unavailable"); return; }
        BridgeEvents.status(sent ? "Confirm on iPhone" : "Phone request failed");
    }
    void input(String gesture) { if (gesture == null) return; if ("camera".equals(gesture) || "cameraLongPress".equals(gesture)) { if (voice != null && BridgeEvents.foreground()) voice.toggle(); else BridgeEvents.voice("Siri unavailable"); return; } if (tcp != null) tcp.sendInput(gesture); if (ble != null) ble.sendInput(gesture); }
    @Override public void onDestroy() { closeBridges(); main.removeCallbacksAndMessages(null); super.onDestroy(); }
    private void closeBridges() { closing = true; generation++; if (voice != null) voice.close(); voice = null; main.removeCallbacks(retry); reconnect.reset(); if (uploader != null) uploader.close(); uploader = null; if (tcp != null) tcp.stop(); tcp = null; if (ble != null) ble.close(); ble = null; presentation.clear(); BridgeEvents.cleared(); stopForeground(true); }
    @Override public IBinder onBind(Intent intent) { return null; }
    private Notification notification() {
        Notification.Builder b; if (Build.VERSION.SDK_INT >= 26) { ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(new NotificationChannel("explorer-link", "Explorer Link", NotificationManager.IMPORTANCE_LOW)); b = new Notification.Builder(this, "explorer-link"); } else b = new Notification.Builder(this);
        Intent setup = new Intent(this, GlassActivity.class).setAction(GlassActivity.ACTION_SETUP);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0);
        return b.setSmallIcon(android.R.drawable.stat_sys_data_bluetooth).setContentTitle("Explorer Link").setContentText("Connected service").setContentIntent(PendingIntent.getActivity(this, 0, setup, flags)).build();
    }
}
