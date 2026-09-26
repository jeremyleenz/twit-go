package nz.jeremylee.twitgo

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import java.io.File
import java.util.concurrent.Executor

/** Release adapters supplied to the shared UI by [MainActivity]. */
class AndroidMediaAdapters(context: Context) {
    val playback = AndroidPlaybackController(context.applicationContext)
    val downloads = AndroidDownloadController(context.applicationContext)
}

/** Process-wide Media3 objects. DownloadService can recreate the app process independently of UI. */
internal object AndroidMediaStore {
    private var databaseInstance: StandaloneDatabaseProvider? = null
    private var cacheInstance: SimpleCache? = null
    private var managerInstance: DownloadManager? = null
    private var playbackPlayerInstance: ExoPlayer? = null

    @Synchronized
    fun downloadManager(context: Context): DownloadManager = managerInstance ?: DownloadManager(
        context.applicationContext,
        database(context),
        cache(context),
        httpFactory(),
        Executor(Runnable::run),
    ).also { manager ->
        manager.maxParallelDownloads = 1
        manager.addListener(object : DownloadManager.Listener {
            override fun onDownloadChanged(
                downloadManager: DownloadManager,
                download: Download,
                finalException: Exception?,
            ) {
                AndroidDownloadStoragePolicy.enforceActiveStorageReserve(context, download) { id, reason ->
                    downloadManager.setStopReason(id, reason)
                }
            }
        })
        managerInstance = manager
    }

    @Synchronized
    fun cache(context: Context): SimpleCache = cacheInstance ?: SimpleCache(
        File(context.filesDir, "offline-media"),
        NoOpCacheEvictor(),
        database(context),
    ).also { cacheInstance = it }

    fun playbackPlayer(context: Context): ExoPlayer = playbackPlayerInstance ?: ExoPlayer.Builder(context.applicationContext)
        .setMediaSourceFactory(
            DefaultMediaSourceFactory(context).setDataSourceFactory(playbackDataSource(context)),
        )
        .build().also { player ->
            AndroidPlaybackPersistence.restore(context)?.let { saved ->
                player.setMediaItem(saved.item.toPlatformMediaItem(), saved.positionMs)
                player.prepare()
            }
            playbackPlayerInstance = player
        }

    fun playbackDataSource(context: Context): DataSource.Factory = CacheDataSource.Factory()
        .setCache(cache(context))
        .setUpstreamDataSourceFactory(httpFactory())
        // Playback may read completed downloads but never turns streaming into a download.
        .setCacheWriteDataSinkFactory(null)

    fun isOfflineReady(context: Context, id: String): Boolean =
        downloadManager(context).downloadIndex.getDownload(id)?.state == Download.STATE_COMPLETED

    private fun database(context: Context): StandaloneDatabaseProvider =
        databaseInstance ?: StandaloneDatabaseProvider(context.applicationContext).also { databaseInstance = it }

    private fun httpFactory(): DefaultHttpDataSource.Factory =
        DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true)
}

internal fun nz.jeremylee.twitgo.media.MediaItem.downloadId(): String =
    "${id.episodeKey.length}:${id.episodeKey}:${id.variantKey.length}:${id.variantKey}"

internal fun Download.bytesTotalOrNull(): Long? = contentLength.takeIf { it != C.LENGTH_UNSET.toLong() && it >= 0 }

internal fun nz.jeremylee.twitgo.media.MediaItem.toPlatformMediaItem(): MediaItem =
    MediaItem.Builder()
        .setUri(originalEnclosureUrl)
        .setMediaId(downloadId())
        .setCustomCacheKey(mediaCacheKey())
        .build()

/** Cache identity follows feed identity, so a refreshed CDN enclosure reads the completed asset. */
internal fun nz.jeremylee.twitgo.media.MediaItem.mediaCacheKey(): String = downloadId()
