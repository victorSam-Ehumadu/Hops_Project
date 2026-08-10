package com.example.client

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

@SuppressLint("MissingPermission")
class MainActivity : FlutterActivity() {

    companion object {
        lateinit var context: Context
    }

    private val activeServices = mutableMapOf<String, RfcommChatService>()

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        MainActivity.context = applicationContext
    }

    override fun onDestroy() {
        super.onDestroy()
        if (receiverRegistered) {
            unregisterReceiver(foundDeviceReceiver)
            receiverRegistered = false
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
    }

    private fun hasPermission(permission: String): Boolean {
        return ActivityCompat.checkSelfPermission(
            this, permission
        ) == PackageManager.PERMISSION_GRANTED
    }
}