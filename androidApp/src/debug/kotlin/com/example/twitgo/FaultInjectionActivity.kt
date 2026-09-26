package com.example.twitgo

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.offline.DownloadRequest

/**
 * Debug-only entry point for hardware checks that cannot be automated reliably:
 * user-initiated transfer scheduling, network loss, storage pressure, and system stop.
 * Playback and ordinary downloads use the normal app screen.
 */
@UnstableApi
class FaultInjectionActivity : Activity() {
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 32, 32, 32)
        }
        status = TextView(this)
        root.addView(
            TextView(this).apply {
                text = "TWiT Go hardware fault checks\nStart this activity with media_url and optional media_id extras."
            },
        )
        root.addView(Button(this).apply {
            text = "Start user-initiated transfer"
            setOnClickListener { startUserInitiatedTransfer() }
        })
        root.addView(status)
        setContentView(root)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    private fun startUserInitiatedTransfer() {
        if (Build.VERSION.SDK_INT < 34) {
            status.text = "User-initiated transfer jobs require Android 14 or newer."
            return
        }
        val url = intent.getStringExtra(EXTRA_MEDIA_URL)?.takeIf { Uri.parse(it).scheme == "https" }
        if (url == null) {
            status.text = "Provide an HTTPS media_url intent extra."
            return
        }
        val storage = AndroidDownloadStoragePolicy.storagePreflight(this, MINIMUM_START_FREE_BYTES)
        if (!storage.hasEnoughSpace) {
            status.text = "Need ${MINIMUM_START_FREE_BYTES / MEBIBYTE} MB free before this test."
            return
        }
        val id = intent.getStringExtra(EXTRA_MEDIA_ID)?.ifBlank { null } ?: "fault-${url.hashCode()}"
        val request = DownloadRequest.Builder(id, Uri.parse(url)).build()
        val scheduled = UserInitiatedDownloadScheduler.schedule(this, request, null)
        status.text = if (scheduled) {
            "UIDT scheduled. Apply the selected network, storage, or system-stop fault now."
        } else {
            "UIDT scheduling was rejected by Android."
        }
    }

    private companion object {
        const val EXTRA_MEDIA_URL = "media_url"
        const val EXTRA_MEDIA_ID = "media_id"
        const val MEBIBYTE = 1024L * 1024L
        const val MINIMUM_START_FREE_BYTES = 500L * MEBIBYTE
    }
}
