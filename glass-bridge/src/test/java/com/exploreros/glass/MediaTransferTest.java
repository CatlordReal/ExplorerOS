package com.exploreros.glass;

import com.exploreros.glass.core.Base64Codec;
import com.exploreros.glass.core.MediaTransfer;
import com.exploreros.glass.core.ProtocolException;
import com.exploreros.glass.core.ProtocolMessage;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

/** Pure sender/schema regressions. No camera files, Android runtime, or network. */
public final class MediaTransferTest {
    private static final String ID = "00112233445566778899aabbccddeeff", HASH = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    public static void main(String[] args) throws Exception { schemas(); sender(); deduplicatedBegin(); timeoutAndCancel(); System.out.println("MediaTransferTest: PASS"); }
    private static void schemas() throws Exception {
        Map<String, String> begin = begin(3073, 2); new ProtocolMessage(1, "media.begin", begin);
        Map<String, String> chunk = map("id", ID); chunk.put("index", "0"); chunk.put("data", Base64Codec.encode(new byte[MediaTransfer.CHUNK_BYTES])); new ProtocolMessage(1, "media.chunk", chunk); equal(MediaTransfer.MAX_DATA_BASE64, chunk.get("data").length());
        final Map<String, String> oversized = new LinkedHashMap<String, String>(chunk); oversized.put("data", Base64Codec.encode(new byte[MediaTransfer.CHUNK_BYTES + 1])); bad(new Throwing() { public void run() throws Exception { new ProtocolMessage(1, "media.chunk", oversized); } });
        final Map<String, String> wrongChunks = begin(3073, 3); bad(new Throwing() { public void run() throws Exception { new ProtocolMessage(1, "media.begin", wrongChunks); } });
        final Map<String, String> badMime = begin(1, 1); badMime.put("mime", "application/pdf"); bad(new Throwing() { public void run() throws Exception { new ProtocolMessage(1, "media.begin", badMime); } });
        final Map<String, String> upper = begin(1, 1); upper.put("id", ID.toUpperCase()); bad(new Throwing() { public void run() throws Exception { new ProtocolMessage(1, "media.begin", upper); } });
    }
    private static void sender() throws Exception {
        MediaTransfer.Sender sender = new MediaTransfer.Sender(ID, HASH, 3073, "image/jpeg", 9, 0);
        equal("media.begin", sender.begin().type);
        bad(new Throwing() { public void run() throws Exception { sender.inbound(new ProtocolMessage(1, "media.begin", begin(1, 1)), 1); } });
        sender.inbound(new ProtocolMessage(1, "media.accept", map("id", ID)), 1);
        ProtocolMessage first = sender.chunk(new byte[MediaTransfer.CHUNK_BYTES], 2); equal("0", first.payload.get("index"));
        bad(new Throwing() { public void run() throws Exception { sender.finish(3); } });
        sender.inbound(new ProtocolMessage(1, "media.ack", pair("id", ID, "next", "1")), 3);
        bad(new Throwing() { public void run() throws Exception { sender.inbound(new ProtocolMessage(1, "media.ack", pair("id", ID, "next", "1")), 4); } });
        ProtocolMessage finalChunk = sender.chunk(new byte[] {7}, 5); equal("1", finalChunk.payload.get("index"));
        sender.inbound(new ProtocolMessage(1, "media.ack", pair("id", ID, "next", "2")), 6);
        equal("media.finish", sender.finish(7).type);
        final Map<String, String> wrong = complete(HASH.substring(0, 63) + "0", 3073); bad(new Throwing() { public void run() throws Exception { sender.inbound(new ProtocolMessage(1, "media.complete", wrong), 8); } });
        sender.inbound(new ProtocolMessage(1, "media.complete", complete(HASH, 3073)), 9); equal(MediaTransfer.Sender.COMPLETE, sender.state());
    }
    private static void timeoutAndCancel() throws Exception {
        MediaTransfer.Sender timeout = new MediaTransfer.Sender(ID, HASH, 1, "image/jpeg", 0, 0); equal(false, timeout.timedOut(MediaTransfer.ACK_TIMEOUT_MS - 1)); equal(true, timeout.timedOut(MediaTransfer.ACK_TIMEOUT_MS));
        MediaTransfer.Sender missingComplete = new MediaTransfer.Sender(ID, HASH, 1, "image/jpeg", 0, 0);
        missingComplete.inbound(new ProtocolMessage(1, "media.accept", map("id", ID)), 1);
        missingComplete.chunk(new byte[] {1}, 2);
        missingComplete.inbound(new ProtocolMessage(1, "media.ack", pair("id", ID, "next", "1")), 3);
        missingComplete.finish(4);
        equal(false, missingComplete.timedOut(4 + MediaTransfer.ACK_TIMEOUT_MS - 1));
        equal(true, missingComplete.timedOut(4 + MediaTransfer.ACK_TIMEOUT_MS));
        MediaTransfer.Sender optout = new MediaTransfer.Sender(ID, HASH, 1, "image/jpeg", 0, 0); optout.cancel(); equal(MediaTransfer.Sender.CANCELLED, optout.state()); bad(new Throwing() { public void run() throws Exception { optout.chunk(new byte[] {1}, 1); } });
        MediaTransfer.Sender cancelled = new MediaTransfer.Sender(ID, HASH, 1, "image/jpeg", 0, 0); cancelled.inbound(new ProtocolMessage(1, "media.cancel", pair("id", ID, "code", "disabled")), 1); equal(MediaTransfer.Sender.CANCELLED, cancelled.state());
    }
    private static void deduplicatedBegin() throws Exception {
        MediaTransfer.Sender sender = new MediaTransfer.Sender(ID, HASH, 1, "image/jpeg", 0, 0); Map<String, String> complete = complete(HASH, 1); complete.put("state", "deduplicated"); sender.inbound(new ProtocolMessage(1, "media.complete", complete), 1); equal(MediaTransfer.Sender.COMPLETE, sender.state());
    }
    private static Map<String, String> begin(long bytes, long chunks) { Map<String, String> p = new LinkedHashMap<String, String>(); p.put("id", ID); p.put("sha256", HASH); p.put("bytes", Long.toString(bytes)); p.put("chunks", Long.toString(chunks)); p.put("chunk_bytes", "3072"); p.put("mime", "image/jpeg"); p.put("captured_ms", "0"); return p; }
    private static Map<String, String> complete(String hash, long bytes) { Map<String, String> p = pair("id", ID, "sha256", hash); p.put("bytes", Long.toString(bytes)); p.put("state", "staged"); return p; }
    private static Map<String, String> map(String key, String value) { Map<String, String> p = new LinkedHashMap<String, String>(); p.put(key, value); return p; }
    private static Map<String, String> pair(String a, String b, String c, String d) { Map<String, String> p = map(a, b); p.put(c, d); return p; }
    private static void equal(Object expected, Object actual) { if (expected == null ? actual != null : !expected.equals(actual)) throw new AssertionError("expected " + expected + ", got " + actual); }
    private static void bad(Throwing test) throws Exception { try { test.run(); throw new AssertionError("expected ProtocolException"); } catch (ProtocolException expected) { } }
    private interface Throwing { void run() throws Exception; }
}
