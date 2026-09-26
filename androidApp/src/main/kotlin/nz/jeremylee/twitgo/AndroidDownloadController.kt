package nz.jeremylee.twitgo

import android.content.Context
import android.net.Uri
import android.util.Base64
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadRequest
import androidx.media3.exoplayer.offline.DownloadService
import androidx.media3.exoplayer.scheduler.Requirements
import nz.jeremylee.twitgo.media.DownloadController
import nz.jeremylee.twitgo.media.DownloadNetworkPolicy
import nz.jeremylee.twitgo.media.DownloadPhase
import nz.jeremylee.twitgo.media.DownloadSnapshot
import nz.jeremylee.twitgo.media.DownloadState
import nz.jeremylee.twitgo.media.MediaFailure
import nz.jeremylee.twitgo.media.MediaId
import nz.jeremylee.twitgo.media.MediaItem
import nz.jeremylee.twitgo.media.MediaKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

@UnstableApi
class AndroidDownloadController(private val context: Context) : DownloadController {
    private val manager = AndroidMediaStore.downloadManager(context)
    private val records = DownloadRecords(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutableState = MutableStateFlow(DownloadSnapshot())
    private val admissionFailures = mutableMapOf<MediaId, DownloadState>()
    override val state: StateFlow<DownloadSnapshot> = mutableState.asStateFlow()

    init {
        manager.addListener(object : DownloadManager.Listener {
            override fun onDownloadChanged(
                downloadManager: DownloadManager,
                download: Download,
                finalException: Exception?,
            ) {
                scope.launch { refresh() }
            }
        })
    }

    override suspend fun reconcile() = refresh()

    override suspend fun enqueue(item: MediaItem, networkPolicy: DownloadNetworkPolicy) {
        if (!admitTransfer(item)) return
        records.put(item, RepresentationProbe.observe(item.originalEnclosureUrl))
        setNetworkPolicy(networkPolicy)
        DownloadService.sendAddDownload(
            context,
            Media3DownloadService::class.java,
            item.toDownloadRequest(),
            false,
        )
        refresh()
    }

    override suspend fun pause(id: MediaId) {
        DownloadService.sendSetStopReason(
            context,
            Media3DownloadService::class.java,
            id.toDownloadId(),
            PAUSED_BY_USER,
            false,
        )
        refresh()
    }

    override suspend fun resume(item: MediaItem, networkPolicy: DownloadNetworkPolicy) {
        val id = item.downloadId()
        val existing = manager.downloadIndex.getDownload(id)
        if (existing?.state != Download.STATE_COMPLETED && !admitTransfer(item)) return
        val stored = records.get(id)
        val freshRepresentation = RepresentationProbe.observe(item.originalEnclosureUrl)
        admissionFailures.remove(item.id)
        setNetworkPolicy(networkPolicy)
        if (existing == null) {
            records.put(item, freshRepresentation)
            DownloadService.sendAddDownload(
                context,
                Media3DownloadService::class.java,
                item.toDownloadRequest(),
                false,
            )
        } else if (existing.state != Download.STATE_COMPLETED &&
            stored?.canSafelyResume(item, freshRepresentation) != true
        ) {
            // Never join a retained range to a feed refresh or an unvalidated representation.
            DownloadService.sendRemoveDownload(context, Media3DownloadService::class.java, id, false)
            records.put(item, freshRepresentation)
            DownloadService.sendAddDownload(
                context,
                Media3DownloadService::class.java,
                item.toDownloadRequest(),
                false,
            )
        } else {
            records.put(item, freshRepresentation)
            DownloadService.sendSetStopReason(
                context,
                Media3DownloadService::class.java,
                id,
                Download.STOP_REASON_NONE,
                false,
            )
        }
        refresh()
    }

    override suspend fun cancel(id: MediaId) = remove(id)

    override suspend fun delete(id: MediaId) = remove(id)

    private suspend fun remove(id: MediaId) {
        DownloadService.sendRemoveDownload(context, Media3DownloadService::class.java, id.toDownloadId(), false)
        records.remove(id.toDownloadId())
        admissionFailures.remove(id)
        refresh()
    }

    private fun setNetworkPolicy(policy: DownloadNetworkPolicy) {
        val flags = if (policy == DownloadNetworkPolicy.WIFI_ONLY) {
            Requirements.NETWORK_UNMETERED
        } else {
            Requirements.NETWORK
        }
        DownloadService.sendSetRequirements(
            context,
            Media3DownloadService::class.java,
            Requirements(flags),
            false,
        )
    }

    /** Apply the 500 MB reserve to every path that can start a network transfer. */
    private suspend fun admitTransfer(item: MediaItem): Boolean {
        val storage = AndroidDownloadStoragePolicy.storagePreflight(
            context,
            AndroidDownloadStoragePolicy.MINIMUM_START_FREE_BYTES,
        )
        if (storage.hasEnoughSpace) {
            admissionFailures.remove(item.id)
            return true
        }
        admissionFailures[item.id] = DownloadState(
            item = item,
            phase = DownloadPhase.FAILED,
            failure = MediaFailure.INSUFFICIENT_STORAGE,
        )
        refresh()
        return false
    }

    private suspend fun refresh() = withContext(Dispatchers.IO) {
        mutableState.value = DownloadSnapshot(isReconciled = false)
        val entries = admissionFailures.toMutableMap()
        entries.putAll(records.all().mapNotNull { record ->
            val item = record.item
            val download = manager.downloadIndex.getDownload(item.downloadId()) ?: return@mapNotNull null
            item.id to download.toSharedState(item)
        }.toMap())
        mutableState.value = DownloadSnapshot(isReconciled = true, items = entries)
    }

    private fun Download.toSharedState(item: MediaItem): DownloadState = DownloadState(
        item = item,
        phase = downloadPhase(state, stopReason),
        bytesDownloaded = bytesDownloaded,
        totalBytes = bytesTotalOrNull(),
        failure = downloadFailure(state, stopReason),
    )

    private companion object {
        const val PAUSED_BY_USER = 1
    }
}

internal fun downloadPhase(state: Int, stopReason: Int): DownloadPhase = when (state) {
    Download.STATE_QUEUED -> DownloadPhase.QUEUED
    Download.STATE_DOWNLOADING, Download.STATE_RESTARTING -> DownloadPhase.DOWNLOADING
    Download.STATE_STOPPED -> if (stopReason == AndroidDownloadStoragePolicy.ACTIVE_STORAGE_STOP_REASON) {
        DownloadPhase.FAILED
    } else {
        DownloadPhase.PAUSED
    }
    Download.STATE_COMPLETED -> DownloadPhase.COMPLETED
    else -> DownloadPhase.FAILED
}

internal fun downloadFailure(state: Int, stopReason: Int): MediaFailure? = when {
    state == Download.STATE_STOPPED && stopReason == AndroidDownloadStoragePolicy.ACTIVE_STORAGE_STOP_REASON ->
        MediaFailure.INSUFFICIENT_STORAGE
    state == Download.STATE_FAILED -> MediaFailure.NETWORK
    else -> null
}

private fun MediaId.toDownloadId(): String =
    "${episodeKey.length}:${episodeKey}:${variantKey.length}:${variantKey}"

private fun MediaItem.toDownloadRequest(): DownloadRequest = DownloadRequest.Builder(
    downloadId(),
    Uri.parse(originalEnclosureUrl),
).setCustomCacheKey(mediaCacheKey()).build()

/** Stores the shared identity and feed URL, never a resolved redirect target or cache path. */
private data class DownloadRecord(
    val item: MediaItem,
    val representation: RepresentationObservation?,
) {
    fun canSafelyResume(latestItem: MediaItem, latest: RepresentationObservation?): Boolean =
        item.originalEnclosureUrl == latestItem.originalEnclosureUrl &&
            representation?.etag != null &&
            representation.etag == latest?.etag &&
            representation.length == latest.length
}

private data class RepresentationObservation(val etag: String?, val length: Long?)

private object RepresentationProbe {
    suspend fun observe(url: String): RepresentationObservation? = withContext(Dispatchers.IO) {
        runCatching {
            val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = true
                requestMethod = "GET"
                setRequestProperty("Range", "bytes=0-0")
                connectTimeout = 10_000
                readTimeout = 10_000
            }
            try {
                if (connection.responseCode !in 200..299) return@runCatching null
                val etag = connection.getHeaderField("ETag")?.takeIf { it.isNotBlank() }
                val length = connection.getHeaderField("Content-Range")
                    ?.substringAfterLast('/', missingDelimiterValue = "")
                    ?.toLongOrNull()
                    ?: connection.contentLengthLong.takeIf { it >= 0 }
                RepresentationObservation(etag, length)
            } finally {
                connection.disconnect()
            }
        }.getOrNull()
    }
}

