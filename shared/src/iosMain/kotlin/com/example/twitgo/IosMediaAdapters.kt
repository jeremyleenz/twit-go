package com.example.twitgo

import com.example.twitgo.media.DownloadController
import com.example.twitgo.media.DownloadNetworkPolicy
import com.example.twitgo.media.DownloadPhase
import com.example.twitgo.media.DownloadSnapshot
import com.example.twitgo.media.DownloadState
import com.example.twitgo.media.MediaFailure
import com.example.twitgo.media.MediaId
import com.example.twitgo.media.MediaItem
import com.example.twitgo.media.MediaKind
import com.example.twitgo.media.PlaybackController
import com.example.twitgo.media.PlaybackPhase
import com.example.twitgo.media.PlaybackSource
import com.example.twitgo.media.PlaybackState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Swift implements native AVFoundation work; these adapters keep the shared contract authoritative. */
interface IosNativeMediaEngine {
    fun loadPlayback(originalEnclosureUrl: String, title: String, startPositionMs: Long)
    fun play()
    fun pause()
    fun seekTo(positionMs: Long)
    fun setSpeed(speed: Float)
    fun stopPlayback()
    fun enqueueDownload(downloadId: String, originalEnclosureUrl: String)
    fun pauseDownload(downloadId: String)
    fun resumeDownload(downloadId: String, originalEnclosureUrl: String)
    fun deleteDownload(downloadId: String)
}

/** Entry points used by the native engine to report actual AVFoundation state to shared Compose. */
object IosMediaRuntime {
    private val adapters = IosMediaAdapters()

    fun install(engine: IosNativeMediaEngine) = adapters.install(engine)

    fun restorePlayback(originalEnclosureUrl: String, title: String, positionMs: Long) =
        adapters.playback.restore(originalEnclosureUrl, title, positionMs)

    fun reportPlaybackReady(positionMs: Long) = adapters.playback.reportReady(positionMs)
    fun reportPlaybackPlaying(positionMs: Long) = adapters.playback.reportPlaying(positionMs)
    fun reportPlaybackPaused(positionMs: Long) = adapters.playback.reportPaused(positionMs)
    fun reportPlaybackFailed() = adapters.playback.reportFailed()
    fun reportDownloadQueued(downloadId: String) = adapters.downloads.reportQueued(downloadId)
    fun reportDownloadProgress(downloadId: String, bytesDownloaded: Long, totalBytes: Long) =
        adapters.downloads.reportProgress(downloadId, bytesDownloaded, totalBytes)
    fun reportDownloadCompleted(downloadId: String, bytesDownloaded: Long) =
        adapters.downloads.reportCompleted(downloadId, bytesDownloaded)
    fun reportDownloadFailed(downloadId: String) = adapters.downloads.reportFailed(downloadId)
    fun reportDownloadPaused(downloadId: String) = adapters.downloads.reportPaused(downloadId)

    internal fun controllers(): IosMediaAdapters = adapters
}

internal class IosMediaAdapters {
    lateinit var engine: IosNativeMediaEngine
        private set
    val playback = IosPlaybackController { engine }
    val downloads = IosDownloadController { engine }

    fun install(engine: IosNativeMediaEngine) {
        this.engine = engine
    }
}

