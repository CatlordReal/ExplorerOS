package com.exploreros.glass.integration;

/** Pure lifecycle/presentation policy. No Android context, timers, wake locks, or content storage. */
public final class IntegrationPolicy {
    public static final int ANCS_SILENT = 1, ANCS_PREEXISTING = 1 << 2;
    public static final long PRESENTATION_MS = 30000, DISMISS_COOLDOWN_MS = 10000;
    private long suppressedUntil, lastPresentation = -1;
    private boolean navigationDismissed;
    public static boolean backgroundAllowed(boolean paired, boolean enabled) { return paired && enabled; }
    public synchronized boolean present(boolean paired, boolean enabled, boolean foreground, boolean setup, boolean authenticated, String type, boolean newlyAdded, int flags, long now) {
        if (!backgroundAllowed(paired, enabled) || foreground || setup || !authenticated || now < suppressedUntil) return false;
        if ("ancs".equals(type) && (!newlyAdded || (flags & (ANCS_SILENT | ANCS_PREEXISTING)) != 0)) return false;
        if ("navigation".equals(type) && navigationDismissed) return false;
        if (!"card".equals(type) && !"navigation".equals(type) && !"ancs".equals(type)) return false;
        if (lastPresentation >= 0 && now - lastPresentation < 2000) return false;
        lastPresentation = now; return true;
    }
    public synchronized void dismissed(String type, long now) { suppressedUntil = now + DISMISS_COOLDOWN_MS; if ("navigation".equals(type)) navigationDismissed = true; }
    public synchronized void navigationStopped() { navigationDismissed = false; }
    public synchronized void clear() { suppressedUntil = 0; lastPresentation = -1; navigationDismissed = false; }
    /** Six non-waking retries; an explicit reconnect or authenticated session resets the budget. */
    public static final class Reconnect {
        private static final long[] DELAYS = {1000, 2000, 5000, 10000, 30000, 60000};
        private int attempt;
        public long next(boolean paired, boolean enabled, boolean savedPeer) { return backgroundAllowed(paired, enabled) && savedPeer && attempt < DELAYS.length ? DELAYS[attempt++] : -1; }
        public void reset() { attempt = 0; }
    }
}
