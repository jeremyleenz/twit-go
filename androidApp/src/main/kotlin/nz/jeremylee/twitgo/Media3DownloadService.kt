package nz.jeremylee.twitgo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadService
import androidx.media3.exoplayer.scheduler.Scheduler
import androidx.media3.exoplayer.workmanager.WorkManagerScheduler

@UnstableApi
class Media3DownloadService : DownloadService(NOTIFICATION_ID) {
    override fun onCreate() {
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "TWiT Go downloads", NotificationManager.IMPORTANCE_LOW),
            )
        }
        super.onCreate()
    }

    override fun getDownloadManager(): DownloadManager = AndroidMediaStore.downloadManager(this)

    override fun getScheduler(): Scheduler = WorkManagerScheduler(this, "twit-go-downloads")

    override fun getForegroundNotification(downloads: MutableList<Download>, notMetRequirements: Int): Notification {
        downloads.firstOrNull { it.state == Download.STATE_DOWNLOADING }
            ?.let { download ->
                AndroidDownloadStoragePolicy.enforceActiveStorageReserve(this, download) { id, reason ->
                    AndroidMediaStore.downloadManager(this).setStopReason(id, reason)
                }
            }
        val percent = downloads.firstOrNull()?.percentDownloaded?.takeIf { it >= 0 }?.toInt()
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("TWiT Go download")
            .setContentText(if (percent == null) "Downloading media" else "Downloading $percent%")
            .setProgress(100, percent ?: 0, percent == null)
            .setOngoing(true)
            .build()
    }

    private companion object {
        const val CHANNEL_ID = "twit_go_downloads"
        const val NOTIFICATION_ID = 71
    }
}
