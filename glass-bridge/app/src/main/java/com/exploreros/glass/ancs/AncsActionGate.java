package com.exploreros.glass.ancs;

import com.exploreros.glass.core.ProtocolException;

/** ANCS action payloads are emitted only after Notification Source advertises the flag. */
public final class AncsActionGate {
    public static final int FLAG_POSITIVE_ACTION = 1 << 3, FLAG_NEGATIVE_ACTION = 1 << 4;
    public static final int POSITIVE = 0, NEGATIVE = 1;
    private AncsActionGate() { }
    public static byte[] command(long uid, int eventFlags, int action) throws ProtocolException {
        if (uid < 0 || uid > 0xffffffffL) throw new ProtocolException("bad ANCS uid"); if (action == POSITIVE && (eventFlags & FLAG_POSITIVE_ACTION) == 0) throw new ProtocolException("positive action unavailable"); if (action == NEGATIVE && (eventFlags & FLAG_NEGATIVE_ACTION) == 0) throw new ProtocolException("negative action unavailable"); if (action != POSITIVE && action != NEGATIVE) throw new ProtocolException("unknown ANCS action");
        return new byte[] { 2, (byte) uid, (byte) (uid >>> 8), (byte) (uid >>> 16), (byte) (uid >>> 24), (byte) action };
    }
}
