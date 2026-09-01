package com.example.client

import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

// Quick Settings tile for Silent SOS — see MainActivity's
// "com.example.client/sos_tile" MethodChannel and
// lib/services/sos_service.dart for the Dart-side half of this feature.
//
// Tapping the tile does NOT fire Emergency Flare directly from here — it
// launches/foregrounds MainActivity with ACTION_TRIGGER_SOS, which forwards
// to Dart and opens the exact same confirm-then-reason dialog the in-app
// Emergency Flare button already uses (see hops_app.dart's
// _pendingFlareShortcut, which the existing "Emergency Flare" home-screen
// shortcut also reuses). Firing a real alert with zero confirmation from a
// single accidental tap would risk exactly the false alarm this app's own
// Terms (section 6) explicitly ask users not to trigger.
//
// Not testable from this environment (needs a real device with a Quick
// Settings panel) — verify on-device that the tile appears after
// requestAddTileService and that tapping it actually brings Hops to the
// flare confirm dialog.
class HopsSosTileService : TileService() {

    companion object {
        const val ACTION_TRIGGER_SOS = "com.example.client.ACTION_TRIGGER_SOS"
    }

    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply {
            state = Tile.STATE_ACTIVE
            label = "Hops SOS"
            contentDescription = "Open Hops to send an Emergency Flare"
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).apply {
            action = ACTION_TRIGGER_SOS
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        @Suppress("DEPRECATION") // Intent-based overload; the PendingIntent
        // replacement only exists on API 34+, and this one still works
        // across every API level TileService itself supports (24+).
        startActivityAndCollapse(intent)
    }
}
