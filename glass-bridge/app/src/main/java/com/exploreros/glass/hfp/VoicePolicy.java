package com.exploreros.glass.hfp;

/** Request ownership is distinct from observed audio routing and Siri recognition state. */
public final class VoicePolicy {
    public static final long LIMIT_MS = 30000;
    private boolean trusted, connected, call, owned, sawAudio, dispatched;
    private long deadline;
    public void trusted(boolean value) { trusted = value; if (!value) clear(); }
    public void connection(boolean value) { connected = value; if (!value) clear(); }
    public void call(boolean value) { call = value; if (value) clear(); }
    public boolean request(boolean audioAlreadyOn, long now) {
        if (!trusted || !connected || call || owned || audioAlreadyOn) return false;
        owned = true; sawAudio = false; deadline = now + LIMIT_MS; return true;
    }
    public void sent() { if (owned) dispatched = true; }
    public boolean canControl() { return trusted && connected && !call; }
    public boolean owned() { return owned; }
    public boolean audio(boolean routeOn) {
        if (!owned || !dispatched || call || !connected || !trusted) return false;
        if (routeOn) sawAudio = true;
        else if (sawAudio) clear();
        return owned && routeOn;
    }
    public boolean expired(long now) { return owned && now >= deadline; }
    public boolean cancel() { boolean send = owned && dispatched && trusted && connected && !call; clear(); return send; }
    private void clear() { owned = false; dispatched = false; sawAudio = false; deadline = 0; }
}
