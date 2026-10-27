package io.vdbx.lecasa

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/// Hosts the Flutter app and a small channel for the tablet's own sensors
/// and screen: battery, ambient light, brightness, keep-screen-on.
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
                "deviceName" -> {
                    // The name set in Settings › About, else the model ("M10").
                    val name = android.provider.Settings.Global.getString(
                        contentResolver, "device_name"
                    )
                    result.success(if (name.isNullOrBlank()) android.os.Build.MODEL else name)
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
        val links = LinkTuner(this)
        MethodChannel(messenger, "io.vdbx.lecasa/ble").setMethodCallHandler { call, result ->
            when (call.method) {
                "relaxLink" -> links.relax(call.arguments as String) { result.success(it) }
                "releaseLink" -> {
                    links.release(call.arguments as String)
                    result.success(null)
                }
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

/// Asks for a slow connection interval on a link that is already up, in
/// either role. The Bluetooth plugin keeps its own handles to itself, so
/// this opens a second GATT client on the same link, which Android allows,
/// and asks through that. The handle stays open until [release]: closing it
/// could take the whole link down if nothing else on this side holds it.
@SuppressLint("MissingPermission")
private class LinkTuner(private val context: Context) {
    private val held = mutableMapOf<String, BluetoothGatt>()
    private val main = Handler(Looper.getMainLooper())

    fun relax(mac: String, done: (Boolean) -> Unit) {
        var answered = false
        fun answer(ok: Boolean) = main.post {
            if (!answered) {
                answered = true
                done(ok)
            }
        }
        try {
            val address = mac.uppercase()
            val manager = context.getSystemService(BluetoothManager::class.java)
            val device = (manager.getConnectedDevices(BluetoothProfile.GATT) +
                manager.getConnectedDevices(BluetoothProfile.GATT_SERVER))
                .firstOrNull { it.address.equals(address, ignoreCase = true) }
            if (device == null) {
                Log.i(TAG, "$address not connected")
                answer(false)
                return
            }
            held.remove(address)?.close()
            val gatt = device.connectGatt(context, false, object : BluetoothGattCallback() {
                override fun onConnectionStateChange(g: BluetoothGatt, status: Int, state: Int) {
                    if (state == BluetoothProfile.STATE_CONNECTED) {
                        val ok = g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER)
                        Log.i(TAG, "$address low power interval asked: $ok")
                        answer(ok)
                    } else {
                        answer(false)
                    }
                }
            }, BluetoothDevice.TRANSPORT_LE)
            if (gatt == null) {
                answer(false)
                return
            }
            held[address] = gatt
            main.postDelayed({ answer(false) }, 8000)
        } catch (e: Exception) {
            Log.w(TAG, "relax $mac failed", e)
            answer(false)
        }
    }

    fun release(mac: String) {
        val gatt = held.remove(mac.uppercase()) ?: return
        try {
            gatt.close()
        } catch (e: Exception) {
            Log.w(TAG, "release $mac failed", e)
        }
    }

    companion object {
        const val TAG = "LeCasaLink"
    }
}
