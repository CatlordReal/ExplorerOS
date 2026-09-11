package com.exploreros.glass.core;

import java.nio.ByteBuffer;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.util.ArrayList;
import java.util.List;

/** Bounded UTF-8 LF framing. CR is data, never silently removed. */
public final class LineAccumulator {
    public static final int MAX_LINE = 32768;
    private final byte[] bytes = new byte[MAX_LINE]; private int length;
    public List<String> accept(byte[] input, int offset, int count) throws ProtocolException {
        if (input == null || offset < 0 || count < 0 || offset + count > input.length) throw new ProtocolException("bad input bounds");
        ArrayList<String> out = new ArrayList<String>();
        for (int i = offset; i < offset + count; i++) { byte b = input[i]; if (b == '\n') { out.add(decode()); length = 0; } else { if (length == MAX_LINE) throw new ProtocolException("line too large"); bytes[length++] = b; } }
        return out;
    }
    private String decode() throws ProtocolException { try { CharsetDecoder decoder = Charset.forName("UTF-8").newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT); return decoder.decode(ByteBuffer.wrap(bytes, 0, length)).toString(); } catch (Exception e) { throw new ProtocolException("invalid UTF-8", e); } }
    public void clear() { length = 0; }
}
