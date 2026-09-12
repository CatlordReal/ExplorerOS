package com.exploreros.glass.core;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/** Strict, bounded TCP camera-transfer protocol state. Content bytes are never retained here. */
public final class MediaTransfer {
    public static final int CHUNK_BYTES = 3072, MAX_DATA_BASE64 = 4096, MAX_CANDIDATES = 64, MAX_QUEUE = 16;
    public static final long MAX_IMAGE_BYTES = 50L * 1024L * 1024L, MAX_VIDEO_BYTES = 250L * 1024L * 1024L, MAX_SESSION_BYTES = 500L * 1024L * 1024L, ACK_TIMEOUT_MS = 30000L;
    private MediaTransfer() { }

    public static boolean knownType(String type) { return "media.begin".equals(type) || "media.accept".equals(type) || "media.chunk".equals(type) || "media.ack".equals(type) || "media.finish".equals(type) || "media.complete".equals(type) || "media.cancel".equals(type); }
    public static void validate(String type, Map<String, String> p) throws ProtocolException {
        if ("media.begin".equals(type)) {
            exact(p, "id", "sha256", "bytes", "chunks", "chunk_bytes", "mime", "captured_ms");
            id(p.get("id")); hash(p.get("sha256")); long bytes = number(p.get("bytes"), 1, limitForMime(p.get("mime"))); long chunks = number(p.get("chunks"), 1, (MAX_VIDEO_BYTES + CHUNK_BYTES - 1) / CHUNK_BYTES);
            if (!Integer.toString(CHUNK_BYTES).equals(p.get("chunk_bytes")) || chunks != (bytes + CHUNK_BYTES - 1) / CHUNK_BYTES) throw new ProtocolException("bad media size");
            number(p.get("captured_ms"), 0, Long.MAX_VALUE);
        } else if ("media.accept".equals(type) || "media.finish".equals(type)) { exact(p, "id"); id(p.get("id")); }
        else if ("media.chunk".equals(type)) { exact(p, "id", "index", "data"); id(p.get("id")); number(p.get("index"), 0, (MAX_VIDEO_BYTES + CHUNK_BYTES - 1) / CHUNK_BYTES); byte[] data = Base64Codec.decode(p.get("data")); if (data.length < 1 || data.length > CHUNK_BYTES || p.get("data").length() > MAX_DATA_BASE64 || !Base64Codec.encode(data).equals(p.get("data"))) throw new ProtocolException("bad media chunk"); }
        else if ("media.ack".equals(type)) { exact(p, "id", "next"); id(p.get("id")); number(p.get("next"), 1, (MAX_VIDEO_BYTES + CHUNK_BYTES - 1) / CHUNK_BYTES); }
        else if ("media.complete".equals(type)) { exact(p, "id", "sha256", "bytes", "state"); id(p.get("id")); hash(p.get("sha256")); number(p.get("bytes"), 1, MAX_VIDEO_BYTES); if (!"staged".equals(p.get("state")) && !"deduplicated".equals(p.get("state"))) throw new ProtocolException("bad media state"); }
        else if ("media.cancel".equals(type)) { exact(p, "id", "code"); id(p.get("id")); if (!"disabled".equals(p.get("code")) && !"unsupported".equals(p.get("code")) && !"quota".equals(p.get("code")) && !"storage".equals(p.get("code")) && !"state".equals(p.get("code")) && !"integrity".equals(p.get("code")) && !"timeout".equals(p.get("code"))) throw new ProtocolException("bad media cancel"); }
        else throw new ProtocolException("unknown media type");
    }
    public static boolean image(String mime) { return "image/jpeg".equals(mime) || "image/png".equals(mime); }
    public static boolean video(String mime) { return "video/mp4".equals(mime) || "video/3gpp".equals(mime); }
    public static long limitForMime(String mime) throws ProtocolException { if (image(mime)) return MAX_IMAGE_BYTES; if (video(mime)) return MAX_VIDEO_BYTES; throw new ProtocolException("unsupported media type"); }
    public static boolean mediaReceiveAdvertised(ProtocolMessage message) { if (!"capabilities".equals(message.type) || !"ios".equals(message.payload.get("endpoint"))) return false; String features = message.payload.get("features"); if (features == null) return false; for (String value : features.split(",")) if ("media.receive.tcp.v1".equals(value.trim())) return true; return false; }
    public static Map<String, String> cancel(String id, String code) throws ProtocolException { Map<String, String> out = new LinkedHashMap<String, String>(); out.put("id", id); out.put("code", code); validate("media.cancel", out); return out; }
    private static void exact(Map<String, String> value, String... keys) throws ProtocolException { if (value.size() != keys.length) throw new ProtocolException("wrong media fields"); for (String key : keys) if (!value.containsKey(key)) throw new ProtocolException("missing media field"); }
    private static long number(String value, long min, long max) throws ProtocolException { if (value == null || value.length() == 0 || value.length() > 19 || (value.length() > 1 && value.charAt(0) == '0')) throw new ProtocolException("bad media number"); for (int i = 0; i < value.length(); i++) if (value.charAt(i) < '0' || value.charAt(i) > '9') throw new ProtocolException("bad media number"); try { long parsed = Long.parseLong(value); if (parsed < min || parsed > max) throw new ProtocolException("media number out of range"); return parsed; } catch (NumberFormatException e) { throw new ProtocolException("bad media number"); } }
    private static void id(String value) throws ProtocolException { lowercaseHex(value, 16, "media id"); }
    private static void hash(String value) throws ProtocolException { lowercaseHex(value, 32, "media hash"); }
    private static void lowercaseHex(String value, int bytes, String label) throws ProtocolException { if (value == null || value.length() != bytes * 2 || !value.equals(value.toLowerCase(Locale.US))) throw new ProtocolException("bad " + label); Hex.decodeExact(value, bytes); }

