package com.exploreros.glass;

import android.content.Context;
import android.content.SharedPreferences;
import com.exploreros.glass.core.Hex;
import com.exploreros.glass.core.ProtocolException;

/** Application-private pairing key. Values are never logged. */
final class PairingStore {
    private static final String NAME = "explorer_link", KEY = "pairing_key", BLE_ADDRESS = "ble_address", MEDIA_ENABLED = "camera_sync_enabled", MEDIA_DONE = "camera_sync_done";
    private PairingStore() { }
    static boolean backgroundEnabled(Context context) { return context.getSharedPreferences(NAME, Context.MODE_PRIVATE).getBoolean("background_integration", true); }
    static void backgroundEnabled(Context context, boolean enabled) { context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().putBoolean("background_integration", enabled).commit(); }
    static byte[] get(Context context) throws ProtocolException { return Hex.decodeExact(context.getSharedPreferences(NAME, Context.MODE_PRIVATE).getString(KEY, null), 32); }
    static boolean has(Context context) { try { get(context); return true; } catch (ProtocolException ignored) { return false; } }
    static void save(Context context, String hex) throws ProtocolException { String canonical = Hex.encode(Hex.decodeExact(hex, 32)); SharedPreferences values = context.getSharedPreferences(NAME, Context.MODE_PRIVATE); SharedPreferences.Editor edit = values.edit().putString(KEY, canonical); if (!canonical.equals(values.getString(KEY, null))) edit.remove(MEDIA_DONE); if (!edit.commit()) throw new ProtocolException("key storage failed"); }
    static void revoke(Context context) { context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().remove(KEY).remove(BLE_ADDRESS).remove(MEDIA_DONE).remove(MEDIA_ENABLED).commit(); }
    static void clearBleAddress(Context context) { context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().remove(BLE_ADDRESS).commit(); }
    static String bleAddress(Context context) { return context.getSharedPreferences(NAME, Context.MODE_PRIVATE).getString(BLE_ADDRESS, null); }
    static void saveBleAddress(Context context, String address) { context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().putString(BLE_ADDRESS, address).commit(); }
    static boolean cameraSyncEnabled(Context context) { return context.getSharedPreferences(NAME, Context.MODE_PRIVATE).getBoolean(MEDIA_ENABLED, false); }
    static void cameraSyncEnabled(Context context, boolean enabled) { context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().putBoolean(MEDIA_ENABLED, enabled).commit(); }
    static boolean mediaCompleted(Context context, String hash) { for (String value : context.getSharedPreferences(NAME, Context.MODE_PRIVATE).getString(MEDIA_DONE, "").split("\\n")) if (hash.equals(value)) return true; return false; }
    static void recordMediaCompleted(Context context, String hash) throws ProtocolException {
        String canonical = Hex.encode(Hex.decodeExact(hash, 32)); SharedPreferences values = context.getSharedPreferences(NAME, Context.MODE_PRIVATE); String prior = values.getString(MEDIA_DONE, ""); String[] entries = prior.isEmpty() ? new String[0] : prior.split("\\n"); StringBuilder next = new StringBuilder();
        for (int i = Math.max(0, entries.length - 255); i < entries.length; i++) if (!canonical.equals(entries[i])) { if (next.length() > 0) next.append('\n'); next.append(entries[i]); }
        if (next.length() > 0) next.append('\n'); next.append(canonical); if (!values.edit().putString(MEDIA_DONE, next.toString()).commit()) throw new ProtocolException("media ledger storage failed");
    }
}
