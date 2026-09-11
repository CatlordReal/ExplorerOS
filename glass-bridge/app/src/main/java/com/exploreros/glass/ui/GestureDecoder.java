package com.exploreros.glass.ui;

/** Glass touchpad gesture classifier; callers feed ACTION_DOWN/UP timestamps and positions. */
public final class GestureDecoder {
    public static final String TAP = "tap", DOUBLE_TAP = "doubleTap", LEFT = "swipeLeft", RIGHT = "swipeRight", DOWN = "swipeDown";
    private static final long TAP_MS = 250, DOUBLE_MS = 350; private static final float SWIPE = 45f;
    private long downTime, lastTap; private boolean hasTap; private float downX, downY;
    public void down(long time, float x, float y) { downTime = time; downX = x; downY = y; }
    public String up(long time, float x, float y) {
        float dx = x - downX, dy = y - downY; if (Math.abs(dx) >= SWIPE && Math.abs(dx) > Math.abs(dy)) return dx > 0 ? RIGHT : LEFT; if (dy >= SWIPE && Math.abs(dy) > Math.abs(dx)) return DOWN; if (time - downTime > TAP_MS) return null;
        String result = hasTap && time - lastTap <= DOUBLE_MS ? DOUBLE_TAP : TAP; lastTap = time; hasTap = true; return result;
    }
}
