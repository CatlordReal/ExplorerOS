package com.exploreros.glass;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import com.exploreros.glass.integration.IntegrationPolicy;

/** Preinstalled lifecycle only; unpaired and disabled installations do nothing at boot. */
public final class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || !(Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction()) || Intent.ACTION_MY_PACKAGE_REPLACED.equals(intent.getAction()))) return;
        if (IntegrationPolicy.backgroundAllowed(PairingStore.has(context), PairingStore.backgroundEnabled(context))) BridgeService.start(context, BridgeService.ACTION_BACKGROUND);
    }
}
