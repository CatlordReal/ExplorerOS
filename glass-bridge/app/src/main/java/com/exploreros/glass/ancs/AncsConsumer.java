package com.exploreros.glass.ancs;

import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.os.Handler;
import android.os.Looper;
import com.exploreros.glass.ble.GattOperationQueue;
import com.exploreros.glass.core.ProtocolException;
import java.util.UUID;

/** Direct bonded ANCS consumer. Session text stays in memory. */
public final class AncsConsumer {
    private static final UUID SERVICE = UUID.fromString("7905F431-B5CE-4E99-A40F-4B1E122D00D0"), NOTIFICATION_SOURCE = UUID.fromString("9FBF120D-6301-42D9-8C58-25E699A21DBD"), CONTROL_POINT = UUID.fromString("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9"), DATA_SOURCE = UUID.fromString("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB"), CCCD = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB");
    public interface Callbacks { void status(String text); void notification(AncsNotifications.Notification value); void removed(long uid); void invalidated(long uid); void failure(); void unavailable(); }
    private final BluetoothGatt gatt; private final GattOperationQueue queue; private final BluetoothGattCharacteristic source, control, data; private final Callbacks callbacks; private final AncsNotifications model; private final Handler handler = new Handler(Looper.getMainLooper()); private volatile boolean closed; private Runnable deadline; private long writingUid = -1; private int writingAction = -1;
    private AncsConsumer(BluetoothGatt gatt, GattOperationQueue queue, BluetoothGattCharacteristic source, BluetoothGattCharacteristic control, BluetoothGattCharacteristic data, final Callbacks callbacks) {
        this.gatt = gatt; this.queue = queue; this.source = source; this.control = control; this.data = data; this.callbacks = callbacks;
        model = new AncsNotifications(new AncsNotifications.Events() {
            @Override public void request(final long uid, final byte[] command) { write(command, uid, -1); }
            @Override public void notification(AncsNotifications.Notification value) { callbacks.notification(value); }
            @Override public void removed(long uid) { callbacks.removed(uid); }
            @Override public void invalidated(long uid) { callbacks.invalidated(uid); }
        });
    }
    public static AncsConsumer attach(BluetoothGatt gatt, GattOperationQueue queue, Callbacks callbacks) { BluetoothGattService service = gatt.getService(SERVICE); if (service == null) return null; BluetoothGattCharacteristic source = service.getCharacteristic(NOTIFICATION_SOURCE), control = service.getCharacteristic(CONTROL_POINT), data = service.getCharacteristic(DATA_SOURCE); if (source == null || control == null || data == null || source.getDescriptor(CCCD) == null || data.getDescriptor(CCCD) == null) return null; return new AncsConsumer(gatt, queue, source, control, data, callbacks); }
    public void start() { enable(data); enable(source); callbacks.status("ANCS discovered"); }
    public boolean handles(BluetoothGattCharacteristic characteristic) { return characteristic == source || characteristic == data; }
    public void changed(BluetoothGattCharacteristic characteristic, byte[] value) { if (closed) return; try { if (characteristic == source) model.source(value); else model.data(value); } catch (ProtocolException e) { callbacks.status("ANCS response rejected; reconnect required"); callbacks.failure(); } }
    public boolean isControl(BluetoothGattCharacteristic characteristic) { return characteristic == control; }
    public void rejectedWrite() { if (writingAction < 0) model.rejected(writingUid); callbacks.status("ANCS item unavailable"); }
    public void perform(long uid, int action) { try { write(model.action(uid, action), uid, action); } catch (ProtocolException e) { callbacks.status("ANCS action unavailable"); } }
    public void close() { closed = true; if (deadline != null) handler.removeCallbacks(deadline); deadline = null; model.clear(); }
    private void write(final byte[] command, final long uid, final int action) { if (closed) return; queue.enqueue(new GattOperationQueue.Starter() { @Override public boolean start() {
        if (closed) return false;
        if (action >= 0) try { model.action(uid, action); } catch (ProtocolException e) { return false; }
        else { if (deadline != null) handler.removeCallbacks(deadline); deadline = new Runnable() { @Override public void run() { if (!closed && model.activeUid() == uid) { callbacks.unavailable(); callbacks.status("ANCS unavailable; reconnect to retry"); } } }; handler.postDelayed(deadline, 15000); }
        writingUid = uid; writingAction = action; control.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT); control.setValue(command); return gatt.writeCharacteristic(control);
    } }); }
    private void enable(final BluetoothGattCharacteristic characteristic) { final BluetoothGattDescriptor descriptor = characteristic.getDescriptor(CCCD); queue.enqueue(new GattOperationQueue.Starter() { @Override public boolean start() { if (closed || !gatt.setCharacteristicNotification(characteristic, true)) return false; descriptor.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE); return gatt.writeDescriptor(descriptor); } }); }
}
