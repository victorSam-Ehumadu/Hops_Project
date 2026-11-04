package com.example.client

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.util.UUID

@SuppressLint("MissingPermission")
class RfcommChatService(private val channel: MethodChannel) {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("fa87c0d0-afac-11de-8a39-0800200c9a66")
        private const val CONNECT_TIMEOUT_MS = 15_000L
    }

    @Volatile private var serverSocket: BluetoothServerSocket? = null
    @Volatile private var clientSocket: BluetoothSocket? = null
    @Volatile private var pendingSocket: BluetoothSocket? = null
    @Volatile private var writer: PrintWriter? = null

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // ── Server ────────────────────────────────────────────────────────────────
    fun startServer(
        bluetoothAdapter: BluetoothAdapter,
        callback: (Boolean, String?) -> Unit,
    ) {
        if (!hasPermission()) {
            callback(false, "Missing BLUETOOTH_CONNECT permission")
            return
        }

        scope.launch {
            var localServer: BluetoothServerSocket? = null
            try {
                try { serverSocket?.close() } catch (_: IOException) {}
                localServer = bluetoothAdapter
                    .listenUsingInsecureRfcommWithServiceRecord("HopsChat", SERVICE_UUID)
                serverSocket = localServer

                val socket = localServer.accept() // blocks until client connects
                try { localServer.close() } catch (_: IOException) {}
                if (serverSocket === localServer) serverSocket = null

                if (socket != null) {
                    onSocketReady(socket)
                    withContext(Dispatchers.Main + NonCancellable) {
                        callback(true, null)
                    }
                } else {
                    withContext(Dispatchers.Main + NonCancellable) {
                        callback(false, "Connection failed")
                    }
                }
            } catch (e: IOException) {
                try { localServer?.close() } catch (_: IOException) {}
                if (serverSocket === localServer) serverSocket = null
                withContext(Dispatchers.Main + NonCancellable) {
                    callback(false, "Server error: ${e.message}")
                }
            }
        }
    }

    // ── Client ────────────────────────────────────────────────────────────────
    fun connectToDevice(
        bluetoothAdapter: BluetoothAdapter,
        macAddress: String,
        callback: (Boolean, String?) -> Unit,
    ) {
        if (!hasPermission()) {
            callback(false, "Missing BLUETOOTH_CONNECT permission")
            return
        }

        scope.launch {
            var socket: BluetoothSocket? = null
            try {
                try { pendingSocket?.close() } catch (_: IOException) {}
                val device: BluetoothDevice = bluetoothAdapter.getRemoteDevice(macAddress)
                socket = device.createInsecureRfcommSocketToServiceRecord(SERVICE_UUID)
                pendingSocket = socket

                if (bluetoothAdapter.isDiscovering) {
                    bluetoothAdapter.cancelDiscovery()
                }

                val watchdog = launch {
                    delay(CONNECT_TIMEOUT_MS)
                    try { socket.close() } catch (_: IOException) {}
                }
                try {
                    socket.connect()
                } finally {
                    watchdog.cancel()
                }

                if (pendingSocket === socket) pendingSocket = null
                onSocketReady(socket)
                withContext(Dispatchers.Main + NonCancellable) {
                    callback(true, null)
                }
            } catch (e: IOException) {
                if (pendingSocket === socket) pendingSocket = null
                // Always close a failed BluetoothSocket so its native RFCOMM
                // port / file descriptor isn't leaked in the Android BT stack.
                try { socket?.close() } catch (_: IOException) {}
                withContext(Dispatchers.Main + NonCancellable) {
                    callback(false, "Connection error: ${e.message}")
                }
            }
        }
    }

    // ── Shared socket setup ───────────────────────────────────────────────────
    private suspend fun onSocketReady(socket: BluetoothSocket) {
        val oldSocket = clientSocket
        if (oldSocket != null && oldSocket !== socket) {
            try { oldSocket.close() } catch (_: IOException) {}
        }
        clientSocket = socket
        writer = PrintWriter(OutputStreamWriter(socket.outputStream, Charsets.UTF_8), true)
        withContext(Dispatchers.Main + NonCancellable) {
            channel.invokeMethod("onConnected", socket.remoteDevice.address)
        }
        listenForMessages(socket)
    }

    private fun listenForMessages(socket: BluetoothSocket) {
        scope.launch {
            try {
                val reader = BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
                while (isActive) {
                    val line = reader.readLine() ?: break
                    withContext(Dispatchers.Main) {
                        channel.invokeMethod("onMessageReceived", line)
                    }
                }
            } catch (_: IOException) {
                // Socket closed or link dropped — handled in finally below.
            } finally {
                // If clientSocket is still pointing to this socket (i.e. we
                // didn't intentionally call disconnect() first), notify Dart
                // whether the peer disconnected cleanly (EOF) or dropped (IOException).
                if (clientSocket === socket) {
                    clientSocket = null
                    writer = null
                    try { socket.close() } catch (_: IOException) {}
                    withContext(Dispatchers.Main + NonCancellable) {
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
                val w = writer ?: throw IOException("Not connected")
                synchronized(w) {
                    w.println(message)
                    w.flush()
                    // PrintWriter swallows IOExceptions internally; checkError()
                    // is required to detect a broken Bluetooth pipe on write.
                    if (w.checkError()) {
                        throw IOException("Write failed on RFCOMM socket")
                    }
                }
                withContext(Dispatchers.Main + NonCancellable) { callback(true) }
            } catch (_: IOException) {
                withContext(Dispatchers.Main + NonCancellable) { callback(false) }
            }
        }
    }

    // ── Disconnect ────────────────────────────────────────────────────────────
    fun disconnect() {
        writer = null
        val pending = pendingSocket
        val client = clientSocket
        val server = serverSocket
        pendingSocket = null
        clientSocket = null
        serverSocket = null

        try { pending?.close() } catch (_: IOException) {}
        try { client?.close() } catch (_: IOException) {}
        try { server?.close() } catch (_: IOException) {}

        // Cancel active child coroutines without permanently killing `scope`,
        // so subsequent retry calls on the same session still execute.
        scope.coroutineContext.cancelChildren()
    }

    private fun hasPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return true
        }
        return ActivityCompat.checkSelfPermission(
            MainActivity.context,
            Manifest.permission.BLUETOOTH_CONNECT,
        ) == PackageManager.PERMISSION_GRANTED
    }
}