    /** Sender state is pure and holds only one outbound raw chunk at a time. */
    public static final class Sender {
        public static final int WAIT_ACCEPT = 1, READY = 2, WAIT_ACK = 3, WAIT_COMPLETE = 4, COMPLETE = 5, CANCELLED = 6;
        private final String id, sha256, mime, capturedMs; private final long bytes, chunks;
        private int state = WAIT_ACCEPT; private long next, sent; private long activity;
        public Sender(String id, String sha256, long bytes, String mime, long capturedMs, long now) throws ProtocolException {
            this.id = id; this.sha256 = sha256; this.bytes = bytes; this.mime = mime; this.capturedMs = Long.toString(capturedMs); this.chunks = (bytes + CHUNK_BYTES - 1) / CHUNK_BYTES; this.activity = now;
            validate("media.begin", beginPayload());
        }
        public synchronized ProtocolMessage begin() throws ProtocolException { return new ProtocolMessage(1, "media.begin", beginPayload()); }
        public synchronized ProtocolMessage chunk(byte[] data, long now) throws ProtocolException {
            if (state != READY || data == null || data.length < 1 || data.length > CHUNK_BYTES || sent + data.length > bytes || (next + 1 == chunks && sent + data.length != bytes)) throw new ProtocolException("media sender state");
            Map<String, String> p = new LinkedHashMap<String, String>(); p.put("id", id); p.put("index", Long.toString(next)); p.put("data", Base64Codec.encode(data)); ProtocolMessage result = new ProtocolMessage(1, "media.chunk", p); sent += data.length; next++; state = WAIT_ACK; activity = now; return result;
        }
        public synchronized ProtocolMessage finish(long now) throws ProtocolException { if (state != READY || sent != bytes || next != chunks) throw new ProtocolException("media incomplete"); state = WAIT_COMPLETE; activity = now; Map<String, String> p = new LinkedHashMap<String, String>(); p.put("id", id); return new ProtocolMessage(1, "media.finish", p); }
        public synchronized void inbound(ProtocolMessage message, long now) throws ProtocolException {
            if (!knownType(message.type) || "media.begin".equals(message.type) || "media.chunk".equals(message.type) || "media.finish".equals(message.type)) throw new ProtocolException("wrong media direction");
            if (!id.equals(message.payload.get("id"))) throw new ProtocolException("media id mismatch");
            if ("media.accept".equals(message.type)) { if (state != WAIT_ACCEPT) throw new ProtocolException("unexpected media accept"); state = READY; }
            else if ("media.ack".equals(message.type)) { if (state != WAIT_ACK || !Long.toString(next).equals(message.payload.get("next"))) throw new ProtocolException("unexpected media ack"); state = READY; }
            else if ("media.complete".equals(message.type)) { if ((state != WAIT_COMPLETE && !(state == WAIT_ACCEPT && "deduplicated".equals(message.payload.get("state")))) || !sha256.equals(message.payload.get("sha256")) || !Long.toString(bytes).equals(message.payload.get("bytes"))) throw new ProtocolException("bad media complete"); state = COMPLETE; }
            else if ("media.cancel".equals(message.type)) state = CANCELLED;
            activity = now; notifyAll();
        }
        public synchronized boolean await(int expected, long timeoutMs) throws InterruptedException { long until = System.currentTimeMillis() + timeoutMs; while (state != expected && state != COMPLETE && state != CANCELLED) { long left = until - System.currentTimeMillis(); if (left <= 0) return false; wait(left); } return state == expected; }
        public synchronized boolean timedOut(long now) { return state != COMPLETE && state != CANCELLED && now - activity >= ACK_TIMEOUT_MS; }
        public synchronized void cancel() { if (state != COMPLETE) { state = CANCELLED; notifyAll(); } }
        public synchronized int state() { return state; }
        public synchronized String id() { return id; }
        public synchronized long bytes() { return bytes; }
        public synchronized String sha256() { return sha256; }
        private Map<String, String> beginPayload() { Map<String, String> p = new LinkedHashMap<String, String>(); p.put("id", id); p.put("sha256", sha256); p.put("bytes", Long.toString(bytes)); p.put("chunks", Long.toString(chunks)); p.put("chunk_bytes", Integer.toString(CHUNK_BYTES)); p.put("mime", mime); p.put("captured_ms", capturedMs); return p; }
    }
}
