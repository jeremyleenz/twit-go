package nz.jeremylee.twitgo.media

import kotlinx.coroutines.flow.StateFlow

enum class DownloadPhase {
    QUEUED,
    DOWNLOADING,
    PAUSED,
    COMPLETED,
    FAILED,
}

enum class DownloadNetworkPolicy {
    WIFI_ONLY,
    ALLOW_CELLULAR,
}

data class DownloadState(
    val item: MediaItem,
    val phase: DownloadPhase,
    val bytesDownloaded: Long = 0,
    val totalBytes: Long? = null,
    val failure: MediaFailure? = null,
)

/** Until reconciliation finishes, no item is safe to present as playable offline. */
data class DownloadSnapshot(
    val isReconciled: Boolean = false,
    val items: Map<MediaId, DownloadState> = emptyMap(),
)

/**
 * The adapter owns transfer scheduling and storage. COMPLETED is published only after verifying
 * a playable offline asset, including on restart. Android plays through Media3 CacheDataSource;
 * iOS plays a permanent app-owned file. Neither path nor redirect target enters shared state.
 * A changed remote representation must restart safely or fail before it becomes COMPLETED.
 */
interface DownloadController {
    val state: StateFlow<DownloadSnapshot>

    /** Reconcile app records with platform storage before publishing any completed item. */
    suspend fun reconcile()

    suspend fun enqueue(item: MediaItem, networkPolicy: DownloadNetworkPolicy)

    /** Keep partial bytes and position so the user can resume later. */
    suspend fun pause(id: MediaId)

    /** Supply the latest feed URL; the adapter validates any retained partial representation. */
    suspend fun resume(item: MediaItem, networkPolicy: DownloadNetworkPolicy)

    /** Discard a partial transfer and its state. */
    suspend fun cancel(id: MediaId)

    /** Remove a completed offline asset and its state. */
    suspend fun delete(id: MediaId)
}
