package com.exploreros.glass;

import android.content.Context;
import android.content.SharedPreferences;
import com.exploreros.glass.core.Hex;
import com.exploreros.glass.core.ProtocolException;

/** Application-private pairing key. Values are never logged. */
final class PairingStore {
    private static final String NAME = "explorer_link", KEY = "pairing_key", BLE_ADDRESS = "ble_address";
    private PairingStore() { }
    static boolean backgroundEnabled(Context context) { return context.getSharedPreferences(NAME, Context.MODE_PRIVATE).getBoolean("background_integration", true); }
    static void backgroundEnabled(Context context, boolean enabled) { context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().putBoolean("background_integration", enabled).commit(); }
    static byte[] get(Context context) throws ProtocolException { return Hex.decodeExact(context.getSharedPreferences(NAME, Context.MODE_PRIVATE).getString(KEY, null), 32); }
    static boolean has(Context context) { try { get(context); return true; } catch (ProtocolException ignored) { return false; } }
    static void save(Context context, String hex) throws ProtocolException { String canonical = Hex.encode(Hex.decodeExact(hex, 32)); if (!context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().putString(KEY, canonical).commit()) throw new ProtocolException("key storage failed"); }
    static void revoke(Context context) { context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().remove(KEY).remove(BLE_ADDRESS).commit(); }
    static void clearBleAddress(Context context) { context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().remove(BLE_ADDRESS).commit(); }
    static String bleAddress(Context context) { return context.getSharedPreferences(NAME, Context.MODE_PRIVATE).getString(BLE_ADDRESS, null); }
    static void saveBleAddress(Context context, String address) { context.getSharedPreferences(NAME, Context.MODE_PRIVATE).edit().putString(BLE_ADDRESS, address).commit(); }
}
