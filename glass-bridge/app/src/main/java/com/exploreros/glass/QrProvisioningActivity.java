package com.exploreros.glass;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.exploreros.glass.core.MiniJson;
import com.exploreros.glass.core.Hex;
import com.exploreros.glass.core.ProtocolException;
import java.util.Map;

/** Uses ZXing when installed; paste remains available without a bundled scanner dependency. */
public final class QrProvisioningActivity extends Activity {
    private static final int SCAN = 71; private EditText payload; private TextView status;
    @Override public void onCreate(Bundle state) { super.onCreate(state); BridgeEvents.enteringSetup(); LinearLayout root = new LinearLayout(this); root.setPadding(18, 18, 18, 18); root.setOrientation(LinearLayout.VERTICAL); status = new TextView(this); status.setText("Scan iPhone Explorer Link QR or paste provisioning payload"); payload = new EditText(this); payload.setHint("{\"service\":\"explorerlink\",...}"); Button scan = new Button(this); scan.setText("Scan with ZXing"); scan.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { scan(); } }); Button save = new Button(this); save.setText("Save pairing key"); save.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { save(); } }); root.addView(status); root.addView(payload); root.addView(scan); root.addView(save); setContentView(root); }
    @Override public void onStop() { super.onStop(); if (!PairingStore.backgroundEnabled(this) && !BridgeEvents.foreground()) stopService(new Intent(this, BridgeService.class)); }
    @Override public void onDestroy() { BridgeEvents.leavingSetup(); super.onDestroy(); }
    private void scan() { try { Intent intent = new Intent("com.google.zxing.client.android.SCAN"); intent.putExtra("SCAN_MODE", "QR_CODE_MODE"); startActivityForResult(intent, SCAN); } catch (Exception e) { status.setText("ZXing scanner unavailable; paste QR payload"); } }
    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) { super.onActivityResult(requestCode, resultCode, data); if (requestCode == SCAN && resultCode == RESULT_OK && data != null) { payload.setText(data.getStringExtra("SCAN_RESULT")); save(); } }
    private void save() { try { Map<String, Object> value = MiniJson.object(payload.getText().toString()); if (!"explorerlink".equals(value.get("service")) || !(value.get("v") instanceof Long) || ((Long) value.get("v")).longValue() != 1 || !(value.get("key") instanceof String)) throw new ProtocolException("not an Explorer Link QR payload"); Hex.decodeExact((String) value.get("key"), 32); startService(new Intent(this, BridgeService.class).setAction(BridgeService.ACTION_REKEY).putExtra(BridgeService.EXTRA_KEY, (String) value.get("key"))); finish(); } catch (ProtocolException e) { status.setText("Invalid provisioning payload"); } }
}
