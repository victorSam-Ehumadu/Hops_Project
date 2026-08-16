package com.example.client

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.io.PrintWriter
import java.util.UUID

class RfcommChatService(private val channel: MethodChannel) {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("fa87c0d0-afac-11de-8a39-0800200c9a66")
    }

    private var serverSocket: BluetoothServerSocket? = null
    private var clientSocket: BluetoothSocket? = null
    private var writer: PrintWriter? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // ── Server ────────────────────────────────────────────────────────────────
    fun startServer(
        bluetoothAdapter: BluetoothAdapter,
        callback: (Boolean, String?) -> Unit,
    ) {
        if (!hasPermission()) { callback(false, "Missing BLUETOOTH_CONNECT permission"); return }

        scope.launch {
            try {
                serverSocket = bluetoothAdapter
                    .listenUsingRfcommWithServiceRecord("HopsChat", SERVICE_UUID)

                val socket = serverSocket?.accept()   // blocks until client connects
                serverSocket?.close()
                serverSocket = null

                if (socket != null) {
                    onSocketReady(socket)
                    withContext(Dispatchers.Main) { callback(true, null) }
                } else {
                    withContext(Dispatchers.Main) { callback(false, "Connection failed") }
                }
            } catch (e: IOException) {
                withContext(Dispatchers.Main) { callback(false, "Server error: ${e.message}") }
            }
        }
    }

    // ── Client ────────────────────────────────────────────────────────────────
    fun connectToDevice(
        bluetoothAdapter: BluetoothAdapter,
        macAddress: String,
        callback: (Boolean, String?) -> Unit,
    ) {
        if (!hasPermission()) { callback(false, "Missing BLUETOOTH_CONNECT permission"); return }

        scope.launch {
            try {
                val device: BluetoothDevice = bluetoothAdapter.getRemoteDevice(macAddress)
                val socket = device.createRfcommSocketToServiceRecord(SERVICE_UUID)
                bluetoothAdapter.cancelDiscovery()
                socket.connect()
                onSocketReady(socket)
                withContext(Dispatchers.Main) { callback(true, null) }
            } catch (e: IOException) {
                withContext(Dispatchers.Main) { callback(false, "Connection error: ${e.message}") }
            }
        }
    }

    // ── Shared socket setup ───────────────────────────────────────────────────
    // suspend, not a plain fun — every call site is already inside a
    // scope.launch { } coroutine (running on Dispatchers.IO), and
    // MethodChannel.invokeMethod must run on the main thread, same
    // requirement listenForMessages' own invokeMethod call below already
    // follows.
    private suspend fun onSocketReady(socket: BluetoothSocket) {
        clientSocket = socket
        writer = PrintWriter(socket.outputStream, true)
        // Only meaningful for the server (startServer) side — the client
        // already knows the MAC it dialed via connectToDevice's own
        // argument. This is what lets the *host* side also learn (and
        // persist, on the Dart side) the peer's address, so a future chat
        // with this same contact can skip requesting discoverability
        // entirely — see rfcomm_chat_service.dart's onMacLearned.
        withContext(Dispatchers.Main) {
            channel.invokeMethod("onConnected", socket.remoteDevice.address)
        }
        listenForMessages(socket)
    }

    private fun listenForMessages(socket: BluetoothSocket) {
        scope.launch {
            try {
                val reader = BufferedReader(InputStreamReader(socket.inputStream))
                while (isActive) {
                    val line = reader.readLine() ?: break
                    withContext(Dispatchers.Main) {
                        channel.invokeMethod("onMessageReceived", line)
                    }
                }
            } catch (e: IOException) {
                if (clientSocket != null) {
                    withContext(Dispatchers.Main) {
                        channel.invokeMethod("onConnectionLost", null)
                    }
                }
            }
        }
    }

    // ── Send (off main thread) ────────────────────────────────────────────────
    fun sendMessage(message: String, callback: (Boolean) -> Unit) {
        scope.launch {
            try {
                writer?.println(message) ?: throw IOException("Not connected")
                withContext(Dispatchers.Main) { callback(true) }
            } catch (e: IOException) {
                withContext(Dispatchers.Main) { callback(false) }
            }
        }
    }

    // ── Disconnect ────────────────────────────────────────────────────────────
    fun disconnect() {
        scope.cancel()
        writer = null
        try { clientSocket?.close() } catch (_: IOException) {}
        try { serverSocket?.close() } catch (_: IOException) {}
        clientSocket = null
        serverSocket = null
    }

    private fun hasPermission() = ActivityCompat.checkSelfPermission(
        MainActivity.context,
        Manifest.permission.BLUETOOTH_CONNECT,
    ) == PackageManager.PERMISSION_GRANTED
}