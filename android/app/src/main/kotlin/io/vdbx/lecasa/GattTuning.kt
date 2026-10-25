package io.vdbx.lecasa

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.os.Build
import android.util.Log
import dev.zeekr.bluetooth_low_energy_android.BluetoothLowEnergyAndroidPlugin
import dev.zeekr.bluetooth_low_energy_android.CentralManagerImpl
import io.flutter.embedding.engine.FlutterEngine

/// Reaches the BluetoothGatt that the bluetooth_low_energy plugin opened for
/// a device and adjusts the link: connection priority and PHY. The plugin
/// has no API for either.
///
/// Why: the PRITOM M10 loses every link to a Daly BMS module (status 8)
/// exactly one supervision timeout after the module asks for new connection
/// parameters. Asking for parameters from our side first, and pinning the
/// 1M PHY, are the two knobs Android gives an app.
///
/// The plugin keeps its GATT objects in private fields, so this finds them
/// by type, not by name (R8 renames fields in release builds).
object GattTuning {
    private const val TAG = "LeCasaGatt"

    private fun gattFor(engine: FlutterEngine, address: String): BluetoothGatt? {
        val plugin = engine.plugins.get(BluetoothLowEnergyAndroidPlugin::class.java) ?: return null
        val central = plugin.javaClass.declaredFields
            .firstOrNull { it.type == CentralManagerImpl::class.java }
            ?.let {
                it.isAccessible = true
                it.get(plugin)
            } ?: return null
        var cls: Class<*>? = central.javaClass
        while (cls != null) {
            for (f in cls.declaredFields) {
                if (!Map::class.java.isAssignableFrom(f.type)) continue
                f.isAccessible = true
                val gatt = (f.get(central) as? Map<*, *>)?.get(address)
                if (gatt is BluetoothGatt) return gatt
            }
            cls = cls.superclass
        }
        return null
    }

    /// Returns what was done, for the log. [priority] is "high", "balanced",
    /// "low" or null to leave it.
    @SuppressLint("MissingPermission")
    fun tune(engine: FlutterEngine, address: String, priority: String?, phy1m: Boolean): Map<String, Any?> {
        val gatt = try {
            gattFor(engine, address)
        } catch (e: Exception) {
            Log.w(TAG, "could not reach the plugin's GATT objects", e)
            null
        } ?: return mapOf("found" to false)

        val out = mutableMapOf<String, Any?>("found" to true)
        if (priority != null) {
            val p = when (priority) {
                "high" -> BluetoothGatt.CONNECTION_PRIORITY_HIGH
                "low" -> BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER
                else -> BluetoothGatt.CONNECTION_PRIORITY_BALANCED
            }
            out["priority"] = gatt.requestConnectionPriority(p)
        }
        if (phy1m && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            gatt.setPreferredPhy(
                BluetoothDevice.PHY_LE_1M_MASK,
                BluetoothDevice.PHY_LE_1M_MASK,
                BluetoothDevice.PHY_OPTION_NO_PREFERRED,
            )
            out["phy"] = "1M"
        }
        Log.i(TAG, "tune $address: $out")
        return out
    }
}
