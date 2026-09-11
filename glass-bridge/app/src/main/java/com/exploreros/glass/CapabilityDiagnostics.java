package com.exploreros.glass;

import android.bluetooth.BluetoothAdapter;
import android.content.Context;
import javax.crypto.Cipher;

/** Facts only: discovered services are reported later, never inferred from device model. */
final class CapabilityDiagnostics {
    private CapabilityDiagnostics() { }
    static String startup(Context context) { boolean crypto = false; try { Cipher.getInstance("AES/GCM/NoPadding"); crypto = true; } catch (Exception ignored) { } BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter(); return "API19 bridge: AES-GCM " + (crypto ? "ready" : "unavailable") + ", BLE central " + (adapter != null && adapter.isEnabled() ? "ready" : "unavailable") + ", HFP state pending"; }
}
