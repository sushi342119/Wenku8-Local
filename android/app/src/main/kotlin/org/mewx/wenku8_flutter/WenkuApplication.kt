package org.mewx.wenku8_flutter

import android.app.Application
import com.ryanheise.audioservice.AudioServicePlugin

/** Attach app bridges even when Android creates the shared engine for a media service first. */
class WenkuApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        attachWenkuEnginePlugins(AudioServicePlugin.getFlutterEngine(this))
    }
}