private class DownloadRecords(context: Context) {
    private val preferences = context.getSharedPreferences("offline-media-records", Context.MODE_PRIVATE)

    fun put(item: MediaItem, representation: RepresentationObservation?) {
        val json = JSONObject()
            .put("episodeKey", item.id.episodeKey)
            .put("variantKey", item.id.variantKey)
            .put("kind", item.kind.name)
            .put("url", item.originalEnclosureUrl)
            .put("title", item.title)
            .put("showTitle", item.showTitle)
            .put("artworkUrl", item.artworkUrl)
            .put("etag", representation?.etag)
            .put("length", representation?.length)
        preferences.edit().putString(key(item.downloadId()), json.toString()).apply()
    }

    fun get(downloadId: String): DownloadRecord? = preferences.getString(key(downloadId), null)?.let(::decode)

    fun all(): List<DownloadRecord> = preferences.all.values.mapNotNull { value ->
        (value as? String)?.let(::decode)
    }

    fun remove(downloadId: String) {
        preferences.edit().remove(key(downloadId)).apply()
    }

    private fun decode(value: String): DownloadRecord? = runCatching {
        JSONObject(value).let { json ->
            val item = MediaItem(
                id = MediaId(json.getString("episodeKey"), json.getString("variantKey")),
                kind = MediaKind.valueOf(json.getString("kind")),
                originalEnclosureUrl = json.getString("url"),
                title = json.getString("title"),
                showTitle = json.getString("showTitle"),
                artworkUrl = json.optString("artworkUrl").takeIf { it.isNotBlank() && it != "null" },
            )
            DownloadRecord(
                item,
                RepresentationObservation(
                    json.optString("etag").takeIf { it.isNotBlank() && it != "null" },
                    json.optLong("length", -1).takeIf { it >= 0 },
                ),
            )
        }
    }.getOrNull()

    private fun key(downloadId: String): String = Base64.encodeToString(
        downloadId.toByteArray(Charsets.UTF_8),
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
    )
}
