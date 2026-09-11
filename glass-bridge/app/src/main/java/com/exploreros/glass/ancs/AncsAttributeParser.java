package com.exploreros.glass.ancs;

import com.exploreros.glass.core.ProtocolException;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Parses one fragmented ANCS notification-attribute response with known requested IDs. */
public final class AncsAttributeParser {
    public static final int COMMAND_NOTIFICATION_ATTRIBUTES = 0;
    private static final int MAX_ATTRIBUTE_BYTES = 4096, MAX_RESPONSE_BYTES = 32768;
    private final byte[] requested; private final byte[] buffer = new byte[MAX_RESPONSE_BYTES]; private int size, offset; private long uid = -1; private final Map<Integer, String> attributes = new LinkedHashMap<Integer, String>();
    public AncsAttributeParser(byte[] requested) { this.requested = requested.clone(); }
    public void reset(long expectedUid) { Arrays.fill(buffer, (byte) 0); size = offset = 0; uid = expectedUid; attributes.clear(); }
    public Result accept(byte[] data) throws ProtocolException {
        if (uid < 0) throw new ProtocolException("ANCS parser not armed"); if (data == null || data.length == 0 || size + data.length > MAX_RESPONSE_BYTES) throw new ProtocolException("ANCS response too large");
        System.arraycopy(data, 0, buffer, size, data.length); size += data.length;
        if (offset == 0) { if (size < 5) return null; if ((buffer[0] & 255) != COMMAND_NOTIFICATION_ATTRIBUTES || little32(buffer, 1) != uid) throw new ProtocolException("unexpected ANCS response"); offset = 5; }
        while (attributes.size() < requested.length) {
            if (size - offset < 3) return null; int id = buffer[offset] & 255, len = little16(buffer, offset + 1); if (len > MAX_ATTRIBUTE_BYTES) throw new ProtocolException("ANCS attribute too large"); if (size - offset - 3 < len) return null;
            if (id != (requested[attributes.size()] & 255)) throw new ProtocolException("unexpected ANCS attribute");
            attributes.put(Integer.valueOf(id), strictUtf8(buffer, offset + 3, len)); offset += 3 + len;
        }
        if (offset != size) throw new ProtocolException("trailing ANCS attribute bytes"); Result result = new Result(uid, attributes); reset(-1); return result;
    }
    private static String strictUtf8(byte[] source, int offset, int length) throws ProtocolException { try { return Charset.forName("UTF-8").newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(source, offset, length)).toString(); } catch (Exception e) { throw new ProtocolException("invalid ANCS UTF-8", e); } }
    private static long little32(byte[] bytes, int p) { return ((long) bytes[p] & 255) | (((long) bytes[p + 1] & 255) << 8) | (((long) bytes[p + 2] & 255) << 16) | (((long) bytes[p + 3] & 255) << 24); }
    private static int little16(byte[] bytes, int p) { return (bytes[p] & 255) | ((bytes[p + 1] & 255) << 8); }
    public static final class Result { public final long uid; public final Map<Integer, String> attributes; Result(long uid, Map<Integer, String> attributes) { this.uid = uid; this.attributes = new LinkedHashMap<Integer, String>(attributes); } }
}
