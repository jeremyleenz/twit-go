package nz.jeremylee.twitgo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.PersistableBundle
import androidx.annotation.RequiresApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadRequest

/** Android 14+ hardware-test host using the production Media3 download store. */
@RequiresApi(34)
@UnstableApi
class UserInitiatedDownloadJobService : JobService() {
    private var listener: DownloadManager.Listener? = null

    override fun onStartJob(params: JobParameters): Boolean {
        createChannel()
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("TWiT Go test transfer")
            .setContentText("Downloading media")
            .setOngoing(true)
            .build()
        setNotification(params, NOTIFICATION_ID, notification, JOB_END_NOTIFICATION_POLICY_DETACH)
        val url = params.extras.getString(KEY_URL) ?: return false
        val request = DownloadRequest.Builder(params.extras.getString(KEY_ID) ?: url, android.net.Uri.parse(url)).build()
        val manager = AndroidMediaStore.downloadManager(this)
        val jobListener = object : DownloadManager.Listener {
            override fun onDownloadChanged(downloadManager: DownloadManager, download: Download, finalException: Exception?) {
                if (download.request.id != request.id) return
                if (download.state in terminalStates) {
                    downloadManager.removeListener(this)
                    listener = null
                    jobFinished(params, download.state == Download.STATE_FAILED)
                }
            }
        }
        listener = jobListener
        manager.addListener(jobListener)
        // A DownloadManager starts paused when it is created outside DownloadService.
        // The UIDT job owns the explicit user action, so resume it here.
        manager.resumeDownloads()
        manager.addDownload(request)
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        listener?.let(AndroidMediaStore.downloadManager(this)::removeListener)
        listener = null
        return true
    }

    private fun createChannel() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "TWiT Go downloads", NotificationManager.IMPORTANCE_LOW),
        )
    }

    private companion object {
        const val CHANNEL_ID = "media_probe_uidt"
        const val NOTIFICATION_ID = 43
        const val KEY_URL = "url"
        const val KEY_ID = "id"
        val terminalStates = setOf(Download.STATE_COMPLETED, Download.STATE_FAILED, Download.STATE_STOPPED)
    }
}

@RequiresApi(34)
@UnstableApi
internal object UserInitiatedDownloadScheduler {
    fun schedule(context: Context, request: DownloadRequest, estimatedBytes: Long?): Boolean = runCatching {
        val extras = PersistableBundle().apply {
            putString("url", request.uri.toString())
            putString("id", request.id)
        }
        val network = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val job = JobInfo.Builder(jobId(request.id), ComponentName(context, UserInitiatedDownloadJobService::class.java))
            .setUserInitiated(true)
            .setRequiredNetwork(network)
            .setEstimatedNetworkBytes(estimatedBytes ?: JobInfo.NETWORK_BYTES_UNKNOWN.toLong(), 0)
            .setExtras(extras)
            .build()
        val scheduler = context.getSystemService(JobScheduler::class.java)
        scheduler.schedule(job) == JobScheduler.RESULT_SUCCESS
    }.getOrDefault(false)

    private fun jobId(id: String): Int = 6_100 + (id.hashCode() and 0x7fff) % 1_000
}
