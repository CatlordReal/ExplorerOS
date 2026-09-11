package com.exploreros.glass.core;

import java.nio.charset.Charset;
import java.security.SecureRandom;
import java.util.LinkedHashMap;
import java.util.Map;

/** Per TCP socket or BLE subscription. Any protocol error permanently closes this object. */
public final class LinkSession {
    private final CryptoBox crypto; private final String localChallenge; private String peerChallenge; private long sentSequence, receivedSequence; private boolean localHelloSent, peerHelloReceived, authenticated, closed;
    public LinkSession(byte[] key) throws ProtocolException { this(key, new SecureRandom()); }
    LinkSession(byte[] key, SecureRandom random) throws ProtocolException { byte[] challenge = new byte[32]; random.nextBytes(challenge); localChallenge = Hex.encode(challenge); crypto = new CryptoBox(key, random); }
    public String initialHello() throws ProtocolException { if (closed || localHelloSent) throw fail("duplicate hello"); localHelloSent = true; Map<String, Object> hello = new LinkedHashMap<String, Object>(); hello.put("v", Long.valueOf(1)); hello.put("hello", localChallenge); return MiniJson.stringify(hello); }
    public ProtocolMessage accept(String line) throws ProtocolException {
        if (closed) throw new ProtocolException("session closed");
        try { Map<String, Object> outer = MiniJson.object(line); ProtocolMessage.requireVersion(outer); if (outer.containsKey("hello")) { receiveHello(outer); return null; }
            if (!peerHelloReceived || outer.size() != 3 || !outer.containsKey("v") || !(outer.get("v") instanceof Long) || ((Long) outer.get("v")).longValue() != 1) throw fail("malformed encrypted frame"); String nonce = ProtocolMessage.string(outer, "nonce"), box = ProtocolMessage.string(outer, "box");
            String plain = new String(crypto.open(Base64Codec.decode(nonce), Base64Codec.decode(box)), Charset.forName("UTF-8")); ProtocolMessage message = ProtocolMessage.parse(plain, localChallenge);
            if (message.sequence <= receivedSequence) throw fail("replayed sequence"); receivedSequence = message.sequence; authenticated = true; return message;
        } catch (ProtocolException e) { closed = true; throw e; }
    }
    private void receiveHello(Map<String, Object> outer) throws ProtocolException { if (peerHelloReceived || outer.size() != 2) throw fail("duplicate or malformed hello"); Object v = outer.get("v"); if (!(v instanceof Long) || ((Long) v).longValue() != 1) throw fail("unsupported version"); peerChallenge = Hex.encode(Hex.decodeExact(ProtocolMessage.string(outer, "hello"), 32)); peerHelloReceived = true; }
    public String encrypt(String type, Map<String, String> payload) throws ProtocolException { if (closed || !peerHelloReceived) throw fail("cannot encrypt before hello"); ProtocolMessage message = new ProtocolMessage(++sentSequence, type, payload); CryptoBox.Packet packet = crypto.seal(message.json(peerChallenge).getBytes(Charset.forName("UTF-8"))); Map<String, Object> outer = new LinkedHashMap<String, Object>(); outer.put("v", Long.valueOf(1)); outer.put("nonce", Base64Codec.encode(packet.nonce)); outer.put("box", Base64Codec.encode(packet.box)); return MiniJson.stringify(outer); }
    public boolean peerHelloReceived() { return peerHelloReceived; } public boolean authenticated() { return authenticated; } public boolean closed() { return closed; }
    public void close() { closed = true; peerChallenge = null; sentSequence = receivedSequence = 0; }
    private ProtocolException fail(String message) { closed = true; return new ProtocolException(message); }
}
