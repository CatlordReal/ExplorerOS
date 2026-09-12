package com.exploreros.glass;

import com.exploreros.glass.core.LinkSession;
import com.exploreros.glass.core.ProtocolMessage;
import com.exploreros.glass.core.MediaTransfer;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.Socket;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Socket-level TCP regression coverage. No Android runtime or fixed port required. */
public final class TransportTest {
    private static final byte[] KEY = key();

    public static void main(String[] args) throws Exception {
        final Events events = new Events();
        TcpBridge bridge = new TcpBridge(KEY, events, 0);
        bridge.setMediaSyncEnabled(true);
        bridge.start();
        int port = awaitPort(bridge);
        Socket untrusted = null;
        Socket first = null;
        Socket second = null;
        Socket reconnect = null;
        try {
            untrusted = new Socket("127.0.0.1", port);
            untrusted.setSoTimeout(1500);
            BufferedReader attackerReader = reader(untrusted);
            require(attackerReader.readLine().contains("\"hello\""), "server hello");
            require(!bridge.sendPhoneAction("notes.create"), "unauthenticated phone action gate");
            require(!bridge.sendMedia(new ProtocolMessage(1, "media.cancel", MediaTransfer.cancel("00112233445566778899aabbccddeeff", "disabled"))), "unauthenticated media gate");
            write(untrusted, "{\"v\":1,\"nonce\":\"AA==\",\"box\":\"AA==\"}");
            waitClosed(untrusted);
            equal(0, events.messages());

            first = new Socket("127.0.0.1", port);
            Client ios = authenticate(first, true, true);
            require(events.await("capabilities", 1500), "authenticated capabilities callback");
            require(awaitPhoneActions(bridge), "advertised phone actions");
            require(awaitMediaReceive(bridge), "advertised media receive");
            require(bridge.sendPhoneAction("notes.create"), "authenticated phone action");
            ProtocolMessage phoneAction = read(ios);
            equal("phone.action", phoneAction.type);
            equal("notes.create", phoneAction.payload.get("action"));
            require(bridge.sendMedia(new ProtocolMessage(1, "media.cancel", MediaTransfer.cancel("00112233445566778899aabbccddeeff", "disabled"))), "authenticated TCP media gate");
            ProtocolMessage cancel = read(ios);
            equal("media.cancel", cancel.type);
            send(ios, "ping", map("id", "keepalive-7"));
            ProtocolMessage pong = read(ios);
            equal("pong", pong.type);
            equal("keepalive-7", pong.payload.get("id"));
            require(!events.seen("ping"), "ping must not dispatch as action");

            second = new Socket("127.0.0.1", port);
            waitClosed(second);
            close(first);
            require(awaitNoPhoneActions(bridge), "disconnect clears phone action capability");
            reconnect = new Socket("127.0.0.1", port);
            authenticate(reconnect, false, false);
            require(events.awaitCount("capabilities", 2, 1500), "reconnect callback");
        } finally {
            close(reconnect);
            close(second);
            close(first);
            close(untrusted);
            bridge.stop();
        }
        System.out.println("TransportTest: PASS");
    }

    private static Client authenticate(Socket socket, boolean phoneActions, boolean mediaReceive) throws Exception {
        socket.setSoTimeout(1500);
        Client client = new Client(socket, new LinkSession(KEY));
        client.session.accept(client.in.readLine());
        write(socket, client.session.initialHello());
        ProtocolMessage capabilities = read(client);
        equal("capabilities", capabilities.type);
        equal("glass", capabilities.payload.get("endpoint"));
        require(capabilities.payload.get("features").contains("media.send.tcp.v1"), "Glass media capability follows opt-in");
        send(client, "capabilities", capabilities(phoneActions, mediaReceive));
        return client;
    }

    private static ProtocolMessage read(Client client) throws Exception {
        String line = client.in.readLine();
        require(line != null, "encrypted response");
        ProtocolMessage message = client.session.accept(line);
        require(message != null, "encrypted application message");
        return message;
    }

