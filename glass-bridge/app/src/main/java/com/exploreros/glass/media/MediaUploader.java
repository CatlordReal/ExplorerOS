package com.exploreros.glass.media;

import android.content.Context;
import android.os.SystemClock;
import com.exploreros.glass.core.Hex;
import com.exploreros.glass.core.MediaTransfer;
import com.exploreros.glass.core.ProtocolException;
import com.exploreros.glass.core.ProtocolMessage;
import java.io.FileInputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** One TCP-only camera upload at a time. Source files are read-only and never deleted. */
public final class MediaUploader {
    public interface Callbacks { boolean transportReady(); boolean send(ProtocolMessage message); boolean completed(String sha256); void recordCompleted(String sha256) throws ProtocolException; void status(String value); }
    private final Context context; private final Callbacks callbacks; private final ExecutorService worker = Executors.newSingleThreadExecutor(); private final ArrayDeque<CameraCatalog.Entry> queue = new ArrayDeque<CameraCatalog.Entry>(); private final SecureRandom random = new SecureRandom();
    private CameraCatalog catalog; private boolean enabled, peerReady, scheduled, closed; private MediaTransfer.Sender active; private InputStream activeStream; private long sessionBytes;
    public MediaUploader(Context context, Callbacks callbacks) { this.context = context.getApplicationContext(); this.callbacks = callbacks; }
    public synchronized void enabled(boolean value) {
        if (!value) {
            // The service keeps the TCP media capability enabled until this returns, so a receiver
            // with a private partial can delete it immediately instead of waiting for its timeout.
            cancelLocked("disabled", true);
            enabled = false;
            return;
        }
        enabled = true;
        scheduleLocked();
    }
    public synchronized void peerReady(boolean value) { peerReady = value; if (!value) cancelLocked("state", false); else scheduleLocked(); }
    public synchronized void disconnected() { sessionBytes = 0; queue.clear(); cancelLocked("state", false); }
    public synchronized void close() { closed = true; enabled = false; cancelLocked("state", false); queue.clear(); worker.shutdownNow(); }
    public void inbound(ProtocolMessage message) {
        MediaTransfer.Sender sender; synchronized (this) { sender = active; }
        if (sender == null) return;
        try { sender.inbound(message, SystemClock.elapsedRealtime()); }
        catch (ProtocolException e) { sender.cancel(); callbacks.status("Camera sync stopped"); }
    }
    private void scheduleLocked() { if (closed || scheduled || !enabled || !peerReady || !callbacks.transportReady()) return; scheduled = true; worker.execute(new Runnable() { @Override public void run() { runUploads(); } }); }
    private void cancelLocked(String code, boolean notifyPeer) {
        MediaTransfer.Sender sender = active;
        if (notifyPeer && sender != null && peerReady && !closed && callbacks.transportReady()) {
            try { callbacks.send(new ProtocolMessage(1, "media.cancel", MediaTransfer.cancel(sender.id(), code))); } catch (ProtocolException ignored) { }
        }
        if (sender != null) sender.cancel();
        if (activeStream != null) try { activeStream.close(); } catch (Exception ignored) { }
    }
    private void runUploads() {
        int attempted = 0;
        try {
            while (attempted++ < MediaTransfer.MAX_CANDIDATES) {
                CameraCatalog.Entry entry = next(); if (entry == null) return;
                if (!upload(entry)) return;
            }
        } finally { synchronized (this) { scheduled = false; if (enabled && peerReady && callbacks.transportReady() && !closed && !queue.isEmpty()) scheduleLocked(); } }
    }
    private CameraCatalog.Entry next() {
        synchronized (this) { if (closed || !enabled || !peerReady || !callbacks.transportReady() || sessionBytes >= MediaTransfer.MAX_SESSION_BYTES) return null; if (!queue.isEmpty()) return queue.removeFirst(); }
        try {
            CameraCatalog value; synchronized (this) { if (catalog == null) catalog = new CameraCatalog(context); value = catalog; }
            List<CameraCatalog.Entry> page = value.nextPage(); synchronized (this) { for (CameraCatalog.Entry entry : page) if (queue.size() < MediaTransfer.MAX_QUEUE) queue.addLast(entry); return queue.isEmpty() ? null : queue.removeFirst(); }
        } catch (Exception e) { callbacks.status("Camera sync unavailable"); return null; }
    }
    private boolean upload(CameraCatalog.Entry entry) {
        try {
            Stable stable = hash(entry); if (callbacks.completed(stable.hash)) return true;
            synchronized (this) { if (sessionBytes + entry.bytes > MediaTransfer.MAX_SESSION_BYTES || !enabled || !peerReady || !callbacks.transportReady()) return false; active = new MediaTransfer.Sender(nextId(), stable.hash, entry.bytes, entry.mime, entry.capturedMs, SystemClock.elapsedRealtime()); }
            MediaTransfer.Sender sender = current(); if (sender == null || !send(sender.begin())) return false;
            boolean accepted = sender.await(MediaTransfer.Sender.READY, MediaTransfer.ACK_TIMEOUT_MS);
            if (sender.state() == MediaTransfer.Sender.COMPLETE) { callbacks.recordCompleted(stable.hash); callbacks.status("Camera item staged"); return true; }
            if (!accepted) return abort(sender, sender.timedOut(SystemClock.elapsedRealtime()) ? "timeout" : "state");
            stream(entry.file);
            MessageDigest digest = MessageDigest.getInstance("SHA-256"); byte[] buffer = new byte[MediaTransfer.CHUNK_BYTES]; long total = 0;
            for (int read; (read = activeStream.read(buffer)) != -1;) {
                if (read == 0) continue; byte[] chunk = read == buffer.length ? buffer : Arrays.copyOf(buffer, read); digest.update(chunk); total += read;
                if (!send(sender.chunk(chunk, SystemClock.elapsedRealtime())) || !sender.await(MediaTransfer.Sender.READY, MediaTransfer.ACK_TIMEOUT_MS)) return abort(sender, sender.timedOut(SystemClock.elapsedRealtime()) ? "timeout" : "state");
            }
            closeStream();
            if (total != entry.bytes || !stable.hash.equals(Hex.encode(digest.digest())) || !stable(entry, stable)) return abort(sender, "integrity");
            if (!send(sender.finish(SystemClock.elapsedRealtime())) || !sender.await(MediaTransfer.Sender.COMPLETE, MediaTransfer.ACK_TIMEOUT_MS)) return abort(sender, sender.timedOut(SystemClock.elapsedRealtime()) ? "timeout" : "state");
            callbacks.recordCompleted(stable.hash); synchronized (this) { sessionBytes += entry.bytes; } callbacks.status("Camera item staged"); return true;
        } catch (Exception e) { MediaTransfer.Sender sender = current(); return sender == null ? false : abort(sender, "integrity"); }
        finally { closeStream(); synchronized (this) { active = null; } }
    }
    private synchronized MediaTransfer.Sender current() { return active; }
    private boolean send(ProtocolMessage message) { synchronized (this) { return enabled && peerReady && !closed && callbacks.transportReady() && callbacks.send(message); } }
    private boolean abort(MediaTransfer.Sender sender, String code) {
        sender.cancel(); try { send(new ProtocolMessage(1, "media.cancel", MediaTransfer.cancel(sender.id(), code))); } catch (ProtocolException ignored) { } return false;
    }
    private void stream(java.io.File file) throws Exception { synchronized (this) { activeStream = new FileInputStream(file); } }
    private synchronized void closeStream() { if (activeStream != null) try { activeStream.close(); } catch (Exception ignored) { } finally { activeStream = null; } }
    private static final class Stable { final String hash; final long length, modified; Stable(String hash, long length, long modified) { this.hash = hash; this.length = length; this.modified = modified; } }
    private Stable hash(CameraCatalog.Entry entry) throws Exception {
        long beforeLength = entry.file.length(), beforeModified = entry.file.lastModified(); if (beforeLength != entry.bytes || beforeModified < 0) throw new ProtocolException("camera source changed");
        InputStream in = new FileInputStream(entry.file); MessageDigest digest = MessageDigest.getInstance("SHA-256"); byte[] buffer = new byte[32768]; long total = 0;
        for (int n; (n = in.read(buffer)) != -1;) { digest.update(buffer, 0, n); total += n; } in.close();
        if (total != entry.bytes || beforeLength != entry.file.length() || beforeModified != entry.file.lastModified()) throw new ProtocolException("camera source changed"); return new Stable(Hex.encode(digest.digest()), beforeLength, beforeModified);
    }
    private static boolean stable(CameraCatalog.Entry entry, Stable stable) { return entry.file.isFile() && entry.file.length() == stable.length && entry.file.lastModified() == stable.modified; }
    private String nextId() { byte[] bytes = new byte[16]; random.nextBytes(bytes); return Hex.encode(bytes); }
}
