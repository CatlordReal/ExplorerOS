package com.exploreros.glass.ams;

import com.exploreros.glass.core.ProtocolException;
import java.nio.ByteBuffer;
import java.nio.charset.Charset;
import java.nio.charset.CodingErrorAction;
import java.util.BitSet;

/** Wire values from Apple's AMS specification; contains no Android dependencies. */
public final class AmsState {
    public static final int PLAY = 0, PAUSE = 1, TOGGLE = 2, NEXT = 3, PREVIOUS = 4;
    public static final String REMOTE_UUID = "9B3C81D8-57B1-4A8A-B8DF-0E56F7CA51C2";
    private final BitSet supported = new BitSet(14);
    private String title = "", artist = "", player = "", playback = "";
    public static byte[][] subscriptions() { return new byte[][] { {0, 0, 1}, {2, 0, 2} }; }
    public synchronized void commands(byte[] value) { supported.clear(); if (value != null) for (byte command : value) if ((command & 255) <= 13) supported.set(command & 255); }
    public synchronized boolean supports(int command) { return command >= 0 && command <= 13 && supported.get(command); }
    public synchronized byte[] command(int command) throws ProtocolException { if (!supports(command)) throw new ProtocolException("AMS command unavailable"); return new byte[] {(byte) command}; }
    public synchronized void update(byte[] value) throws ProtocolException {
        if (value == null || value.length < 3 || value.length > 4099) throw new ProtocolException("invalid AMS update");
        int entity = value[0] & 255, attribute = value[1] & 255;
        if (!(entity == 0 && (attribute == 0 || attribute == 1)) && !(entity == 2 && (attribute == 0 || attribute == 2))) return;
        String text;
        try { text = Charset.forName("UTF-8").newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(value, 3, value.length - 3)).toString(); }
        catch (Exception e) { throw new ProtocolException("invalid AMS UTF-8", e); }
        // Glass intentionally displays the bounded notification preview. Mark truncation visibly.
        if ((value[2] & 1) != 0) text += "…";
        if (entity == 2 && attribute == 2) title = text;
        else if (entity == 2) artist = text;
        else if (attribute == 0) player = text;
        else playback = text;
    }
    public synchronized Snapshot snapshot() { return new Snapshot(title, artist, player, playback, supported); }
    public synchronized void clear() { supported.clear(); title = artist = player = playback = ""; }
    public static final class Snapshot {
        public final String title, artist, player, playback;
        private final BitSet commands;
        Snapshot(String title, String artist, String player, String playback, BitSet commands) { this.title = title; this.artist = artist; this.player = player; this.playback = playback; this.commands = (BitSet) commands.clone(); }
        public boolean supports(int command) { return command >= 0 && command <= 13 && commands.get(command); }
    }
}
