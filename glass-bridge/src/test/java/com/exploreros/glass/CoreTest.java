package com.exploreros.glass;

import com.exploreros.glass.ancs.AncsActionGate;
import com.exploreros.glass.ancs.AncsNotifications;
import com.exploreros.glass.ams.AmsState;
import com.exploreros.glass.ancs.AncsAttributeParser;
import com.exploreros.glass.ble.GattOperationQueue;
import com.exploreros.glass.core.Base64Codec;
import com.exploreros.glass.core.Heartbeat;
import com.exploreros.glass.core.PhoneActions;
import com.exploreros.glass.integration.IntegrationPolicy;
import com.exploreros.glass.core.CryptoBox;
import com.exploreros.glass.core.Hex;
import com.exploreros.glass.core.LineAccumulator;
import com.exploreros.glass.core.LinkSession;
import com.exploreros.glass.core.MiniJson;
import com.exploreros.glass.core.ProtocolException;
import com.exploreros.glass.core.ProtocolMessage;
import com.exploreros.glass.ui.GestureDecoder;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.nio.charset.Charset;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Dependency-free pure JVM test runner. */
public final class CoreTest {
    public static void main(String[] args) throws Exception { base64(); framing(); cryptoFixture(args[0]); session(); schema(); gattDeadline(); gattSetupBarrier(); ancs(); ancsLifecycle(); ams(); integration(); phoneAndHeartbeat(); gestures(); System.out.println("CoreTest: PASS"); }
    private static void base64() throws Exception { equal("AQID", Base64Codec.encode(new byte[] {1,2,3})); equal("AQI=", Base64Codec.encode(new byte[] {1,2})); expectBad(new Throwing() { public void run() throws Exception { Base64Codec.decode("AA=A"); } }); }
    private static void framing() throws Exception { LineAccumulator f = new LineAccumulator(); List<String> a = f.accept("one\ntw".getBytes("UTF-8"), 0, 6); equal(1, a.size()); equal("one", a.get(0)); a = f.accept("o\nthree\n".getBytes("UTF-8"), 0, 8); equal("two", a.get(0)); equal("three", a.get(1)); expectBad(new Throwing() { public void run() throws Exception { new LineAccumulator().accept(new byte[] {(byte)0xc3, 10}, 0, 2); } }); }
    private static void cryptoFixture(String path) throws Exception { Map<String, Object> fixture = MiniJson.object(read(new File(path))); byte[] key = Hex.decodeExact((String) fixture.get("key_hex"), 32); Map<String, Object> packet = MiniJson.cast(fixture.get("encrypted_packet")); byte[] nonce = Base64Codec.decode((String) fixture.get("nonce_b64")); byte[] box = Base64Codec.decode((String) packet.get("box")); CryptoBox crypto = new CryptoBox(key); String expected = MiniJson.stringify(fixture.get("plaintext")); equal(expected, new String(crypto.open(nonce, box), Charset.forName("UTF-8"))); equal((String) packet.get("box"), Base64Codec.encode(crypto.seal(nonce, expected.getBytes("UTF-8")).box)); }
    private static void session() throws Exception { byte[] key = new byte[32]; Arrays.fill(key, (byte) 7); LinkSession a = new LinkSession(key), b = new LinkSession(key); String aHello = a.initialHello(), bHello = b.initialHello(); a.accept(bHello); b.accept(aHello); Map<String, String> p = new LinkedHashMap<String, String>(); p.put("endpoint", "glass"); p.put("features", "test"); final String frame = a.encrypt("capabilities", p); ProtocolMessage m = b.accept(frame); equal("capabilities", m.type); expectBad(new Throwing() { public void run() throws Exception { b.accept(frame); } }); }
    private static void schema() throws Exception { final String challenge = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; ProtocolMessage future = ProtocolMessage.parse("{\"challenge\":\"" + challenge + "\",\"seq\":1,\"type\":\"future\",\"payload\":{}}", challenge); if (future.knownType) throw new AssertionError(); expectBad(new Throwing() { public void run() throws Exception { ProtocolMessage.parse("{\"challenge\":\"" + challenge + "\",\"seq\":9007199254740992,\"type\":\"ping\",\"payload\":{}}", challenge); } }); expectBad(new Throwing() { public void run() throws Exception { ProtocolMessage.parse("{\"challenge\":\"" + challenge + "\",\"seq\":1,\"type\":\"input\",\"payload\":{\"gesture\":\"bad\"}}", challenge); } }); }
    private static void gattDeadline() { final int[] failures = {0}, starts = {0}; FakeDeadline deadline = new FakeDeadline(); GattOperationQueue queue = new GattOperationQueue(new GattOperationQueue.Failure() { @Override public void onFailure() { failures[0]++; } }, deadline); queue.enqueue(new GattOperationQueue.Starter() { @Override public boolean start() { starts[0]++; return true; } }); equal(1, starts[0]); deadline.fire(); equal(1, failures[0]); queue.complete(true); equal(1, failures[0]); }
    private static void gattSetupBarrier() {
        final int[] ready = {0}; FakeDeadline timer = new FakeDeadline();
        GattOperationQueue queue = new GattOperationQueue(new GattOperationQueue.Failure() { public void onFailure() { } }, timer);
        queue.enqueue(new GattOperationQueue.Starter() { public boolean start() { return true; } });
        queue.afterPending(new Runnable() { public void run() { ready[0]++; } }); equal(0, ready[0]); queue.complete(true); equal(1, ready[0]);
        queue.enqueue(new GattOperationQueue.Starter() { public boolean start() { return true; } });
        queue.afterPending(new Runnable() { public void run() { ready[0]++; } }); queue.complete(false); equal(1, ready[0]);
    }
    private static void ancs() throws Exception { AncsAttributeParser parser = new AncsAttributeParser(new byte[] {1,3}); parser.reset(0x11223344L); byte[] all = new byte[] {0,0x44,0x33,0x22,0x11,1,2,0,'H','i',3,3,0,'B','y','e'}; if (parser.accept(Arrays.copyOfRange(all, 0, 9)) != null) throw new AssertionError(); AncsAttributeParser.Result r = parser.accept(Arrays.copyOfRange(all, 9, all.length)); equal("Hi", r.attributes.get(Integer.valueOf(1))); equal("Bye", r.attributes.get(Integer.valueOf(3))); expectBad(new Throwing() { public void run() throws Exception { AncsActionGate.command(7, 0, AncsActionGate.POSITIVE); } }); equal(6, AncsActionGate.command(7, AncsActionGate.FLAG_POSITIVE_ACTION, AncsActionGate.POSITIVE).length); }
    private static void ams() throws Exception {
        final AmsState state = new AmsState();
        expectBad(new Throwing() { public void run() throws Exception { state.command(AmsState.PLAY); } });
        state.commands(new byte[] {0, 1, 3, 4}); equal(true, state.supports(AmsState.PLAY)); equal(false, state.supports(AmsState.TOGGLE)); equal(4, (int)state.command(AmsState.PREVIOUS)[0]);
        state.commands(new byte[] {2}); equal(false, state.supports(AmsState.PLAY)); equal(true, state.supports(AmsState.TOGGLE));
        equal("9B3C81D8-57B1-4A8A-B8DF-0E56F7CA51C2", AmsState.REMOTE_UUID);
        equal(true, Arrays.equals(new byte[] {0, 0, 1}, AmsState.subscriptions()[0])); equal(true, Arrays.equals(new byte[] {2, 0, 2}, AmsState.subscriptions()[1]));
        state.update(new byte[] {2, 2, 0, 'S', 'o', 'n', 'g'}); state.update(new byte[] {2, 0, 1, 'A'}); state.update(new byte[] {0, 0, 0, 'P'});
        equal("Song", state.snapshot().title); equal("A…", state.snapshot().artist); equal("P", state.snapshot().player);
        state.update(new byte[] {0, 3, 0, 0, 1, 3}); equal(false, state.supports(AmsState.PLAY));
        expectBad(new Throwing() { public void run() throws Exception { state.update(new byte[] {2, 2, 0, (byte)0xff}); } });
        state.clear(); equal("", state.snapshot().title); equal(false, state.supports(AmsState.TOGGLE));
    }
    private static void ancsLifecycle() throws Exception {
        final java.util.ArrayList<Long> requests = new java.util.ArrayList<Long>(), removed = new java.util.ArrayList<Long>();
        final java.util.ArrayList<AncsNotifications.Notification> delivered = new java.util.ArrayList<AncsNotifications.Notification>();
        final AncsNotifications model = new AncsNotifications(new AncsNotifications.Events() {
            public void request(long uid, byte[] bytes) { requests.add(uid); equal(0, (int)bytes[0]); }
            public void notification(AncsNotifications.Notification n) { delivered.add(n); }
            public void removed(long uid) { removed.add(uid); }
            public void invalidated(long uid) { }
        });
        model.source(source(0, 24, 7)); model.source(source(0, 0, 8)); equal(1, requests.size());
        byte[] reply = attributes(7); model.data(Arrays.copyOfRange(reply, 0, 9)); equal(0, delivered.size()); model.data(Arrays.copyOfRange(reply, 9, reply.length));
        equal(2, requests.size()); equal(true, delivered.get(0).newlyAdded); equal("Hi", delivered.get(0).title); equal("Yes", delivered.get(0).positiveLabel); equal(true, delivered.get(0).positive()); equal(true, delivered.get(0).negative());
        equal(true, Arrays.equals(new byte[] {2,7,0,0,0,1}, model.action(7, 1)));
        model.source(source(2, 0, 8)); model.data(attributes(8)); equal(1, delivered.size());
        model.source(source(1, 0, 7)); expectBad(new Throwing() { public void run() throws Exception { model.action(7, 0); } });
        model.source(source(1, 8, 7)); model.data(attributes(7)); equal(1, delivered.size()); model.data(attributes(7)); equal(2, delivered.size());
        equal(false, delivered.get(1).newlyAdded); equal(true, delivered.get(1).positive()); equal(false, delivered.get(1).negative());
        model.source(source(2, 0, 7)); expectBad(new Throwing() { public void run() throws Exception { model.action(7, 0); } });
        model.clear(); equal(-1L, model.activeUid());
        model.source(source(0, 0, 20)); model.source(source(0, 0, 21)); model.source(source(2, 0, 20)); model.rejected(20); equal(21L, model.activeUid()); model.data(attributes(21));
        model.clear(); int beforeOverflow = removed.size(); for (int uid = 0; uid < 100; uid++) model.source(source(0, 0, uid));
        equal(true, removed.size() >= beforeOverflow + 36); model.clear();
        equal(true, Arrays.equals(new byte[] {0,7,0,0,0,1,(byte)128,0,3,0,4,6,7}, AncsNotifications.attributesCommand(7)));
    }
    private static byte[] source(int event, int flags, int uid) { return new byte[] {(byte)event,(byte)flags,0,0,(byte)uid,0,0,0}; }
    private static byte[] attributes(int uid) { return new byte[] {0,(byte)uid,0,0,0,1,2,0,'H','i',3,1,0,'B',6,3,0,'Y','e','s',7,2,0,'N','o'}; }
    private static void integration() {
        equal(false, IntegrationPolicy.backgroundAllowed(false, true)); equal(false, IntegrationPolicy.backgroundAllowed(true, false)); equal(true, IntegrationPolicy.backgroundAllowed(true, true));
        IntegrationPolicy policy = new IntegrationPolicy();
        equal(false, policy.present(false, true, false, false, true, "card", false, 0, 100));
        equal(false, policy.present(true, true, false, false, false, "card", false, 0, 100));
        equal(false, policy.present(true, true, true, false, true, "card", false, 0, 100));
        equal(false, policy.present(true, true, false, true, true, "card", false, 0, 100));
        equal(false, policy.present(true, true, false, false, true, "ancs", true, IntegrationPolicy.ANCS_PREEXISTING, 100));
        equal(false, policy.present(true, true, false, false, true, "ancs", true, IntegrationPolicy.ANCS_SILENT, 100));
        equal(false, policy.present(true, true, false, false, true, "ancs", false, 0, 100));
        equal(false, policy.present(true, true, false, false, true, "ping", false, 0, 100));
        equal(true, policy.present(true, true, false, false, true, "ancs", true, 0, 100));
        equal(false, policy.present(true, true, false, false, true, "card", false, 0, 101));
        policy.dismissed("navigation", 1000);
        equal(false, policy.present(true, true, false, false, true, "card", false, 0, 2000));
        equal(false, policy.present(true, true, false, false, true, "navigation", false, 0, 20000));
        policy.navigationStopped(); equal(true, policy.present(true, true, false, false, true, "navigation", false, 0, 20000));
        IntegrationPolicy.Reconnect retry = new IntegrationPolicy.Reconnect(); equal(-1L, retry.next(false, true, true)); equal(-1L, retry.next(true, false, true)); equal(-1L, retry.next(true, true, false));
        for (long delay : new long[] {1000,2000,5000,10000,30000,60000}) equal(delay, retry.next(true, true, true));
        equal(-1L, retry.next(true, true, true)); retry.reset(); equal(1000L, retry.next(true, true, true));
    }
    private static void phoneAndHeartbeat() throws Exception {
        com.exploreros.glass.hfp.VoicePolicy voice = new com.exploreros.glass.hfp.VoicePolicy();
        equal(false, voice.request(false, 0)); voice.trusted(true); equal(false, voice.request(false, 0));
        voice.connection(true); equal(false, voice.request(true, 0)); voice.call(true); equal(false, voice.request(false, 0));
        voice.call(false); equal(true, voice.request(false, 100)); equal(false, voice.audio(false)); equal(true, voice.owned());
        equal(false, voice.audio(true)); voice.sent(); equal(true, voice.audio(true)); equal(false, voice.audio(false)); equal(false, voice.owned()); equal(false, voice.cancel());
        equal(true, voice.request(false, 200)); voice.call(true); equal(false, voice.cancel()); equal(false, voice.audio(true));
        voice.call(false); equal(true, voice.request(false, 300)); voice.sent(); equal(false, voice.expired(30299)); equal(true, voice.expired(30300)); equal(true, voice.cancel()); equal(false, voice.cancel());
        equal(true, voice.request(false, 400)); voice.connection(false); equal(false, voice.cancel());
        voice.connection(true); equal(true, voice.request(false, 450)); equal(false, voice.cancel());
        equal(true, voice.request(false, 500)); voice.trusted(false); equal(false, voice.cancel());

        for (String action : new String[] {"focus.on","focus.off","silent.on","silent.off","notes.create","notes.browse"}) equal(action, new ProtocolMessage(1,"phone.action",PhoneActions.payload(action)).payload.get("action"));
        expectBad(new Throwing() { public void run() throws Exception { PhoneActions.payload("shell.run"); } });
        expectBad(new Throwing() { public void run() throws Exception { Map<String,String> removed = new LinkedHashMap<String,String>(); removed.put("action", "mail.open"); new ProtocolMessage(1,"phone.action",removed); } });
        Map<String,String> fields = new LinkedHashMap<String,String>(); fields.put("id", "beat-17"); equal(fields, Heartbeat.pong(new ProtocolMessage(1,"ping",fields)));
        equal(0, Heartbeat.pong(new ProtocolMessage(1,"ping",new LinkedHashMap<String,String>())).size());
        fields.clear(); fields.put("endpoint", "ios"); fields.put("features", "card,phone.actions"); equal(true, PhoneActions.advertised(new ProtocolMessage(1,"capabilities",fields)));
        fields.put("endpoint", "simulator"); equal(false, PhoneActions.advertised(new ProtocolMessage(1,"capabilities",fields)));
        fields.put("endpoint", "ios"); fields.put("features", "phone.actions.fake"); equal(false, PhoneActions.advertised(new ProtocolMessage(1,"capabilities",fields)));
    }
    private static void gestures() { GestureDecoder g = new GestureDecoder(); g.down(0, 0, 0); equal("tap", g.up(100, 1, 1)); g.down(200,0,0); equal("doubleTap", g.up(250,1,1)); g.down(1000,0,0); equal("swipeLeft", g.up(1100,-60,0)); g.down(1200,0,0); equal("swipeDown", g.up(1300,0,60)); }
    private static String read(File f) throws Exception { FileInputStream in = new FileInputStream(f); ByteArrayOutputStream out = new ByteArrayOutputStream(); byte[] b = new byte[4096]; for (int n; (n = in.read(b)) != -1;) out.write(b,0,n); in.close(); return new String(out.toByteArray(), "UTF-8"); }
    private static void equal(Object expected, Object actual) { if (expected == null ? actual != null : !expected.equals(actual)) throw new AssertionError("expected " + expected + ", got " + actual); }
    private static void expectBad(Throwing test) throws Exception { try { test.run(); throw new AssertionError("expected ProtocolException"); } catch (ProtocolException wanted) { } }
    private interface Throwing { void run() throws Exception; }
    private static final class FakeDeadline implements GattOperationQueue.Deadline { Runnable callback; @Override public void arm(Runnable callback, long milliseconds) { this.callback = callback; } @Override public void cancel() { callback = null; } void fire() { Runnable pending = callback; if (pending != null) pending.run(); } }
}