    private static void send(Client client, String type, Map<String, String> payload) throws Exception { write(client.socket, client.session.encrypt(type, payload)); }
    private static Map<String, String> capabilities(boolean phoneActions, boolean mediaReceive) { Map<String, String> value = map("endpoint", "ios"); value.put("features", "tcp" + (phoneActions ? ",phone.actions" : "") + (mediaReceive ? ",media.receive.tcp.v1" : "")); return value; }
    private static Map<String, String> map(String a, String b) { Map<String, String> value = new LinkedHashMap<String, String>(); value.put(a, b); return value; }
    private static BufferedReader reader(Socket socket) throws Exception { return new BufferedReader(new InputStreamReader(socket.getInputStream(), Charset.forName("UTF-8"))); }
    private static void write(Socket socket, String line) throws Exception { BufferedWriter out = new BufferedWriter(new OutputStreamWriter(socket.getOutputStream(), Charset.forName("UTF-8"))); out.write(line); out.write('\n'); out.flush(); }
    private static int awaitPort(TcpBridge bridge) throws Exception { for (int i = 0; i < 100; i++) { int port = bridge.boundPort(); if (port > 0) return port; Thread.sleep(10); } throw new AssertionError("listener did not bind"); }
    private static boolean awaitPhoneActions(TcpBridge bridge) throws Exception { for (int i = 0; i < 100; i++) { if (bridge.phoneActionsAvailable()) return true; Thread.sleep(10); } return false; }
    private static boolean awaitMediaReceive(TcpBridge bridge) throws Exception { for (int i = 0; i < 100; i++) { if (bridge.mediaReceiveAvailable()) return true; Thread.sleep(10); } return false; }
    private static boolean awaitNoPhoneActions(TcpBridge bridge) throws Exception { for (int i = 0; i < 100; i++) { if (!bridge.phoneActionsAvailable()) return true; Thread.sleep(10); } return false; }
    private static void waitClosed(Socket socket) throws Exception { try { socket.setSoTimeout(1500); int value = socket.getInputStream().read(); if (value != -1) throw new AssertionError("connection remained open"); } catch (java.net.SocketException expected) { } }
    private static void close(Socket socket) { if (socket != null) try { socket.close(); } catch (Exception ignored) { } }
    private static void equal(Object expected, Object actual) { if (expected == null ? actual != null : !expected.equals(actual)) throw new AssertionError("expected " + expected + ", got " + actual); }
    private static void require(boolean condition, String label) { if (!condition) throw new AssertionError(label); }
    private static byte[] key() { byte[] key = new byte[32]; Arrays.fill(key, (byte) 0x42); return key; }

    private static final class Client { final Socket socket; final BufferedReader in; final LinkSession session; Client(Socket socket, LinkSession session) throws Exception { this.socket = socket; this.in = reader(socket); this.session = session; } }
    private static final class Events implements TcpBridge.Callbacks {
        private final List<String> types = new ArrayList<String>();
        public void status(String value) { }
        public synchronized void received(ProtocolMessage message) { types.add(message.type); notifyAll(); }
        public void closed() { }
        synchronized int messages() { return types.size(); }
        synchronized boolean seen(String type) { return types.contains(type); }
        synchronized boolean await(String type, long milliseconds) throws InterruptedException { long until = System.currentTimeMillis() + milliseconds; while (!types.contains(type) && System.currentTimeMillis() < until) wait(Math.max(1, until - System.currentTimeMillis())); return types.contains(type); }
        synchronized boolean awaitCount(String type, int count, long milliseconds) throws InterruptedException { long until = System.currentTimeMillis() + milliseconds; while (count(type) < count && System.currentTimeMillis() < until) wait(Math.max(1, until - System.currentTimeMillis())); return count(type) >= count; }
        private int count(String type) { int total = 0; for (String candidate : types) if (type.equals(candidate)) total++; return total; }
    }
}
