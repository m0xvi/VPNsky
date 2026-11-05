package ru.vpnsky.client.service

import android.app.Service
import android.content.ComponentCallbacks2
import ru.vpnsky.client.common.BroadcastAction
import ru.vpnsky.client.common.GlobalState
import ru.vpnsky.client.common.sendBroadcast
import ru.vpnsky.client.core.Core

interface ManagedService {
    fun start()

    fun stop()
}

internal fun Service.notifyVpnStartRequested() {
    GlobalState.log("VPN start requested")
    BroadcastAction.VPN_START_REQUESTED.sendBroadcast()
}

internal fun Service.notifyVpnRevoked() {
    GlobalState.log("VPN permission revoked")
    BroadcastAction.VPN_REVOKED.sendBroadcast()
}

// UI_HIDDEN reaches the services too, since they share the activity's process,
// and Android 14 stopped delivering the running levels this answers to.
@Suppress("DEPRECATION")
internal fun trimCoreMemory(level: Int) {
    MitmPressure.onTrimMemory(level)
    if (level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW ||
        level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL
    ) {
        Core.forceGC()
    }
}

internal fun lowCoreMemory() {
    MitmPressure.onLowMemory()
    Core.forceGC()
}
