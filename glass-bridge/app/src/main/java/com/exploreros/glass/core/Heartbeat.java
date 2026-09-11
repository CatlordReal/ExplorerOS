package com.exploreros.glass.core;

import java.util.LinkedHashMap;
import java.util.Map;

/** Called only after LinkSession authenticated and validated the received message. */
public final class Heartbeat {
    private Heartbeat() { }
    public static Map<String, String> pong(ProtocolMessage message) throws ProtocolException { if (!"ping".equals(message.type)) throw new ProtocolException("not a ping"); Map<String, String> payload = new LinkedHashMap<String, String>(); if (message.payload.containsKey("id")) payload.put("id", message.payload.get("id")); return payload; }
}
