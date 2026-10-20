package com.example.client

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.StatusBarManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
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

    // ── Discovery ────────────────────────────────────────────────────────────
    // EventChannel streams found devices to Flutter as they are discovered.
    // Listens to BOTH ACTION_FOUND and ACTION_NAME_CHANGED and prefers
    // EXTRA_NAME from the broadcast intent so freshly-renamed Hops adapters
    // are recognized even when Android's BluetoothDevice cache still holds an
    // older BLE advertisement payload name (e.g. "HPS:...").
    private var discoveryEventSink: EventChannel.EventSink? = null

    private val foundDeviceReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action ?: return
            if (action != BluetoothDevice.ACTION_FOUND &&
                action != BluetoothDevice.ACTION_NAME_CHANGED
            ) return

            val device: BluetoothDevice? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(
                        BluetoothDevice.EXTRA_DEVICE,
                        BluetoothDevice::class.java
                    )
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                }
            if (device == null) return

            val extraName = intent.getStringExtra(BluetoothDevice.EXTRA_NAME)
            val name = if (hasBtPermission(Manifest.permission.BLUETOOTH_CONNECT)) {
                extraName ?: device.name ?: "Unknown"
            } else {
                extraName ?: "Unknown"
            }

            val map = mapOf("name" to name, "address" to device.address)
            runOnUiThread {
                discoveryEventSink?.success(map)
            }
        }
    }

    private var receiverRegistered = false

    // ── Silent SOS Quick Settings tile ────────────────────────────────────
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
            try {
                unregisterReceiver(foundDeviceReceiver)
            } catch (_: Exception) {}
            receiverRegistered = false
        }
        activeServices.values.forEach { it.disconnect() }
        activeServices.clear()
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

                // ── Bonded devices ────────────────────────────────────────────
                "getBondedDevices" -> {
                    if (!hasBtPermission(Manifest.permission.BLUETOOTH_CONNECT)) {
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

                // ── Start classic BT discovery ────────────────────────────────
                "startDiscovery" -> {
                    if (!hasBtPermission(Manifest.permission.BLUETOOTH_SCAN)) {
                        result.error("NO_PERM", "BLUETOOTH_SCAN permission required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (!receiverRegistered) {
                            val filter = IntentFilter().apply {
                                addAction(BluetoothDevice.ACTION_FOUND)
                                addAction(BluetoothDevice.ACTION_NAME_CHANGED)
                            }
                            registerReceiver(foundDeviceReceiver, filter)
                            receiverRegistered = true
                        }
                        if (bluetoothAdapter.isDiscovering) {
                            bluetoothAdapter.cancelDiscovery()
                        }
                        bluetoothAdapter.startDiscovery()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("DISCOVERY_ERROR", e.message, null)
                    }
                }

                // ── Stop classic BT discovery ─────────────────────────────────
                "stopDiscovery" -> {
                    if (!hasBtPermission(Manifest.permission.BLUETOOTH_SCAN)) {
                        result.error("NO_PERM", "BLUETOOTH_SCAN permission required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (bluetoothAdapter.isDiscovering) {
                            bluetoothAdapter.cancelDiscovery()
                        }
                        if (receiverRegistered) {
                            try {
                                unregisterReceiver(foundDeviceReceiver)
                            } catch (_: Exception) {}
                            receiverRegistered = false
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("STOP_ERROR", e.message, null)
                    }
                }

                // ── Classic BT discoverability ────────────────────────────────
                "ensureDiscoverable" -> {
                    val seconds = call.argument<Int>("seconds") ?: 120
                    try {
                        // Complete any stale pending result so Dart never hangs.
                        discoverableResult?.success(false)
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
                    // Cleanly close any previous native service for this peer
                    // so its server/client sockets don't hold the RFCOMM UUID.
                    activeServices.remove(peerId)?.disconnect()

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
                                runOnUiThread {
                                    if (ok) innerResult.success(null)
                                    else innerResult.error("SERVER_ERROR", err, null)
                                }
                            }
                            "connectToDevice" -> {
                                val mac = innerCall.argument<String>("macAddress")
                                    ?: return@setMethodCallHandler innerResult.error(
                                        "NO_MAC", "macAddress required", null
                                    )
                                if (bluetoothAdapter.isDiscovering) {
                                    bluetoothAdapter.cancelDiscovery()
                                }
                                service.connectToDevice(bluetoothAdapter, mac) { ok, err ->
                                    runOnUiThread {
                                        if (ok) innerResult.success(null)
                                        else innerResult.error("CONNECT_ERROR", err, null)
                                    }
                                }
                            }
                            "sendMessage" -> {
                                val msg = innerCall.argument<String>("message")
                                    ?: return@setMethodCallHandler innerResult.error(
                                        "NO_MSG", "message required", null
                                    )
                                service.sendMessage(msg) { ok ->
                                    runOnUiThread {
                                        innerResult.success(ok)
                                    }
                                }
                            }
                            "disconnect" -> {
                                // Only closes in-flight sockets on the service;
                                // keep service in activeServices until closeSession.
                                service.disconnect()
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
                    activeServices.remove(peerId)?.disconnect()
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
                "consumePendingSos" -> {
                    val had = pendingSos
                    pendingSos = false
                    result.success(had)
                }
                "requestAddTile" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        try {
                            val statusBarManager = getSystemService(StatusBarManager::class.java)
                            val componentName = ComponentName(this, HopsSosTileService::class.java)
                            val icon = Icon.createWithResource(this, R.mipmap.ic_launcher_monochrome)
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

    /**
     * BLUETOOTH_SCAN / BLUETOOTH_CONNECT only exist as runtime permissions on
     * Android 12+ (API 31+). On Android 11 and below, classic Bluetooth uses
     * install-time BLUETOOTH / BLUETOOTH_ADMIN + runtime ACCESS_FINE_LOCATION.
     */
    private fun hasBtPermission(permission: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            (permission == Manifest.permission.BLUETOOTH_SCAN ||
                    permission == Manifest.permission.BLUETOOTH_CONNECT ||
                    permission == Manifest.permission.BLUETOOTH_ADVERTISE)
        ) {
            return true
        }
        return ActivityCompat.checkSelfPermission(
            this, permission
        ) == PackageManager.PERMISSION_GRANTED
    }
}