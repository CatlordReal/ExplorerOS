package com.exploreros.glass;

import com.exploreros.glass.core.LineAccumulator;
import com.exploreros.glass.core.Heartbeat;
import com.exploreros.glass.core.PhoneActions;
import com.exploreros.glass.core.LinkSession;
import com.exploreros.glass.core.ProtocolException;
import com.exploreros.glass.core.ProtocolMessage;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.Charset;
import java.util.LinkedHashMap;
import java.util.Map;

/** One bounded, authenticated TCP client on port 8765. */
final class TcpBridge {
    interface Callbacks { void status(String value); void received(ProtocolMessage message); void closed(); }
    private volatile String bluetoothFeatures = "";
    private final int port;
    private final byte[] key; private final Callbacks callbacks; private volatile boolean running; private volatile ServerSocket server; private volatile Socket active; private volatile Connection activeConnection;
    TcpBridge(byte[] key, Callbacks callbacks) { this(key, callbacks, 8765); }
    TcpBridge(byte[] key, Callbacks callbacks, int port) { this.key = key.clone(); this.callbacks = callbacks; this.port = port; }
    int boundPort() { ServerSocket listener = server; return listener == null || listener.isClosed() ? -1 : listener.getLocalPort(); }
    boolean phoneActionsAvailable() { Connection connection = activeConnection; return connection != null && connection.phoneActionsAvailable(); }
    boolean sendPhoneAction(String action) { Connection connection = activeConnection; return connection != null && connection.sendPhoneAction(action); }
    void start() { if (running) return; running = true; new Thread(new Runnable() { @Override public void run() { acceptLoop(); } }, "explorer-tcp-listener").start(); }
    void stop() { running = false; close(server); close(active); activeConnection = null; }
    void setBluetoothCapabilities(boolean ancs, boolean ams) { final String updated = (ancs ? ",ancs.available" : "") + (ams ? ",ams.available" : ""); if (updated.equals(bluetoothFeatures)) return; bluetoothFeatures = updated; final Connection connection = activeConnection; if (connection != null) new Thread(new Runnable() { @Override public void run() { connection.updateCapabilities(); } }, "explorer-capabilities").start(); }
    void sendInput(String gesture) { Connection connection = activeConnection; if (connection != null) connection.sendInput(gesture); }
    private void acceptLoop() {
        try { server = new ServerSocket(port); callbacks.status("Wi-Fi listening: " + server.getLocalPort()); while (running) { Socket socket = server.accept(); socket.setTcpNoDelay(true); socket.setSoTimeout(15000); if (activeConnection != null) { close(socket); continue; } active = socket; Connection connection = new Connection(socket); activeConnection = connection; new Thread(connection, "explorer-tcp-client").start(); } }
        catch (Exception ignored) { if (running) callbacks.status("Wi-Fi unavailable"); }
        finally { close(server); server = null; }
    }
    private final class Connection implements Runnable {
        private final Socket socket; private volatile boolean open = true; private LinkSession session; private volatile boolean peerPhoneActions;
        Connection(Socket socket) { this.socket = socket; }
        @Override public void run() {
            try { session = new LinkSession(key); write(session.initialHello()); InputStream in = socket.getInputStream(); byte[] buffer = new byte[2048]; LineAccumulator lines = new LineAccumulator();
                for (int n; open && (n = in.read(buffer)) != -1;) for (String line : lines.accept(buffer, 0, n)) { ProtocolMessage message = session.accept(line); if (session.peerHelloReceived()) writeCapabilitiesIfNeeded(); if (message != null) { if (!message.knownType) sendUnknownType(message.type); else if ("ping".equals(message.type)) sendPong(message); else { if ("capabilities".equals(message.type)) peerPhoneActions = PhoneActions.advertised(message); callbacks.received(message); } if (session.authenticated()) { socket.setSoTimeout(60000); callbacks.status("Wi-Fi authenticated"); } } }
            } catch (Exception ignored) { }
            finally { open = false; peerPhoneActions = false; if (activeConnection == this) { activeConnection = null; callbacks.closed(); callbacks.status("Wi-Fi disconnected"); } close(socket); if (session != null) session.close(); }
        }
        private boolean capabilitiesSent;
        private synchronized void writeCapabilitiesIfNeeded() throws ProtocolException { if (!capabilitiesSent) { Map<String, String> cap = new LinkedHashMap<String, String>(); cap.put("endpoint", "glass"); cap.put("features", "tcp,card,navigation,input,ble-central" + bluetoothFeatures); write(session.encrypt("capabilities", cap)); capabilitiesSent = true; } }
        synchronized void updateCapabilities() { if (open && session != null && session.peerHelloReceived()) try { capabilitiesSent = false; writeCapabilitiesIfNeeded(); } catch (ProtocolException ignored) { close(socket); } }
        synchronized void sendInput(String gesture) { if (open && session != null && session.peerHelloReceived()) try { Map<String, String> payload = new LinkedHashMap<String, String>(); payload.put("gesture", gesture); write(session.encrypt("input", payload)); } catch (ProtocolException ignored) { close(socket); } }
        synchronized boolean phoneActionsAvailable() { return open && peerPhoneActions && session != null && session.authenticated(); }
        synchronized boolean sendPhoneAction(String action) { if (!phoneActionsAvailable()) return false; try { write(session.encrypt("phone.action", PhoneActions.payload(action))); return true; } catch (ProtocolException ignored) { close(socket); return false; } }
        private synchronized void sendPong(ProtocolMessage message) throws ProtocolException { write(session.encrypt("pong", Heartbeat.pong(message))); }
        private synchronized void sendUnknownType(String type) throws ProtocolException { Map<String, String> payload = new LinkedHashMap<String, String>(); payload.put("code", "unknown_type"); payload.put("message", "Unsupported message type: " + (type.length() > 128 ? type.substring(0, 128) : type)); write(session.encrypt("error", payload)); }
        private synchronized void write(String line) throws ProtocolException { try { OutputStream out = socket.getOutputStream(); out.write((line + "\n").getBytes(Charset.forName("UTF-8"))); out.flush(); } catch (Exception e) { throw new ProtocolException("transport write failed", e); } }
    }
    private static void close(java.io.Closeable value) { if (value != null) try { value.close(); } catch (Exception ignored) { } }
}
