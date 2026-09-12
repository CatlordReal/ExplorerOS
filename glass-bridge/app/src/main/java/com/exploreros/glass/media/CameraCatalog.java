package com.exploreros.glass.media;

import android.content.Context;
import android.database.Cursor;
import android.os.Environment;
import android.provider.MediaStore;
import com.exploreros.glass.core.MediaTransfer;
import java.io.File;
import java.io.FileInputStream;
import java.util.ArrayList;
import java.util.List;

/** Bounded API19 MediaStore reader. It only returns regular files under DCIM/Camera. */
public final class CameraCatalog {
    public static final class Entry {
        public final File file; public final String mime; public final long bytes, capturedMs;
        Entry(File file, String mime, long bytes, long capturedMs) { this.file = file; this.mime = mime; this.bytes = bytes; this.capturedMs = capturedMs; }
    }
    private static final int PAGE = MediaTransfer.MAX_QUEUE;
    private final Context context; private final File root;
    private boolean images = true; private long imageModified, imageId, videoModified, videoId;
    public CameraCatalog(Context context) throws Exception { this.context = context.getApplicationContext(); root = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM), "Camera").getCanonicalFile(); }
    /** Alternates image/video pages and advances past skipped/previously uploaded rows. */
    public synchronized List<Entry> nextPage() {
        List<Entry> first = query(images); images = !images; if (!first.isEmpty()) return first;
        List<Entry> second = query(images); images = !images; return second;
    }
    private List<Entry> query(boolean image) {
        ArrayList<Entry> out = new ArrayList<Entry>(); long modified = image ? imageModified : videoModified, id = image ? imageId : videoId;
        String[] columns = {MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DATA, MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED, "datetaken"};
        String selection = MediaStore.MediaColumns.DATA + " LIKE ? AND (" + MediaStore.MediaColumns.DATE_MODIFIED + " > ? OR (" + MediaStore.MediaColumns.DATE_MODIFIED + " = ? AND " + MediaStore.MediaColumns._ID + " > ?))";
        String[] args = {root.getPath() + "/%", Long.toString(modified), Long.toString(modified), Long.toString(id)};
        Cursor cursor = null;
        try {
            cursor = context.getContentResolver().query(image ? MediaStore.Images.Media.EXTERNAL_CONTENT_URI : MediaStore.Video.Media.EXTERNAL_CONTENT_URI, columns, selection, args, MediaStore.MediaColumns.DATE_MODIFIED + " ASC, " + MediaStore.MediaColumns._ID + " ASC");
            if (cursor == null) return out;
            int idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID), pathColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA), mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE), sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE), modifiedColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED), takenColumn = cursor.getColumnIndex("datetaken");
            boolean exhausted = false;
            while (out.size() < PAGE) {
                if (!cursor.moveToNext()) { exhausted = true; break; }
                long rowModified = cursor.getLong(modifiedColumn), rowId = cursor.getLong(idColumn); setCursor(image, rowModified, rowId);
                String path = cursor.getString(pathColumn), mime = cursor.getString(mimeColumn); long size = cursor.getLong(sizeColumn), taken = takenColumn < 0 ? 0 : cursor.getLong(takenColumn);
                Entry entry = allowed(path, mime, size, taken > 0 ? taken : rowModified * 1000L); if (entry != null) out.add(entry);
            }
            if (exhausted && out.isEmpty()) resetCursor(image);
        } catch (Exception ignored) { }
        finally { if (cursor != null) cursor.close(); }
        return out;
    }
    private void setCursor(boolean image, long modified, long id) { if (image) { imageModified = modified; imageId = id; } else { videoModified = modified; videoId = id; } }
    private void resetCursor(boolean image) { if (image) { imageModified = 0; imageId = 0; } else { videoModified = 0; videoId = 0; } }
    private Entry allowed(String path, String mime, long size, long capturedMs) {
        try {
            if (path == null || size < 1 || size > MediaTransfer.limitForMime(mime)) return null;
            File file = new File(path); String canonical = file.getCanonicalPath(), base = root.getPath() + "/";
            if (!canonical.startsWith(base) || !canonical.equals(file.getAbsolutePath()) || !file.isFile() || file.length() != size || !extensionMatches(file.getName(), mime) || !headerMatches(file, mime)) return null;
            return new Entry(file, mime, size, capturedMs);
        } catch (Exception ignored) { return null; }
    }
    private static boolean extensionMatches(String name, String mime) {
        String lower = name.toLowerCase(java.util.Locale.US);
        return ("image/jpeg".equals(mime) && (lower.endsWith(".jpg") || lower.endsWith(".jpeg"))) || ("image/png".equals(mime) && lower.endsWith(".png")) || ("video/mp4".equals(mime) && lower.endsWith(".mp4")) || ("video/3gpp".equals(mime) && (lower.endsWith(".3gp") || lower.endsWith(".3gpp")));
    }
    private static boolean headerMatches(File file, String mime) throws Exception {
        FileInputStream in = new FileInputStream(file); byte[] head = new byte[12]; int read = in.read(head); in.close();
        if ("image/jpeg".equals(mime)) return read >= 3 && (head[0] & 255) == 255 && (head[1] & 255) == 216 && (head[2] & 255) == 255;
        if ("image/png".equals(mime)) return read >= 8 && (head[0] & 255) == 137 && head[1] == 80 && head[2] == 78 && head[3] == 71 && head[4] == 13 && head[5] == 10 && head[6] == 26 && head[7] == 10;
        if ("video/mp4".equals(mime)) return read >= 8 && head[4] == 'f' && head[5] == 't' && head[6] == 'y' && head[7] == 'p';
        return read >= 11 && head[4] == 'f' && head[5] == 't' && head[6] == 'y' && head[7] == 'p' && head[8] == '3' && head[9] == 'g' && head[10] == 'p';
    }
}
