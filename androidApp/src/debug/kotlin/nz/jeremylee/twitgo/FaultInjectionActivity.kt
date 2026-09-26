package nz.jeremylee.twitgo

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.offline.DownloadRequest

/**
 * Debug-only entry point for hardware checks that cannot be automated reliably:
 * user-initiated transfer scheduling, network loss, storage pressure, and system stop.
 * Playback and ordinary downloads use the normal app screen.
 */
@UnstableApi
class FaultInjectionActivity : ComponentActivity() {
    private var status by mutableStateOf("")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    Column(
                        modifier = Modifier.padding(24.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                        horizontalAlignment = Alignment.Start,
                    ) {
                        Text("TWiT Go hardware fault checks", style = MaterialTheme.typography.headlineSmall)
                        Text("Start this activity with media_url and optional media_id extras.")
                        Button(onClick = ::startUserInitiatedTransfer) {
                            Text("Start user-initiated transfer")
                        }
                        if (status.isNotBlank()) Text(status)
                    }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    private fun startUserInitiatedTransfer() {
        if (Build.VERSION.SDK_INT < 34) {
            status = "User-initiated transfer jobs require Android 14 or newer."
            return
        }
        val url = intent.getStringExtra(EXTRA_MEDIA_URL)?.takeIf { Uri.parse(it).scheme == "https" }
        if (url == null) {
            status = "Provide an HTTPS media_url intent extra."
            return
        }
        val storage = AndroidDownloadStoragePolicy.storagePreflight(this, MINIMUM_START_FREE_BYTES)
        if (!storage.hasEnoughSpace) {
            status = "Need ${MINIMUM_START_FREE_BYTES / MEBIBYTE} MB free before this test."
            return
        }
        val id = intent.getStringExtra(EXTRA_MEDIA_ID)?.ifBlank { null } ?: "fault-${url.hashCode()}"
        val request = DownloadRequest.Builder(id, Uri.parse(url)).build()
        val scheduled = UserInitiatedDownloadScheduler.schedule(this, request, null)
        status = if (scheduled) {
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
