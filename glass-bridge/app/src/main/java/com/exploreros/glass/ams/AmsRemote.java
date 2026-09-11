package com.exploreros.glass.ams;

import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import com.exploreros.glass.ble.GattOperationQueue;
import com.exploreros.glass.core.ProtocolException;
import java.util.UUID;

/** Direct AMS remote, enabled only by live Remote Command notifications. */
public final class AmsRemote {
    private static final UUID SERVICE = UUID.fromString("89D3502B-0F36-433A-8EF4-C502AD55F8DC"), REMOTE_COMMAND = UUID.fromString(AmsState.REMOTE_UUID), ENTITY_UPDATE = UUID.fromString("2F7CABCE-808D-411F-9A0C-BB92BA96C102"), CCCD = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB");
    public interface Callbacks { void status(String text); void media(AmsState.Snapshot value); }
    private final BluetoothGatt gatt; private final GattOperationQueue queue; private final BluetoothGattCharacteristic remote, update; private final Callbacks callbacks; private final AmsState state = new AmsState(); private volatile boolean closed;
    private AmsRemote(BluetoothGatt gatt, GattOperationQueue queue, BluetoothGattCharacteristic remote, BluetoothGattCharacteristic update, Callbacks callbacks) { this.gatt = gatt; this.queue = queue; this.remote = remote; this.update = update; this.callbacks = callbacks; }
    public static AmsRemote attach(BluetoothGatt gatt, GattOperationQueue queue, Callbacks callbacks) {
        BluetoothGattService service = gatt.getService(SERVICE); if (service == null) return null;
        BluetoothGattCharacteristic remote = service.getCharacteristic(REMOTE_COMMAND), update = service.getCharacteristic(ENTITY_UPDATE);
        if (remote == null || update == null || remote.getDescriptor(CCCD) == null || update.getDescriptor(CCCD) == null) return null;
        return new AmsRemote(gatt, queue, remote, update, callbacks);
    }
    public void start() { enable(remote); enable(update); for (byte[] subscription : AmsState.subscriptions()) write(update, subscription, -1); callbacks.status("AMS discovered; commands pending"); }
    public boolean handles(BluetoothGattCharacteristic characteristic) { return characteristic == remote || characteristic == update; }
    public void changed(BluetoothGattCharacteristic characteristic, byte[] value) { if (closed) return; try { if (characteristic == remote) state.commands(value); else state.update(value); callbacks.media(state.snapshot()); } catch (ProtocolException e) { callbacks.status("AMS metadata rejected"); } }
    public void perform(int command) { try { write(remote, state.command(command), command); } catch (ProtocolException e) { callbacks.status("AMS command unavailable"); } }
    public void close() { closed = true; state.clear(); }
    private void write(final BluetoothGattCharacteristic characteristic, final byte[] value, final int command) { if (closed) return; queue.enqueue(new GattOperationQueue.Starter() { @Override public boolean start() { if (closed) return false; if (command >= 0 && !state.supports(command)) return false; characteristic.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT); characteristic.setValue(value); return gatt.writeCharacteristic(characteristic); } }); }
    private void enable(final BluetoothGattCharacteristic characteristic) { final BluetoothGattDescriptor descriptor = characteristic.getDescriptor(CCCD); queue.enqueue(new GattOperationQueue.Starter() { @Override public boolean start() { if (closed || !gatt.setCharacteristicNotification(characteristic, true)) return false; descriptor.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE); return gatt.writeDescriptor(descriptor); } }); }
}