internal class IosPlaybackController(
    private val engine: () -> IosNativeMediaEngine,
) : PlaybackController {
    private val mutableState = MutableStateFlow(PlaybackState())
    override val state: StateFlow<PlaybackState> = mutableState.asStateFlow()

    override suspend fun load(item: MediaItem, startPositionMs: Long) {
        mutableState.value = PlaybackState(
            item = item,
            phase = PlaybackPhase.LOADING,
            source = PlaybackSource.REMOTE,
            positionMs = startPositionMs.coerceAtLeast(0),
        )
        engine().loadPlayback(item.originalEnclosureUrl, item.title, startPositionMs.coerceAtLeast(0))
    }

    override suspend fun play() = engine().play()
    override suspend fun pause() = engine().pause()
    override suspend fun seekTo(positionMs: Long) = engine().seekTo(positionMs.coerceAtLeast(0))
    override suspend fun setSpeed(speed: Float) = engine().setSpeed(speed.coerceIn(0.5f, 3f))

    override suspend fun stop() {
        engine().stopPlayback()
        mutableState.value = PlaybackState()
    }

    fun restore(originalEnclosureUrl: String, title: String, positionMs: Long) {
        mutableState.value = PlaybackState(
            item = restoredItem(originalEnclosureUrl, title),
            phase = PlaybackPhase.READY,
            source = PlaybackSource.REMOTE,
            positionMs = positionMs.coerceAtLeast(0),
        )
    }

    fun reportReady(positionMs: Long) = update(PlaybackPhase.READY, positionMs)
    fun reportPlaying(positionMs: Long) = update(PlaybackPhase.PLAYING, positionMs)
    fun reportPaused(positionMs: Long) = update(PlaybackPhase.PAUSED, positionMs)
    fun reportFailed() {
        mutableState.value = mutableState.value.copy(phase = PlaybackPhase.FAILED, failure = MediaFailure.NETWORK)
    }

    private fun update(phase: PlaybackPhase, positionMs: Long) {
        val prior = mutableState.value
        if (prior.item != null) mutableState.value = prior.copy(phase = phase, positionMs = positionMs.coerceAtLeast(0))
    }

    private fun restoredItem(url: String, title: String) = MediaItem(
        id = MediaId(url, "default"),
        kind = MediaKind.AUDIO,
        originalEnclosureUrl = url,
        title = title,
        showTitle = "TWiT Go",
    )
}

internal class IosDownloadController(
    private val engine: () -> IosNativeMediaEngine,
) : DownloadController {
    private val items = mutableMapOf<String, MediaItem>()
    private val mutableState = MutableStateFlow(DownloadSnapshot(isReconciled = true))
    override val state: StateFlow<DownloadSnapshot> = mutableState.asStateFlow()

    override suspend fun reconcile() = Unit

    override suspend fun enqueue(item: MediaItem, networkPolicy: DownloadNetworkPolicy) {
        val id = item.downloadId()
        items[id] = item
        update(id, DownloadState(item, DownloadPhase.QUEUED))
        engine().enqueueDownload(id, item.originalEnclosureUrl)
    }

    override suspend fun pause(id: MediaId) {
        val downloadId = id.toDownloadId()
        engine().pauseDownload(downloadId)
        items[downloadId]?.let { update(downloadId, DownloadState(it, DownloadPhase.PAUSED)) }
    }

    override suspend fun resume(item: MediaItem, networkPolicy: DownloadNetworkPolicy) {
        val id = item.downloadId()
        items[id] = item
        update(id, DownloadState(item, DownloadPhase.QUEUED))
        engine().resumeDownload(id, item.originalEnclosureUrl)
    }

    override suspend fun cancel(id: MediaId) = delete(id)

    override suspend fun delete(id: MediaId) {
        val downloadId = id.toDownloadId()
        engine().deleteDownload(downloadId)
        items.remove(downloadId)
        mutableState.value = mutableState.value.copy(items = mutableState.value.items - id)
    }

    fun reportQueued(downloadId: String) = setPhase(downloadId, DownloadPhase.QUEUED)
    fun reportPaused(downloadId: String) = setPhase(downloadId, DownloadPhase.PAUSED)
    fun reportProgress(downloadId: String, bytesDownloaded: Long, totalBytes: Long) =
        item(downloadId)?.let { update(downloadId, DownloadState(it, DownloadPhase.DOWNLOADING, bytesDownloaded, totalBytes.takeIf { totalBytes > 0 })) }
    fun reportCompleted(downloadId: String, bytesDownloaded: Long) =
        item(downloadId)?.let { update(downloadId, DownloadState(it, DownloadPhase.COMPLETED, bytesDownloaded, bytesDownloaded)) }
    fun reportFailed(downloadId: String) =
        item(downloadId)?.let { update(downloadId, DownloadState(it, DownloadPhase.FAILED, failure = MediaFailure.NETWORK)) }

    private fun setPhase(downloadId: String, phase: DownloadPhase) =
        item(downloadId)?.let { update(downloadId, DownloadState(it, phase)) }
    private fun item(downloadId: String): MediaItem? = items[downloadId]
    private fun update(downloadId: String, state: DownloadState) {
        mutableState.value = mutableState.value.copy(items = mutableState.value.items + (state.item.id to state))
    }
}

private fun MediaId.toDownloadId(): String =
    "${episodeKey.length}:$episodeKey:${variantKey.length}:$variantKey"

private fun MediaItem.downloadId(): String = id.toDownloadId()
