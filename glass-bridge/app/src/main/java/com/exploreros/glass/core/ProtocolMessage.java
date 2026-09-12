package com.exploreros.glass.core;

import java.nio.charset.Charset;
import java.util.LinkedHashMap;
import java.util.Map;

/** Validated encrypted inner protocol message. */
public final class ProtocolMessage {
    public final long sequence; public final String type; public final Map<String, String> payload; public final boolean knownType;
    public ProtocolMessage(long sequence, String type, Map<String, String> payload) throws ProtocolException { this.sequence = sequence; this.type = type; this.payload = new LinkedHashMap<String, String>(payload); knownType = isKnownType(type); validate(); }
    public static ProtocolMessage parse(String json, String expectedChallenge) throws ProtocolException {
        Map<String, Object> raw = MiniJson.object(json); if (raw.size() != 4 || !raw.containsKey("challenge") || !raw.containsKey("seq") || !raw.containsKey("type") || !raw.containsKey("payload")) throw new ProtocolException("malformed message"); requireVersion(raw);
        if (!expectedChallenge.equals(string(raw, "challenge"))) throw new ProtocolException("challenge mismatch");
        Object seq = raw.get("seq"); if (!(seq instanceof Long) || ((Long) seq).longValue() < 1 || ((Long) seq).longValue() > 9007199254740991L) throw new ProtocolException("bad sequence");
        String type = string(raw, "type"); Object payloadObject = raw.get("payload"); if (!(payloadObject instanceof Map)) throw new ProtocolException("bad payload");
        Map<String, String> payload = new LinkedHashMap<String, String>();
        for (Map.Entry<String, Object> e : MiniJson.cast(payloadObject).entrySet()) { if (!(e.getValue() instanceof String)) throw new ProtocolException("payload value must be string"); payload.put(e.getKey(), (String) e.getValue()); }
        return new ProtocolMessage(((Long) seq).longValue(), type, payload);
    }
    public String json(String peerChallenge) { Map<String, Object> out = new LinkedHashMap<String, Object>(); out.put("challenge", peerChallenge); out.put("seq", Long.valueOf(sequence)); out.put("type", type); out.put("payload", new LinkedHashMap<String, String>(payload)); return MiniJson.stringify(out); }
    public static void requireVersion(Map<String, Object> raw) throws ProtocolException { Object v = raw.get("v"); if (v != null && (!(v instanceof Long) || ((Long) v).longValue() != 1)) throw new ProtocolException("unsupported version"); }
    public static String string(Map<String, Object> raw, String key) throws ProtocolException { Object value = raw.get(key); if (!(value instanceof String)) throw new ProtocolException("missing " + key); return (String) value; }
    private void validate() throws ProtocolException {
        if (payload.size() > 32) throw new ProtocolException("too many payload fields");
        for (Map.Entry<String, String> e : payload.entrySet()) { if (utf8(e.getKey()) > 64 || utf8(e.getValue()) > 4096) throw new ProtocolException("payload field too large"); }
        if (!knownType) return;
        if ("capabilities".equals(type)) { require("endpoint", "features"); String endpoint = payload.get("endpoint"); if (!("glass".equals(endpoint) || "ios".equals(endpoint) || "simulator".equals(endpoint) || "qt".equals(endpoint))) throw new ProtocolException("bad endpoint"); }
        else if ("card".equals(type)) { require("title", "body", "source"); oneOf("source", "companion", "appIntent", "speech"); }
        else if ("navigation".equals(type)) { require("instruction", "distance", "destination", "step", "total", "source"); oneOf("source", "mapkit", "demo"); }
        else if ("navigation.stop".equals(type)) exact();
        else if ("input".equals(type)) { require("gesture"); oneOf("gesture", "tap", "doubleTap", "swipeLeft", "swipeRight", "swipeDown", "camera", "cameraLongPress"); }
        else if ("phone.action".equals(type)) { require("action"); if (!PhoneActions.valid(payload.get("action"))) throw new ProtocolException("unknown phone action"); }
        else if ("ping".equals(type) || "pong".equals(type)) optional("id");
        else if ("error".equals(type)) require("code", "message");
        else if (MediaTransfer.knownType(type)) MediaTransfer.validate(type, payload);
    }
    public static boolean isKnownType(String value) { return "capabilities".equals(value) || "card".equals(value) || "navigation".equals(value) || "navigation.stop".equals(value) || "input".equals(value) || "phone.action".equals(value) || "ping".equals(value) || "pong".equals(value) || "error".equals(value) || MediaTransfer.knownType(value); }
    private void require(String... keys) throws ProtocolException { if (payload.size() != keys.length) throw new ProtocolException("wrong payload fields"); for (String key : keys) if (!payload.containsKey(key)) throw new ProtocolException("missing payload field"); }
    private void exact() throws ProtocolException { if (!payload.isEmpty()) throw new ProtocolException("wrong payload fields"); }
    private void optional(String key) throws ProtocolException { if (payload.size() > 1 || (payload.size() == 1 && !payload.containsKey(key))) throw new ProtocolException("wrong payload fields"); }
    private void oneOf(String key, String... options) throws ProtocolException { String value = payload.get(key); for (String option : options) if (option.equals(value)) return; throw new ProtocolException("bad " + key); }
    private static int utf8(String value) { return value.getBytes(Charset.forName("UTF-8")).length; }
}
