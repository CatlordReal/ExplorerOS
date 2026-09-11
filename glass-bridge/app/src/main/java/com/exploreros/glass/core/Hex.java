package com.exploreros.glass.core;

/** Strict hex used for challenges and provisioning keys. */
public final class Hex {
    private Hex() { }
    public static String encode(byte[] bytes) {
        char[] out = new char[bytes.length * 2];
        final char[] table = "0123456789abcdef".toCharArray();
        for (int i = 0; i < bytes.length; i++) { int b = bytes[i] & 0xff; out[i * 2] = table[b >>> 4]; out[i * 2 + 1] = table[b & 15]; }
        return new String(out);
    }
    public static byte[] decodeExact(String value, int length) throws ProtocolException {
        if (value == null || value.length() != length * 2) throw new ProtocolException("bad hex length");
        byte[] out = new byte[length];
        for (int i = 0; i < out.length; i++) {
            int hi = Character.digit(value.charAt(i * 2), 16), lo = Character.digit(value.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) throw new ProtocolException("bad hex");
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }
}
