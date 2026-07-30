package bd.july.crisis_mesh

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bluetooth adapter state.
 *
 * Neither nearby_connections nor permission_handler can tell us whether the
 * Bluetooth RADIO is actually on: a granted permission and an enabled adapter
 * are different things, and Nearby fails in a confusing way when the second is
 * missing. Fifteen lines of Kotlin answers it exactly, which beats adding a
 * whole BLE package to read one boolean.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "crisis_mesh/radio"
    private val requestEnableBt = 4711

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Which runtime permissions even EXIST depends on the OS
                    // version. Asking for an Android 13 permission on Android
                    // 11 yields a permission that can never be granted, so the
                    // app would wait forever for something impossible.
                    "sdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
                    "isBluetoothOn" -> result.success(isBluetoothOn())
                    "requestBluetoothOn" -> {
                        if (isBluetoothOn()) {
                            result.success(true)
                        } else {
                            // Shows the system "allow this app to turn on
                            // Bluetooth?" dialog. One tap, and the user never
                            // leaves the app — far better than sending them
                            // into Settings to hunt for a toggle.
                            try {
                                startActivityForResult(
                                    Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                                    requestEnableBt,
                                )
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isBluetoothOn(): Boolean = try {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        manager?.adapter?.isEnabled == true
    } catch (e: Exception) {
        // No adapter, or a permission model that hides it. Treat as off rather
        // than crashing; the readiness card will just ask the user to check.
        false
    }
}
