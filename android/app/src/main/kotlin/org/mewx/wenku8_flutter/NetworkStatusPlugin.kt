package org.mewx.wenku8_flutter

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** A single default-network observer per engine. No HTTP polling or Wi-Fi-only assumptions. */
class NetworkStatusPlugin : FlutterPlugin, EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var manager: ConnectivityManager? = null
    private var events: EventChannel? = null
    private var methods: MethodChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var current: Network? = null
    private var capabilities: NetworkCapabilities? = null
    private var blocked = false
    private var last: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        manager = binding.applicationContext.getSystemService(ConnectivityManager::class.java)
        events = EventChannel(binding.binaryMessenger, "org.mewx.wenku8/network_events").also {
            it.setStreamHandler(this)
        }
        methods = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/network_status").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "current") result.success(snapshot()) else result.notImplemented()
            }
        }
    }

    private fun classify(caps: NetworkCapabilities?, blocked: Boolean = false): String =
        NetworkStatePolicy.classify(
            caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true,
            blocked,
        )

    private fun snapshot(): String {
        val service = manager ?: return "unknown"
        return try {
            val network = service.activeNetwork ?: return "offline"
            classify(service.getNetworkCapabilities(network))
        } catch (_: SecurityException) { "unknown" }
    }

    private fun publish(state: String) {
        if (last == state) return
        last = state
        sink?.success(state)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        stop()
        sink = eventSink
        val service = manager ?: run { publish("unknown"); return }
        val observer = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { main.post {
                if (sink !== eventSink) return@post
                current = network; capabilities = null; blocked = false
                publish("checking")
            } }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { main.post {
                if (sink !== eventSink || current != network) return@post
                capabilities = caps
                publish(classify(caps, blocked))
            } }
            override fun onLost(network: Network) { main.post {
                // A late loss from the previous default must not hide a newly connected network.
                if (sink !== eventSink || current != network) return@post
                current = null; capabilities = null; blocked = false
                publish("offline")
            } }
            override fun onBlockedStatusChanged(network: Network, isBlocked: Boolean) { main.post {
                if (sink !== eventSink || current != network) return@post
                blocked = isBlocked
                publish(classify(capabilities, blocked))
            } }
        }
        try {
            service.registerDefaultNetworkCallback(observer)
            callback = observer
            current = service.activeNetwork
            capabilities = current?.let(service::getNetworkCapabilities)
            publish(if (current == null) "offline" else classify(capabilities))
        } catch (_: SecurityException) { publish("unknown") }
    }

    override fun onCancel(arguments: Any?) = stop()

    private fun stop() {
        callback?.let { observer ->
            try { manager?.unregisterNetworkCallback(observer) } catch (_: IllegalArgumentException) { }
        }
        callback = null; sink = null; current = null; capabilities = null; last = null; blocked = false
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        events?.setStreamHandler(null); methods?.setMethodCallHandler(null)
        events = null; methods = null; manager = null
    }
}
