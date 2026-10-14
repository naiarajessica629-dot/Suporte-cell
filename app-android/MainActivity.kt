package com.superfrio.suporte_cell

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Entrega ao Flutter o link que abriu o app (https://.../s/CODIGO),
// tanto no primeiro abrir (getInitialLink) quanto com o app já aberto (onNewIntent).
class MainActivity : FlutterActivity() {
    private val channelName = "suporte/deeplink"
    private var startUri: String? = null
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startUri = intent?.data?.toString()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitialLink") {
                result.success(startUri)
                startUri = null
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val data = intent.data?.toString()
        if (data != null) channel?.invokeMethod("link", data)
    }
}
