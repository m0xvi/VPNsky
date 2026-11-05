package ru.vpnsky.client

import android.app.Application
import android.content.Context
import ru.vpnsky.client.common.GlobalState

class FlClashApplication : Application() {
    override fun attachBaseContext(base: Context?) {
        super.attachBaseContext(base)
        GlobalState.init(this)
    }
}
