package io.vdbx.lecasa

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.BatteryManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/// Hosts the Flutter app and small channels for the tablet's own sensors
/// and screen (battery, ambient light, brightness, keep-screen-on) and for
/// tuning Bluetooth links (GattTuning.kt).
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "io.vdbx.lecasa/tablet").setMethodCallHandler { call, result ->
            when (call.method) {
                "battery" -> {
                    val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                    val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                    result.success(
                        mapOf(
                            "level" to if (level in 0..100) level else null,
                            "charging" to bm.isCharging,
                        )
                    )
                }
                "setBrightness" -> {
                    val v = (call.arguments as Number?)?.toFloat()
                    val lp = window.attributes
                    lp.screenBrightness = v ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    window.attributes = lp
                    result.success(null)
                }
                "keepScreenOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "io.vdbx.lecasa/gatt").setMethodCallHandler { call, result ->
            when (call.method) {
                "tuneLink" -> result.success(
                    GattTuning.tune(
                        flutterEngine,
                        call.argument<String>("address") ?: "",
                        call.argument<String>("priority"),
                        call.argument<Boolean>("phy1m") ?: false,
                    )
                )
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "io.vdbx.lecasa/light").setStreamHandler(
            LightStream(getSystemService(Context.SENSOR_SERVICE) as SensorManager)
        )
    }
}

/// Streams ambient light in lux. Ends at once on tablets without a sensor.
private class LightStream(private val sensors: SensorManager) :
    EventChannel.StreamHandler, SensorEventListener {
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val light = sensors.getDefaultSensor(Sensor.TYPE_LIGHT)
        if (light == null) {
            events.error("no_sensor", "This device has no ambient light sensor", null)
            return
        }
        sink = events
        sensors.registerListener(this, light, SensorManager.SENSOR_DELAY_NORMAL)
    }

    override fun onCancel(arguments: Any?) {
        sensors.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        sink?.success(event.values[0].toDouble())
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
