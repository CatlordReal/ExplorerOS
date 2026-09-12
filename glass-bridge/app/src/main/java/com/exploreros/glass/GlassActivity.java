package com.exploreros.glass;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import com.exploreros.glass.core.ProtocolMessage;
import com.exploreros.glass.ancs.AncsNotifications;
import com.exploreros.glass.ams.AmsState;
import com.exploreros.glass.ui.GestureDecoder;
import com.exploreros.glass.ui.ThemePolicy;
import com.exploreros.glass.integration.IntegrationPolicy;
import java.util.ArrayList;
import java.util.LinkedHashMap;

/** Card-first display. Setup and explicit phone actions live on separate screens. */
public final class GlassActivity extends Activity implements BridgeEvents.Listener {
    static final String ACTION_PRESENT = "com.exploreros.glass.PRESENT", ACTION_SETUP = "com.exploreros.glass.SETUP", EXTRA_PRESENTATION = "presentation";
    private boolean automatic, resumed, phoneActionsAvailable;
    private String voiceStatus = "";
    private BridgeEvents.Presentation launchPresentation;
    private final android.os.Handler timer = new android.os.Handler();
    private final Runnable automaticTimeout = new Runnable() { public void run() { if (automatic && resumed) returnHome(); } };
    private TextView status, title, body;
    private LinearLayout root, content;
    private final GestureDecoder gestures = new GestureDecoder();
    private final LinkedHashMap<String, String> candidates = new LinkedHashMap<String, String>();
    private final LinkedHashMap<Long, AncsNotifications.Notification> notifications = new LinkedHashMap<Long, AncsNotifications.Notification>();
    private final ArrayList<Button> controls = new ArrayList<Button>();
    private String page = "card", statusText = "Pair iPhone", cardTitle = "Explorer Link", cardBody = "", currentSource = "companion";
    private long selectedUid = -1;
    private AmsState.Snapshot media;
    private boolean cameraLongPress;
    private int selectedControl;
    @Override public void onCreate(Bundle state) { super.onCreate(state); if (!configureLaunch(getIntent())) { finish(); return; } build(); }
    private boolean configureLaunch(Intent intent) {
        automatic = intent != null && ACTION_PRESENT.equals(intent.getAction());
        if (automatic) {
            if (intent.getComponent() == null || !GlassActivity.class.getName().equals(intent.getComponent().getClassName())) return false;
            launchPresentation = BridgeEvents.claimPresentation(intent.getLongExtra(EXTRA_PRESENTATION, -1));
            if (launchPresentation == null || !PairingStore.has(this) || !PairingStore.backgroundEnabled(this) || BridgeEvents.setupActive()) return false;
            page = "card";
            getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON | android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        } else { page = "setup"; launchPresentation = null; getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON); }
        return true;
    }
    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (resumed && !automatic && !"card".equals(page) && ACTION_PRESENT.equals(intent.getAction())) { BridgeEvents.claimPresentation(intent.getLongExtra(EXTRA_PRESENTATION, -1)); return; }
        setIntent(intent); if (!configureLaunch(intent)) { finish(); return; } if (resumed) applyLaunch();
    }
    @Override public void onResume() { super.onResume(); resumed = true; if (isFinishing()) return; BridgeEvents.leavingSetup(); BridgeEvents.set(this); if (!automatic && PairingStore.has(this)) BridgeService.start(this, BridgeService.ACTION_OPEN); applyLaunch(); }
    private void applyLaunch() {
        if (launchPresentation != null) {
            BridgeEvents.Presentation current = BridgeEvents.resolvePresentation(launchPresentation); launchPresentation = null;
            if (current == null) { finish(); return; }
            if (current.notification != null) display(current.notification); else onMessage(current.message);
        }
        timer.removeCallbacks(automaticTimeout); if (automatic) timer.postDelayed(automaticTimeout, IntegrationPolicy.PRESENTATION_MS); build();
    }
    @Override public void onPause() { if (!voiceStatus.isEmpty()) command(BridgeService.ACTION_VOICE_CANCEL); resumed = false; BridgeEvents.detach(this); timer.removeCallbacks(automaticTimeout); super.onPause(); }
    @Override public void onStop() { super.onStop(); if (automatic && !isFinishing()) { BridgeService.presentation.dismissed(currentSource, android.os.SystemClock.elapsedRealtime()); finish(); } if (!PairingStore.backgroundEnabled(this)) stopService(new Intent(this, BridgeService.class)); }
    @Override public void onDestroy() { timer.removeCallbacksAndMessages(null); super.onDestroy(); }
    private void returnHome() {
        BridgeService.presentation.dismissed(currentSource, android.os.SystemClock.elapsedRealtime());
        dismiss(); timer.removeCallbacks(automaticTimeout);
        getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);
        try { startActivity(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); } catch (android.content.ActivityNotFoundException ignored) { }
        finish();
    }
    private void build() {
        controls.clear(); root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(16, 6, 16, 6);
        status = text(12); status.setSingleLine(true); status.setText(voiceStatus.isEmpty() ? statusText : voiceStatus); root.addView(status, new LinearLayout.LayoutParams(-1, 26));
        if ("card".equals(page)) buildCard(); else buildPanel();
        setContentView(root); applyTheme(root); selectedControl = Math.min(selectedControl, Math.max(0, controls.size() - 1));
    }
    private void buildCard() {
        title = text(26); title.setMaxLines(2); title.setText(cardTitle); root.addView(title, new LinearLayout.LayoutParams(-1, -2));
        ScrollView scroll = new ScrollView(this); body = text(20); body.setText(cardBody); scroll.addView(body); root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout bar = row(); addButton(bar, "Actions", new Runnable() { public void run() { show("actions"); } }); addButton(bar, "Media", new Runnable() { public void run() { show("media"); } }); addButton(bar, "Setup", new Runnable() { public void run() { show("setup"); } }); if (phoneActionsAvailable) addButton(bar, "Phone", new Runnable() { public void run() { show("phone"); } }); root.addView(bar, new LinearLayout.LayoutParams(-1, 44));
        View.OnClickListener tap = new View.OnClickListener() { @Override public void onClick(View v) { input(GestureDecoder.TAP); show("actions"); } }; title.setOnClickListener(tap); body.setOnClickListener(tap);
    }
    private void buildPanel() {
        LinearLayout heading = row(); addButton(heading, "Back", new Runnable() { public void run() { show("card"); } }); TextView label = text(20); label.setText("setup".equals(page) ? "Setup" : "media".equals(page) ? "Media" : "phone".equals(page) ? "Phone" : "Actions"); heading.addView(label, new LinearLayout.LayoutParams(0, 44, 2)); root.addView(heading);
        ScrollView scroll = new ScrollView(this); content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL); scroll.addView(content); root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        if ("setup".equals(page)) {
            addButton(content, "Pair QR/key", new Runnable() { public void run() { BridgeEvents.enteringSetup(); startActivity(new Intent(GlassActivity.this, QrProvisioningActivity.class)); } });
            addButton(content, "Bluetooth settings", new Runnable() { public void run() { try { BridgeEvents.enteringSetup(); startActivity(new Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS)); } catch (android.content.ActivityNotFoundException e) { onStatus("Open system Bluetooth settings to pair"); } } });
            if (PairingStore.bleAddress(this) != null) addButton(content, "Reconnect", new Runnable() { public void run() { startService(new Intent(GlassActivity.this, BridgeService.class).setAction(BridgeService.ACTION_CONNECT).putExtra(BridgeService.EXTRA_ADDRESS, PairingStore.bleAddress(GlassActivity.this))); } });
            addButton(content, "Scan iPhone", new Runnable() { public void run() { candidates.clear(); command(BridgeService.ACTION_SCAN); } });
            for (final String address : candidates.keySet()) addButton(content, candidates.get(address) + " · " + address, new Runnable() { public void run() { startService(new Intent(GlassActivity.this, BridgeService.class).setAction(BridgeService.ACTION_CONNECT).putExtra(BridgeService.EXTRA_ADDRESS, address)); show("card"); } });
            addButton(content, "Background: " + (PairingStore.backgroundEnabled(this) ? "On" : "Off"), new Runnable() { public void run() { PairingStore.backgroundEnabled(GlassActivity.this, !PairingStore.backgroundEnabled(GlassActivity.this)); command(BridgeService.ACTION_BACKGROUND_CHANGED); build(); } });
            addButton(content, "Camera sync: " + (PairingStore.cameraSyncEnabled(this) ? "On" : "Off"), new Runnable() { public void run() { boolean enabled = !PairingStore.cameraSyncEnabled(GlassActivity.this); PairingStore.cameraSyncEnabled(GlassActivity.this, enabled); startService(new Intent(GlassActivity.this, BridgeService.class).setAction(BridgeService.ACTION_MEDIA_SYNC).putExtra(BridgeService.EXTRA_ENABLED, enabled)); build(); } });
            addButton(content, "Theme", new Runnable() { public void run() { ThemePolicy.next(GlassActivity.this); build(); } });
            addButton(content, "Revoke pairing", new Runnable() { public void run() { command(BridgeService.ACTION_REVOKE); show("card"); } });
        } else if ("phone".equals(page) && phoneActionsAvailable) {
            phoneButton("Focus on", "focus.on"); phoneButton("Focus off", "focus.off");
            phoneButton("Silent on", "silent.on"); phoneButton("Silent off", "silent.off");
            phoneButton("New note on iPhone", "notes.create"); phoneButton("Browse notes", "notes.browse");
        } else if ("media".equals(page)) {
            TextView track = text(23); track.setText(media == null ? "AMS unavailable" : media.title); content.addView(track);
            TextView artist = text(18); artist.setText(media == null ? "" : media.artist + "\n" + media.player); content.addView(artist);
            LinearLayout transport = row(); mediaButton(transport, "Previous", AmsState.PREVIOUS); mediaButton(transport, "Play", AmsState.PLAY); mediaButton(transport, "Pause", AmsState.PAUSE); mediaButton(transport, "Next", AmsState.NEXT); content.addView(transport);
            mediaButton(content, "Play / Pause", AmsState.TOGGLE);
        } else {
            final AncsNotifications.Notification n = notifications.get(selectedUid);
            if (n != null) {
                TextView note = text(20); note.setText(n.title); content.addView(note);
                if (n.positive()) notificationButton(n, n.positiveLabel, "Positive action", 0);
                if (n.negative()) notificationButton(n, n.negativeLabel, "Negative action", 1);
                if (!n.positive() && !n.negative()) { TextView unavailable = text(18); unavailable.setText("No phone actions"); content.addView(unavailable); }
            }
            addButton(content, "Dismiss card", new Runnable() { public void run() { input(GestureDecoder.DOWN); if (automatic) returnHome(); else { dismiss(); show("card"); } } });
            if (phoneActionsAvailable) addButton(content, "Phone", new Runnable() { public void run() { show("phone"); } });
            addButton(content, "Media", new Runnable() { public void run() { show("media"); } });
            addButton(content, "Setup", new Runnable() { public void run() { show("setup"); } });
            for (final AncsNotifications.Notification item : notifications.values()) if (item.uid != selectedUid) addButton(content, item.title, new Runnable() { public void run() { display(item); show("card"); } });
        }
    }
    private void phoneButton(String label, final String action) { addButton(content, label, new Runnable() { public void run() { startService(new Intent(GlassActivity.this, BridgeService.class).setAction(BridgeService.ACTION_PHONE).putExtra(BridgeService.EXTRA_PHONE_ACTION, action)); } }); }
    private void notificationButton(final AncsNotifications.Notification n, String label, String fallback, final int action) { addButton(content, "Reply".equalsIgnoreCase(label) ? "Open reply on iPhone" : label == null || label.length() == 0 ? fallback : label, new Runnable() { public void run() { startService(new Intent(GlassActivity.this, BridgeService.class).setAction(BridgeService.ACTION_NOTIFICATION).putExtra(BridgeService.EXTRA_UID, n.uid).putExtra(BridgeService.EXTRA_COMMAND, action)); show("card"); } }); }
    private void mediaButton(LinearLayout parent, String label, final int command) { Button b = addButton(parent, label, new Runnable() { public void run() { startService(new Intent(GlassActivity.this, BridgeService.class).setAction(BridgeService.ACTION_MEDIA).putExtra(BridgeService.EXTRA_COMMAND, command)); } }); b.setEnabled(media != null && media.supports(command)); }
    private LinearLayout row() { LinearLayout value = new LinearLayout(this); value.setOrientation(LinearLayout.HORIZONTAL); return value; }
    private TextView text(int size) { TextView value = new TextView(this); value.setTextSize(size); value.setPadding(0, 3, 0, 3); return value; }
    private Button addButton(LinearLayout parent, String label, final Runnable action) { Button value = new Button(this); value.setText(label); value.setTextSize(15); value.setSingleLine(true); value.setMinHeight(0); value.setMinimumHeight(0); value.setPadding(8, 0, 8, 0); value.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { action.run(); } }); controls.add(value); parent.addView(value, parent.getOrientation() == LinearLayout.HORIZONTAL ? new LinearLayout.LayoutParams(0, 44, 1) : new LinearLayout.LayoutParams(-1, 44)); return value; }
    private void show(String destination) { if ("setup".equals(destination)) { automatic = false; timer.removeCallbacks(automaticTimeout); getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON); } page = destination; selectedControl = 0; build(); }
    @Override public void onStatus(final String value) { runOnUiThread(new Runnable() { public void run() { statusText = value; if (status != null) status.setText(voiceStatus.isEmpty() ? value : voiceStatus); } }); }
    @Override public void onVoice(final String value) { runOnUiThread(new Runnable() { public void run() { voiceStatus = value; if (status != null) status.setText(value.isEmpty() ? statusText : value); } }); }
    @Override public void onMessage(final ProtocolMessage message) { runOnUiThread(new Runnable() { public void run() {
        if ("card".equals(message.type)) { selectedUid = -1; currentSource = "companion"; cardTitle = message.payload.get("title"); cardBody = message.payload.get("body"); }
        else if ("navigation".equals(message.type)) { selectedUid = -1; currentSource = "navigation"; cardTitle = message.payload.get("instruction"); cardBody = message.payload.get("distance") + " · " + message.payload.get("destination") + "\n" + message.payload.get("step") + "/" + message.payload.get("total"); }
        else if ("navigation.stop".equals(message.type) && "navigation".equals(currentSource)) { if (automatic) { returnHome(); return; } dismiss(); } else return;
        if ("card".equals(page)) build();
    } }); }
    @Override public void onBleCandidate(final String name, final String address) { runOnUiThread(new Runnable() { public void run() { candidates.put(address, name); if ("setup".equals(page)) build(); } }); }
    @Override public void onNotification(final AncsNotifications.Notification n) { runOnUiThread(new Runnable() { public void run() { notifications.put(n.uid, n); if (!"navigation".equals(currentSource) && (!automatic || selectedUid == n.uid || (n.newlyAdded && (n.flags & (IntegrationPolicy.ANCS_PREEXISTING | IntegrationPolicy.ANCS_SILENT)) == 0))) display(n); if ("card".equals(page) || "actions".equals(page)) build(); } }); }
    @Override public void onRemoved(final long uid) { runOnUiThread(new Runnable() { public void run() { notifications.remove(uid); if (selectedUid == uid) { if (automatic) { returnHome(); return; } dismiss(); } if ("card".equals(page) || "actions".equals(page)) build(); } }); }
    @Override public void onPhoneActions(final boolean available) { runOnUiThread(new Runnable() { public void run() { phoneActionsAvailable = available; if (!available && "phone".equals(page)) page = "card"; if (root != null) build(); } }); }
    @Override public void onInvalidated(final long uid) { runOnUiThread(new Runnable() { public void run() { notifications.remove(uid); if ("actions".equals(page)) build(); } }); }
    @Override public void onBleCleared() { runOnUiThread(new Runnable() { public void run() { candidates.clear(); media = null; if ("media".equals(page) || "setup".equals(page)) build(); } }); }
    @Override public void onMedia(final AmsState.Snapshot value) { runOnUiThread(new Runnable() { public void run() { media = value; if ("media".equals(page)) build(); } }); }
    @Override public void onCompanionCleared() { runOnUiThread(new Runnable() { public void run() { if (!"ancs".equals(currentSource)) { if (automatic) { returnHome(); return; } dismiss(); if ("card".equals(page)) build(); } } }); }
    @Override public void onCleared() { runOnUiThread(new Runnable() { public void run() { candidates.clear(); notifications.clear(); media = null; phoneActionsAvailable = false; if (automatic) { returnHome(); return; } dismiss(); build(); } }); }
    private void display(AncsNotifications.Notification n) { selectedUid = n.uid; currentSource = "ancs"; cardTitle = n.title; cardBody = n.body; }
    private void dismiss() { selectedUid = -1; currentSource = "companion"; cardTitle = "Explorer Link"; cardBody = ""; }
    // Observe before child dispatch: ScrollView/Button consumption must not lose swipes.
    @Override public boolean dispatchTouchEvent(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) gestures.down(event.getEventTime(), event.getX(), event.getY());
        else if (event.getActionMasked() == MotionEvent.ACTION_UP) { String gesture = gestures.up(event.getEventTime(), event.getX(), event.getY()); if (gesture != null && gesture.startsWith("swipe")) { MotionEvent cancel = MotionEvent.obtain(event); cancel.setAction(MotionEvent.ACTION_CANCEL); super.dispatchTouchEvent(cancel); cancel.recycle(); gesture(gesture); return true; } if (GestureDecoder.DOUBLE_TAP.equals(gesture) && "card".equals(page)) input(gesture); }
        return super.dispatchTouchEvent(event);
    }
    @Override public boolean dispatchGenericMotionEvent(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) { gestures.down(event.getEventTime(), event.getX(), event.getY()); return true; }
        if (event.getActionMasked() == MotionEvent.ACTION_UP) { String value = gestures.up(event.getEventTime(), event.getX(), event.getY()); if (value != null) gesture(value); return true; }
        return super.dispatchGenericMotionEvent(event);
    }
    private void gesture(String value) {
        if ("card".equals(page)) { input(value); if (GestureDecoder.DOWN.equals(value)) { if (automatic) returnHome(); else { dismiss(); build(); } } else if (GestureDecoder.TAP.equals(value)) show("actions"); }
        else if (GestureDecoder.DOWN.equals(value)) show("card");
        else if (GestureDecoder.LEFT.equals(value) || GestureDecoder.RIGHT.equals(value)) { int direction = GestureDecoder.RIGHT.equals(value) ? 1 : -1; for (int i = 0; i < controls.size(); i++) { selectedControl = (selectedControl + direction + controls.size()) % controls.size(); if (controls.get(selectedControl).isEnabled()) { controls.get(selectedControl).requestFocus(); break; } } }
        else if (GestureDecoder.TAP.equals(value) && !controls.isEmpty()) { Button selected = controls.get(selectedControl); if (selected.isEnabled()) selected.performClick(); }
    }
    @Override public boolean onKeyDown(int keyCode, KeyEvent event) { if (keyCode == KeyEvent.KEYCODE_CAMERA) { if (event.getRepeatCount() == 0) event.startTracking(); return true; } if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER && event.getRepeatCount() == 0) { gesture(GestureDecoder.TAP); return true; } return super.onKeyDown(keyCode, event); }
    @Override public boolean onKeyLongPress(int keyCode, KeyEvent event) { if (keyCode == KeyEvent.KEYCODE_CAMERA) { cameraLongPress = true; input("cameraLongPress"); return true; } return super.onKeyLongPress(keyCode, event); }
    @Override public boolean onKeyUp(int keyCode, KeyEvent event) { if (keyCode == KeyEvent.KEYCODE_CAMERA) { if (cameraLongPress || event.isCanceled()) command(BridgeService.ACTION_VOICE_CANCEL); else if (event.isTracking()) input("camera"); cameraLongPress = false; return true; } return super.onKeyUp(keyCode, event); }
    @Override public void onBackPressed() { if (automatic) { returnHome(); return; } if (!"card".equals(page)) show("card"); else super.onBackPressed(); }
    private void input(String gesture) { startService(new Intent(this, BridgeService.class).setAction(BridgeService.ACTION_INPUT).putExtra(BridgeService.EXTRA_GESTURE, gesture)); }
    private void command(String action) { startService(new Intent(this, BridgeService.class).setAction(action)); }
    private void applyTheme(View view) { int[] colors = ThemePolicy.colors(this); if (view == root) view.setBackgroundColor(colors[0]); if (view instanceof TextView) ((TextView)view).setTextColor(colors[1]); if (view instanceof ViewGroup) for (int i = 0; i < ((ViewGroup)view).getChildCount(); i++) applyTheme(((ViewGroup)view).getChildAt(i)); }
}
