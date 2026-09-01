package com.example.client

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.StatusBarManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.function.Consumer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

@SuppressLint("MissingPermission")
class MainActivity : FlutterActivity() {

    companion object {
        lateinit var context: Context
        private const val REQUEST_DISCOVERABLE = 4201
    }

    private val activeServices = mutableMapOf<String, RfcommChatService>()

    // Pending result for ensureDiscoverable — startActivityForResult is
    // asynchronous (the system "make this device discoverable" dialog),
    // so the MethodChannel.Result has to be held here and completed once
    // onActivityResult actually fires, not returned inline.
    private var discoverableResult: MethodChannel.Result? = null

    // ── Discovery (from YT tutorial approach) ────────────────────────────────
    // EventChannel streams found devices to Flutter as they are discovered.
    private var discoveryEventSink: EventChannel.EventSink? = null

    private val foundDeviceReceiver = FoundDeviceReceiver { device ->
        val name = if (hasPermission(Manifest.permission.BLUETOOTH_CONNECT))
            device.name ?: "Unknown"
        else
            "Unknown"
        val map = mapOf("name" to name, "address" to device.address)
        // Post to main thread — EventSink must be called on main thread
        runOnUiThread {
            discoveryEventSink?.success(map)
        }
    }

    private var receiverRegistered = false

    // ── Silent SOS Quick Settings tile ────────────────────────────────────
    // See HopsSosTileService.kt for why a tile tap doesn't fire the flare
    // directly. Two delivery paths to Dart, matching the two ways this
    // Activity can receive the tile's launch intent:
    //   - Cold start (Hops wasn't running): the intent that CREATED this
    //     Activity carries the action, caught in onCreate below and held
    //     here until Dart calls consumePendingSos once it's ready to
    //     receive it — the same "engine wasn't alive yet to catch a
    //     listener" problem shortcutNotifier's cold-start handling solves
    //     for the existing app-icon shortcut (see main.dart/hops_app.dart).
    //   - Warm start (Hops already running): MainActivity's launchMode is
    //     singleTop, so a second launch intent arrives via onNewIntent
    //     instead of a new onCreate — delivered straight to Dart through
    //     sosChannel since the engine's already up.
    private var sosChannel: MethodChannel? = null
    private var pendingSos: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MainActivity.context = applicationContext
        if (intent?.action == HopsSosTileService.ACTION_TRIGGER_SOS) {
            pendingSos = true
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == HopsSosTileService.ACTION_TRIGGER_SOS) {
            sosChannel?.invokeMethod("sosTriggered", null)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (receiverRegistered) {
            unregisterReceiver(foundDeviceReceiver)
            receiverRegistered = false
        }
    }

    // Completes ensureDiscoverable's pending result. resultCode from
    // ACTION_REQUEST_DISCOVERABLE is the granted duration in seconds on
    // success (a positive int, NOT Activity.RESULT_OK), or
    // Activity.RESULT_CANCELED (0) if the user declined.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_DISCOVERABLE) {
            val granted = resultCode != Activity.RESULT_CANCELED
            discoverableResult?.success(granted)
            discoverableResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bluetoothAdapter: BluetoothAdapter = bluetoothManager.adapter

