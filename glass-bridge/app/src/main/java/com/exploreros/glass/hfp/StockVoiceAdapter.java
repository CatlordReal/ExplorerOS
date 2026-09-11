package com.exploreros.glass.hfp;

import android.bluetooth.BluetoothDevice;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.SystemClock;
import java.io.File;
import java.io.FileInputStream;
import java.security.MessageDigest;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Narrow adapter for the unchanged XE22 GlassBluetooth APK in the audited PB3 image. */
public final class StockVoiceAdapter {
    public interface Events { void voice(String state); }
    private static final String PACKAGE = "com.google.glass.bluetooth";
    private static final String STOCK_SHA = "b621f843709abff9f9dc90a0913f1b13d2893548bb86800d5e422fe56750e9e5";
    private static final String SENDER_PERMISSION = "com.google.glass.bluetooth.permission.COMPANION";
    private static final String HEADSET = "com.google.glass.action.HEADSET_STATE";
    private static final String CALL = "com.google.glass.action.PHONE_CALL_STATE_CHANGED";
    private static final String VOICE = "com.google.glass.action.BLUETOOTH_VOICE_RECOGNITION";
    private final Context context; private final Handler main; private final Events events;
    private final VoicePolicy policy = new VoicePolicy();
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final AudioManager audio;
    private boolean closed, registered, verified, stopPending; private int commandGeneration; private BluetoothDevice device;
    private String source; private long size, modified;
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context ignored, Intent intent) {
            if (closed || isInitialStickyBroadcast()) return;
            if (HEADSET.equals(intent.getAction())) {
                BluetoothDevice next = intent.getParcelableExtra("android.bluetooth.device.extra.DEVICE");
                if (device != null && !device.equals(next)) policy.connection(false);
                device = next;
                policy.connection(verified && intent.getIntExtra("com.google.glass.extra.STATE", 0) == 1 && bonded());
            } else if (CALL.equals(intent.getAction())) policy.call(intent.getBooleanExtra("call_state", true));
            if (!policy.owned()) { main.removeCallbacks(poll); events.voice(""); }
        }
    };
    private final Runnable poll = new Runnable() { @Override public void run() {
        if (closed || !policy.owned()) return;
        if (!currentStock() || !bonded()) { policy.connection(false); events.voice(""); return; }
        refreshCall();
        if (!policy.owned()) { events.voice(""); return; }
        if (policy.expired(SystemClock.elapsedRealtime())) { cancel(); return; }
        boolean routed = policy.audio(audio != null && audio.isBluetoothScoOn());
        events.voice(policy.owned() ? (routed ? "Bluetooth voice audio" : "Siri requested") : "");
        if (policy.owned()) main.postDelayed(this, 250);
    } };
    public StockVoiceAdapter(Context context, Handler handler, Events events) {
        this.context = context.getApplicationContext(); this.main = new Handler(handler.getLooper()); this.events = events;
        audio = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (Build.VERSION.SDK_INT != 19 || (context.getApplicationInfo().flags & ApplicationInfo.FLAG_SYSTEM) == 0) return;
        try {
            IntentFilter filter = new IntentFilter(HEADSET); filter.addAction(CALL);
            // Permission applies to the sender. The bridge does not need this privileged permission.
            context.registerReceiver(receiver, filter, SENDER_PERMISSION, handler); registered = true;
            final ApplicationInfo stock = context.getPackageManager().getApplicationInfo(PACKAGE, 0);
            if ((stock.flags & ApplicationInfo.FLAG_SYSTEM) == 0 || !stock.enabled) return;
            source = stock.sourceDir; File file = new File(source); size = file.length(); modified = file.lastModified();
            worker.execute(new Runnable() { public void run() {
                final boolean matches = matchesStock(new File(stock.sourceDir));
                main.post(new Runnable() { public void run() { if (!closed) { verified = matches; policy.trusted(matches); } } });
            } });
        } catch (Exception ignored) { verified = false; policy.trusted(false); }
    }
    public void toggle() {
        if (closed || stopPending) return;
        refreshCall();
        if (policy.owned()) { cancel(); return; }
        if (!currentStock() || !bonded() || audio == null || !policy.request(audio.isBluetoothScoOn(), SystemClock.elapsedRealtime())) { events.voice("Siri unavailable"); return; }
        sendVerified(true, ++commandGeneration);
    }
    public void cancel() {
        main.removeCallbacks(poll); refreshCall();
        if (policy.cancel() && currentStock() && bonded()) { stopPending = true; sendVerified(false, ++commandGeneration); }
        else if (!stopPending) ++commandGeneration;
        events.voice("");
    }
    public void close() {
        if (closed) return;
        cancel(); closed = true; worker.shutdown();
        if (registered) { context.unregisterReceiver(receiver); registered = false; }
    }
    private void sendVerified(final boolean enabled, final int token) {
        worker.execute(new Runnable() { public void run() {
            final boolean matches = source != null && matchesStock(new File(source));
            main.post(new Runnable() { public void run() {
                if (token != commandGeneration || (closed && enabled)) return;
                if (!enabled) stopPending = false;
                refreshCall();
                if (!matches || !currentStock() || !bonded() || !policy.canControl() || (enabled && !policy.owned())) {
                    policy.cancel(); if (!matches) { verified = false; policy.trusted(false); }
                    if (!closed) events.voice(""); return;
                }
                try {
                    context.sendBroadcast(new Intent(VOICE).setPackage(PACKAGE).putExtra("com.google.glass.extra.ENABLE_VOICE_RECOGNITION", enabled));
                    if (enabled) { policy.sent(); events.voice("Siri requested"); main.removeCallbacks(poll); main.post(poll); }
                } catch (RuntimeException ignored) { policy.cancel(); if (!closed) events.voice("Siri unavailable"); }
            } });
        } });
    }
    private boolean bonded() { try { return device != null && device.getBondState() == BluetoothDevice.BOND_BONDED; } catch (RuntimeException ignored) { return false; } }
    private void refreshCall() {
        // A sticky TRUE is only a veto. Never use unauthenticated sticky FALSE to clear a call.
        Intent state = context.registerReceiver(null, new IntentFilter(CALL));
        if (state != null && state.getBooleanExtra("call_state", true)) policy.call(true);
    }
    private boolean currentStock() {
        if (!verified || source == null) return false;
        try { ApplicationInfo info = context.getPackageManager().getApplicationInfo(PACKAGE, 0); File file = new File(info.sourceDir); return info.enabled && source.equals(info.sourceDir) && file.length() == size && file.lastModified() == modified; }
        catch (PackageManager.NameNotFoundException ignored) { return false; }
    }
    private static boolean matchesStock(File file) {
        try { if (file.length() != 2307733) return false; MessageDigest digest = MessageDigest.getInstance("SHA-256"); FileInputStream input = new FileInputStream(file);
            try { byte[] buffer = new byte[32768]; for (int count; (count = input.read(buffer)) != -1;) digest.update(buffer, 0, count); } finally { input.close(); }
            StringBuilder hex = new StringBuilder(); for (byte value : digest.digest()) hex.append(String.format(java.util.Locale.US, "%02x", value & 255)); return STOCK_SHA.equals(hex.toString());
        } catch (Exception ignored) { return false; }
    }
}
