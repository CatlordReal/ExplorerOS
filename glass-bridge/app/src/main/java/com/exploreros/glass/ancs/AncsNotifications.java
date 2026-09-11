package com.exploreros.glass.ancs;

import com.exploreros.glass.core.ProtocolException;
import java.util.LinkedHashMap;
import java.util.Map;

/** Bounded session model. Serializes fragmented replies; stale/removed UIDs cannot act. */
public final class AncsNotifications {
    public interface Events { void request(long uid, byte[] command); void notification(Notification value); void removed(long uid); void invalidated(long uid); }
    public static final class Notification {
        public final long uid; public final int flags; public final boolean newlyAdded; public final String title, body, positiveLabel, negativeLabel;
        Notification(long uid, int flags, boolean newlyAdded, Map<Integer, String> attributes) { this.uid = uid; this.flags = flags; this.newlyAdded = newlyAdded; title = attributes.get(1); body = attributes.get(3); positiveLabel = attributes.get(6); negativeLabel = attributes.get(7); }
        public boolean positive() { return (flags & AncsActionGate.FLAG_POSITIVE_ACTION) != 0; }
        public boolean negative() { return (flags & AncsActionGate.FLAG_NEGATIVE_ACTION) != 0; }
    }
    private final Events events;
    private final LinkedHashMap<Long, Integer> live = new LinkedHashMap<Long, Integer>(), pending = new LinkedHashMap<Long, Integer>();
    private final LinkedHashMap<Long, Boolean> added = new LinkedHashMap<Long, Boolean>();
    private boolean activeAdded;
    private final AncsAttributeParser parser = new AncsAttributeParser(new byte[] {1, 3, 6, 7});
    private long active = -1; private int activeFlags;
    public AncsNotifications(Events events) { this.events = events; }
    public synchronized void source(byte[] value) throws ProtocolException {
        if (value == null || value.length != 8 || (value[0] & 255) > 2) throw new ProtocolException("invalid ANCS source");
        long uid = ((long)value[4]&255) | (((long)value[5]&255)<<8) | (((long)value[6]&255)<<16) | (((long)value[7]&255)<<24);
        if (value[0] == 2) { live.remove(uid); pending.remove(uid); added.remove(uid); events.removed(uid); return; }
        if (!live.containsKey(uid) && live.size() >= 64) { Long oldest = live.keySet().iterator().next(); live.remove(oldest); pending.remove(oldest); added.remove(oldest); events.removed(oldest); }
        added.put(uid, value[0] == 0 && !live.containsKey(uid));
        live.put(uid, value[1] & 255); pending.put(uid, value[1] & 255);
        // A modification may withdraw an action before its replacement text arrives.
        events.invalidated(uid); next();
    }
    public synchronized void data(byte[] value) throws ProtocolException {
        if (active < 0) throw new ProtocolException("unexpected ANCS data");
        AncsAttributeParser.Result result = parser.accept(value); if (result == null) return;
        if (live.containsKey(active) && !pending.containsKey(active)) events.notification(new Notification(active, activeFlags, activeAdded, result.attributes));
        active = -1; next();
    }
    private void next() {
        if (active >= 0 || pending.isEmpty()) return;
        Map.Entry<Long, Integer> item = pending.entrySet().iterator().next(); active = item.getKey(); activeFlags = item.getValue(); activeAdded = Boolean.TRUE.equals(added.remove(active)); pending.remove(active); parser.reset(active);
        events.request(active, attributesCommand(active));
    }
    public static byte[] attributesCommand(long uid) { return new byte[] {0, (byte)uid, (byte)(uid>>>8), (byte)(uid>>>16), (byte)(uid>>>24), 1, (byte)128, 0, 3, 0, 4, 6, 7}; }
    public synchronized byte[] action(long uid, int action) throws ProtocolException { Integer flags = live.get(uid); if (flags == null || pending.containsKey(uid) || active == uid) throw new ProtocolException("ANCS action stale"); return AncsActionGate.command(uid, flags, action); }
    /** A rejected Control Point write generates no Data Source reply, so advancing is safe. */
    public synchronized void rejected(long uid) { if (active == uid) { active = -1; parser.reset(-1); next(); } }
    public synchronized long activeUid() { return active; }
    public synchronized void clear() { live.clear(); pending.clear(); added.clear(); activeAdded = false; active = -1; parser.reset(-1); }
}
