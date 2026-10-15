package com.superfrio.suporte_cell

import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Dois canais:
//  - suporte/deeplink: entrega ao Flutter o link que abriu o app.
//  - suporte/overlay: desenha o apontador do atendente sobre a tela (guia visual).
class MainActivity : FlutterActivity() {
    private val deeplinkChannel = "suporte/deeplink"
    private val overlayChannel = "suporte/overlay"
    private var startUri: String? = null
    private var dlChannel: MethodChannel? = null

    private var wm: WindowManager? = null
    private var overlayView: PointerView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startUri = intent?.data?.toString()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        dlChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deeplinkChannel)
        dlChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitialLink") { result.success(startUri); startUri = null }
            else result.notImplemented()
        }

        val ov = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, overlayChannel)
        ov.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(canOverlay())
                "requestPermission" -> { requestOverlay(); result.success(null) }
                "show" -> {
                    val x = call.argument<Double>("x") ?: -1.0
                    val y = call.argument<Double>("y") ?: -1.0
                    showPointer(x.toFloat(), y.toFloat()); result.success(null)
                }
                "hide" -> { hidePointer(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val data = intent.data?.toString()
        if (data != null) dlChannel?.invokeMethod("link", data)
    }

    private fun canOverlay(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun requestOverlay() {
        if (canOverlay()) return
        val i = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try { startActivity(i) } catch (_: Exception) {}
    }

    private fun ensureView() {
        if (overlayView != null || !canOverlay()) return
        val v = PointerView(this)
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else WindowManager.LayoutParams.TYPE_PHONE
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        lp.gravity = Gravity.TOP or Gravity.START
        try { wm?.addView(v, lp); overlayView = v } catch (_: Exception) {}
    }

    private fun showPointer(x: Float, y: Float) {
        if (!canOverlay()) return
        runOnUiThread { ensureView(); overlayView?.setPoint(x, y) }
    }

    private fun hidePointer() {
        runOnUiThread { overlayView?.setPoint(-1f, -1f) }
    }

    override fun onDestroy() {
        try { overlayView?.let { wm?.removeView(it) } } catch (_: Exception) {}
        overlayView = null
        super.onDestroy()
    }

    // Anel pulsante na posição indicada (coordenadas normalizadas 0..1).
    class PointerView(context: Context) : View(context) {
        private var nx = -1f
        private var ny = -1f
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 8f; color = Color.parseColor("#4B93FF")
        }
        private val halo = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 4f; color = Color.parseColor("#B3FFFFFF")
        }
        private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL; color = Color.parseColor("#4B93FF")
        }

        fun setPoint(x: Float, y: Float) { nx = x; ny = y; invalidate() }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            if (nx < 0f || ny < 0f) return
            val cx = nx * width
            val cy = ny * height
            val t = (System.currentTimeMillis() % 1000L) / 1000f
            val r = 28f + 26f * t
            ring.alpha = (255 * (1f - t)).toInt().coerceIn(0, 255)
            canvas.drawCircle(cx, cy, r, ring)
            canvas.drawCircle(cx, cy, 26f, halo)
            canvas.drawCircle(cx, cy, 9f, dot)
            postInvalidateOnAnimation()
        }
    }
}
