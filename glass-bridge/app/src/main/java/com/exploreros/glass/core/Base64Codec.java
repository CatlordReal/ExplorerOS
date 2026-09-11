package com.exploreros.glass.core;

/** Android API 19/JVM compatible strict RFC 4648 Base64 without line wrapping. */
public final class Base64Codec {
    private static final char[] ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();
    private Base64Codec() { }
    public static String encode(byte[] in) {
        StringBuilder out = new StringBuilder(((in.length + 2) / 3) * 4);
        for (int p = 0; p < in.length; p += 3) {
            int left = in.length - p, n = (in[p] & 255) << 16;
            if (left > 1) n |= (in[p + 1] & 255) << 8;
            if (left > 2) n |= in[p + 2] & 255;
            out.append(ALPHABET[(n >>> 18) & 63]).append(ALPHABET[(n >>> 12) & 63]);
            out.append(left > 1 ? ALPHABET[(n >>> 6) & 63] : '=');
            out.append(left > 2 ? ALPHABET[n & 63] : '=');
        }
        return out.toString();
    }
    public static byte[] decode(String text) throws ProtocolException {
        if (text == null || (text.length() & 3) != 0) throw new ProtocolException("bad base64");
        int pad = text.length() == 0 ? 0 : (text.charAt(text.length() - 1) == '=' ? 1 : 0) + (text.length() > 1 && text.charAt(text.length() - 2) == '=' ? 1 : 0);
        byte[] out = new byte[text.length() / 4 * 3 - pad]; int o = 0;
        for (int p = 0; p < text.length(); p += 4) {
            char cChar = text.charAt(p + 2), dChar = text.charAt(p + 3); int a = value(text.charAt(p)), b = value(text.charAt(p + 1));
            int c = cChar == '=' ? 0 : value(cChar), d = dChar == '=' ? 0 : value(dChar);
            if (a < 0 || b < 0 || c < 0 || d < 0 || (p + 4 != text.length() && (cChar == '=' || dChar == '=')) || (cChar == '=' && dChar != '=') || (cChar == '=' && pad != 2) || (dChar == '=' && cChar != '=' && pad != 1)) throw new ProtocolException("bad base64");
            int n = (a << 18) | (b << 12) | (c << 6) | d;
            if (o < out.length) out[o++] = (byte) (n >>> 16); if (o < out.length) out[o++] = (byte) (n >>> 8); if (o < out.length) out[o++] = (byte) n;
        }
        return out;
    }
    private static int value(char c) { if (c >= 'A' && c <= 'Z') return c - 'A'; if (c >= 'a' && c <= 'z') return c - 'a' + 26; if (c >= '0' && c <= '9') return c - '0' + 52; return c == '+' ? 62 : c == '/' ? 63 : -1; }
}
