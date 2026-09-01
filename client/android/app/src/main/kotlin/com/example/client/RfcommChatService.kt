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
        // BluetoothSocket.connect() is a blocking native call with NO
        // built-in timeout — on some Android Bluetooth stacks (a real,
        // OEM/chipset-specific quirk, not a theoretical one) it can hang
        // indefinitely instead of ever throwing. This bounds it: a
        // watchdog coroutine closes the socket after this many
        // milliseconds if connect() hasn't returned yet, which is the
        // documented way to unblock a stuck BluetoothSocket.connect() —
        // closing it makes the blocked call throw IOException, same as
        // any other connection failure.
        private const val CONNECT_TIMEOUT_MS = 15_000L
    }

    private var serverSocket: BluetoothServerSocket? = null
    private var clientSocket: BluetoothSocket? = null
    // The socket a connectToDevice() call is currently blocked inside
    // .connect() on, if any — held so disconnect() (below) has something
    // to actually close. Without this, a hung connect() (see
    // CONNECT_TIMEOUT_MS's comment above) had NO way to be aborted: the
    // local `socket` variable inside connectToDevice's coroutine wasn't
    // stored anywhere else, clientSocket is only ever set AFTER connect()
    // returns, and cancelling the coroutine scope doesn't interrupt a
    // plain blocking call like connect() — it only stops FUTURE
    // suspension points, which never arrive while stuck inside it.
    private var pendingSocket: BluetoothSocket? = null
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
                    // INSECURE, deliberately — see connectToDevice's matching
                    // comment below for why. Using the secure variant here is
                    // what was causing an unprompted OS "Pair with X?" dialog
                    // to pop up on both this device and the peer's every time
                    // a chat connected.
                    .listenUsingInsecureRfcommWithServiceRecord("HopsChat", SERVICE_UUID)

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
                // INSECURE RFCOMM, not the "secure" variant this used to
                // call. A *secure* RFCOMM connect() to a device Android
                // hasn't bonded with yet silently kicks off real OS-level
                // Bluetooth bonding as a side effect — which is exactly what
                // was surfacing as an unsolicited "Pair with <phone>?" system
                // dialog on both ends of every chat connection, repeating on
                // every retry attempt if it wasn't answered fast enough. Hops
                // chat was never designed to rely on OS bonding for anything
                // (no bonded-devices check anywhere else in this file), so
                // there's nothing this trades away by not pairing — the
                // socket is still a private, direct, point-to-point Bluetooth
                // stream between exactly these two devices, just without
                // triggering Android's separate pairing/bonding flow to get
                // it.
                val socket = device.createInsecureRfcommSocketToServiceRecord(SERVICE_UUID)
                pendingSocket = socket
                bluetoothAdapter.cancelDiscovery()

                // See CONNECT_TIMEOUT_MS's comment — connect() itself has
                // no timeout, so this watchdog child coroutine closes the
                // socket out from under it if it hasn't returned in time,
                // which is what actually unblocks it (cancelling this
                // coroutine alone would not — connect() doesn't check for
                // cancellation, it just blocks on the underlying socket).
                val watchdog = launch {
                    delay(CONNECT_TIMEOUT_MS)
                    try { socket.close() } catch (_: IOException) {}
                }
                try {
                    socket.connect()
                } finally {
                    watchdog.cancel()
                }

                pendingSocket = null
                onSocketReady(socket)
                withContext(Dispatchers.Main) { callback(true, null) }
            } catch (e: IOException) {
                pendingSocket = null
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
        // pendingSocket first, and explicitly — this is what actually
        // aborts an in-flight connectToDevice() that's blocked inside
        // .connect() (see its own comment above for why cancelling the
        // scope alone doesn't touch it).
        try { pendingSocket?.close() } catch (_: IOException) {}
        try { clientSocket?.close() } catch (_: IOException) {}
        try { serverSocket?.close() } catch (_: IOException) {}
        pendingSocket = null
        clientSocket = null
        serverSocket = null
    }

    private fun hasPermission() = ActivityCompat.checkSelfPermission(
        MainActivity.context,
        Manifest.permission.BLUETOOTH_CONNECT,
    ) == PackageManager.PERMISSION_GRANTED
}