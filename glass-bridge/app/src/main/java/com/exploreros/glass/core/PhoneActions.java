package com.exploreros.glass.core;

import java.util.LinkedHashMap;
import java.util.Map;

/** Fixed requests only; the iPhone owns confirmation and execution. */
public final class PhoneActions {
    private PhoneActions() { }
    public static boolean valid(String action) { return "focus.on".equals(action) || "focus.off".equals(action) || "silent.on".equals(action) || "silent.off".equals(action) || "notes.create".equals(action) || "notes.browse".equals(action); }
    public static Map<String, String> payload(String action) throws ProtocolException { if (!valid(action)) throw new ProtocolException("unknown phone action"); Map<String, String> value = new LinkedHashMap<String, String>(); value.put("action", action); return value; }
    public static boolean advertised(ProtocolMessage message) { if (!"capabilities".equals(message.type) || !"ios".equals(message.payload.get("endpoint"))) return false; String features = message.payload.get("features"); if (features == null) return false; for (String feature : features.split(",")) if ("phone.actions".equals(feature.trim())) return true; return false; }
}
