package com.exploreros.glass.ble;

import java.util.ArrayDeque;
import java.util.Timer;
import java.util.TimerTask;

/** BluetoothGatt allows one outstanding operation. Queue is bounded and fails closed. */
public final class GattOperationQueue {
    public interface Starter { boolean start(); }
    public interface Failure { void onFailure(); }
    /** Injectable timing seam; one callback deadline is armed only while an operation is active. */
    public interface Deadline { void arm(Runnable callback, long milliseconds); void cancel(); }
    private static final int MAX_PENDING = 2048; private static final long OPERATION_TIMEOUT_MS = 15000L;
    private final ArrayDeque<Starter> pending = new ArrayDeque<Starter>(); private final Failure failure; private final Deadline deadline; private boolean busy, failed; private int generation;
    public GattOperationQueue(Failure failure) { this(failure, new TimerDeadline()); }
    public GattOperationQueue(Failure failure, Deadline deadline) { this.failure = failure; this.deadline = deadline; }
    public synchronized boolean enqueue(Starter starter) { if (failed || pending.size() >= MAX_PENDING) { fail(); return false; } pending.addLast(starter); runNext(); return !failed; }
    /** Runs only after every earlier GATT callback succeeded. No ATT operation is started. */
    public synchronized boolean afterPending(Runnable callback) { return enqueue(new Completion(callback)); }
    private static final class Completion implements Starter { final Runnable callback; Completion(Runnable callback) { this.callback = callback; } public boolean start() { callback.run(); return true; } }
    public synchronized void complete(boolean success) { if (failed) return; if (!busy) { fail(); return; } deadline.cancel(); generation++; busy = false; if (!success) { fail(); return; } runNext(); }
    public synchronized void clear() { generation++; deadline.cancel(); pending.clear(); busy = false; failed = true; }
    private void runNext() { if (busy || failed) return; while (!pending.isEmpty() && pending.peekFirst() instanceof Completion) { pending.removeFirst().start(); if (busy || failed) return; } if (pending.isEmpty()) return; busy = true; final int activeGeneration = ++generation; if (!pending.removeFirst().start()) { busy = false; fail(); return; } deadline.arm(new Runnable() { @Override public void run() { synchronized (GattOperationQueue.this) { if (!failed && busy && generation == activeGeneration) { busy = false; fail(); } } } }, OPERATION_TIMEOUT_MS); }
    private void fail() { if (failed) return; failed = true; generation++; deadline.cancel(); pending.clear(); failure.onFailure(); }
    private static final class TimerDeadline implements Deadline { private final Timer timer = new Timer("explorer-gatt-deadline", true); private TimerTask task; @Override public synchronized void arm(Runnable callback, long milliseconds) { cancel(); final Runnable deadlineCallback = callback; task = new TimerTask() { @Override public void run() { deadlineCallback.run(); } }; timer.schedule(task, milliseconds); } @Override public synchronized void cancel() { if (task != null) { task.cancel(); task = null; } } }
}