        // ── EventChannel: streams discovered devices to Dart ─────────────────
        // Dart side listens to this stream during a scan.
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.client/bluetooth/discovery"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                discoveryEventSink = events
            }
            override fun onCancel(arguments: Any?) {
                discoveryEventSink = null
            }
        })

        // ── Meta MethodChannel ───────────────────────────────────────────────
        val metaChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.client/rfcomm/meta"
        )

        metaChannel.setMethodCallHandler { call, result ->
            when (call.method) {

                // ── Android API level ─────────────────────────────────────────
                // Needed because BLUETOOTH_SCAN/ADVERTISE/CONNECT only exist as
                // runtime permissions from Android 12 (API 31). Below that,
                // permission_handler maps them to no manifest entry at all and
                // reports DENIED forever - a state the user cannot clear, since
                // there is no dialog and nothing in system settings to switch
                // on. Dart has to know the API level to ask for the right set.
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)

                // ── Adapter name read/write (for BLE name restoration) ────────
                "getAdapterName" -> {
                    try {
                        result.success(bluetoothAdapter.name ?: "")
                    } catch (e: Exception) {
                        result.error("NAME_ERROR", e.message, null)
                    }
                }
                "setAdapterName" -> {
                    try {
                        val name = call.argument<String>("name")
                        if (name != null) {
                            bluetoothAdapter.name = name
                            result.success(null)
                        } else {
                            result.error("NO_NAME", "name argument required", null)
                        }
                    } catch (e: Exception) {
                        result.error("SET_NAME_ERROR", e.message, null)
                    }
                }

                // ── Own address (for server/client role determination) ─────────
                "getOwnAddress" -> {
                    try {
                        result.success(bluetoothAdapter.address ?: "")
                    } catch (e: Exception) {
                        result.error("ADDR_ERROR", e.message, null)
                    }
                }

                // ── Bonded devices (YT tutorial: updatePairedDevices) ─────────
                "getBondedDevices" -> {
                    if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) {
                        result.error("NO_PERM", "BLUETOOTH_CONNECT permission required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val list = bluetoothAdapter.bondedDevices?.map { device ->
                            mapOf("name" to (device.name ?: "Unknown"), "address" to device.address)
                        } ?: emptyList()
                        result.success(list)
                    } catch (e: Exception) {
                        result.error("BT_ERROR", e.message, null)
                    }
                }

                // ── Start classic BT discovery (YT tutorial: startDiscovery) ──
                // Discovered devices are streamed via the EventChannel above.
                "startDiscovery" -> {
                    if (!hasPermission(Manifest.permission.BLUETOOTH_SCAN)) {
                        result.error("NO_PERM", "BLUETOOTH_SCAN permission required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (!receiverRegistered) {
                            val filter = IntentFilter(BluetoothDevice.ACTION_FOUND)
                            registerReceiver(foundDeviceReceiver, filter)
                            receiverRegistered = true
                        }
                        bluetoothAdapter.cancelDiscovery() // cancel any existing scan first
                        bluetoothAdapter.startDiscovery()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("DISCOVERY_ERROR", e.message, null)
                    }
                }

                // ── Stop classic BT discovery (YT tutorial: stopDiscovery) ────
                "stopDiscovery" -> {
                    if (!hasPermission(Manifest.permission.BLUETOOTH_SCAN)) {
                        result.error("NO_PERM", "BLUETOOTH_SCAN permission required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        bluetoothAdapter.cancelDiscovery()
                        if (receiverRegistered) {
                            unregisterReceiver(foundDeviceReceiver)
                            receiverRegistered = false
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("STOP_ERROR", e.message, null)
                    }
                }

                // ── Classic BT discoverability ──────────────────────────────────
                // RFCOMM chat (see rfcomm_chat_service.dart) needs the OTHER
                // device to see this one during classic Bluetooth discovery —
                // for two devices that have never bonded before, that requires
                // this device to be actively "discoverable," which (unlike BLE
                // scanning/advertising permissions) Android requires an explicit
                // user-facing system dialog for; it can't be silently granted.
                // [seconds] argument controls how long discoverability lasts
                // (Android caps this at 300s); result completes once the user
                // responds to that dialog (or immediately with -1/"denied" if
                // Bluetooth is already off or the intent can't be launched).
                "ensureDiscoverable" -> {
                    val seconds = call.argument<Int>("seconds") ?: 120
                    try {
                        discoverableResult = result
                        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
                            putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, seconds)
                        }
                        startActivityForResult(intent, REQUEST_DISCOVERABLE)
                    } catch (e: Exception) {
                        discoverableResult = null
                        result.error("DISCOVERABLE_ERROR", e.message, null)
                    }
                }

                // ── RFCOMM Session open ───────────────────────────────────────
                "openSession" -> {
                    val peerId = call.argument<String>("peerId")
                        ?: return@setMethodCallHandler result.error(
                            "NO_PEER", "peerId required", null
                        )
                    val channelName = "com.example.client/rfcomm/$peerId"
                    val peerChannel = MethodChannel(
                        flutterEngine.dartExecutor.binaryMessenger,
                        channelName
                    )
                    val service = RfcommChatService(peerChannel)
                    activeServices[peerId] = service

                    peerChannel.setMethodCallHandler { innerCall, innerResult ->
                        when (innerCall.method) {
                            "startServer" -> service.startServer(bluetoothAdapter) { ok, err ->
                                if (ok) innerResult.success(null)
                                else innerResult.error("SERVER_ERROR", err, null)
                            }
                            "connectToDevice" -> {
                                val mac = innerCall.argument<String>("macAddress")
                                    ?: return@setMethodCallHandler innerResult.error(
                                        "NO_MAC", "macAddress required", null
                                    )
                                // Cancel discovery before connecting — required by Android
                                bluetoothAdapter.cancelDiscovery()
                                service.connectToDevice(bluetoothAdapter, mac) { ok, err ->
                                    if (ok) innerResult.success(null)
                                    else innerResult.error("CONNECT_ERROR", err, null)
                                }
                            }
                            "sendMessage" -> {
                                val msg = innerCall.argument<String>("message")
                                    ?: return@setMethodCallHandler innerResult.error(
                                        "NO_MSG", "message required", null
                                    )
                                service.sendMessage(msg) { ok -> innerResult.success(ok) }
                            }
                            "disconnect" -> {
                                service.disconnect()
                                activeServices.remove(peerId)
                                innerResult.success(null)
                            }
                            else -> innerResult.notImplemented()
                        }
                    }
                    result.success(null)
                }

                // ── RFCOMM Session close ──────────────────────────────────────
                "closeSession" -> {
                    val peerId = call.argument<String>("peerId")
                        ?: return@setMethodCallHandler result.error(
                            "NO_PEER", "peerId required", null
                        )
                    activeServices[peerId]?.disconnect()
                    activeServices.remove(peerId)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        // ── Silent SOS tile channel ───────────────────────────────────────
        sosChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.client/sos_tile"
        )
        sosChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Consumed once, at Dart startup — mirrors quick_actions'
                // own cold-start handling for the existing shortcut.
                "consumePendingSos" -> {
                    val had = pendingSos
                    pendingSos = false
                    result.success(had)
                }
                // Prompts the user with Android's own "Add tile?" system
                // dialog (API 33+ only — StatusBarManager.requestAddTileService
                // doesn't exist below that; despite the name, this lives on
                // StatusBarManager, not TileService itself). Below API 33,
                // the Dart side falls back to showing manual "swipe down
                // twice, tap edit" instructions instead — see sos_service.dart.
                "requestAddTile" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        try {
                            val statusBarManager = getSystemService(StatusBarManager::class.java)
                            val componentName = ComponentName(this, HopsSosTileService::class.java)
                            val icon = Icon.createWithResource(this, R.mipmap.ic_launcher_monochrome)
                            // Built as an explicit Consumer<Int> rather than a
                            // trailing lambda — Kotlin's automatic SAM
                            // conversion for this method's last
                            // functional-interface parameter isn't reliable,
                            // and left it unable to infer the callback
                            // parameter's type.
                            val resultConsumer = Consumer<Int> { status ->
                                val accepted =
                                    status == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                                    status == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED
                                result.success(accepted)
                            }
                            statusBarManager.requestAddTileService(
                                componentName,
                                "Hops SOS",
                                icon,
                                ContextCompat.getMainExecutor(this),
                                resultConsumer
                            )
                        } catch (e: Exception) {
                            result.error("ADD_TILE_ERROR", e.message, null)
                        }
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return ActivityCompat.checkSelfPermission(
            this, permission
        ) == PackageManager.PERMISSION_GRANTED
    }
}