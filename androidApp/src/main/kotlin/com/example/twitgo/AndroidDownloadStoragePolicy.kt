package com.example.twitgo

import android.content.Context
import android.os.StatFs
import androidx.media3.exoplayer.offline.Download

/**
 * Shared Android storage policy for Media3 download managers.
 *
 * A retained partial remains resumable, but the manager stops it before a full
 * data partition prevents Media3 from persisting its own state.
 */
internal object AndroidDownloadStoragePolicy {
    const val ACTIVE_STORAGE_RESERVE_BYTES = 32L * 1024 * 1024
    const val ACTIVE_STORAGE_STOP_REASON = 2

    fun storagePreflight(context: Context, requiredFreeBytes: Long): StoragePreflight = StoragePreflight(
        availableBytes = StatFs(context.filesDir.path).availableBytes.coerceAtLeast(0),
        requiredFreeBytes = requiredFreeBytes.coerceAtLeast(0),
    )

    fun enforceActiveStorageReserve(
        context: Context,
        download: Download,
        setStopReason: (downloadId: String, reason: Int) -> Unit,
    ) {
        if (download.state != Download.STATE_DOWNLOADING ||
            download.stopReason != Download.STOP_REASON_NONE ||
            storagePreflight(context, ACTIVE_STORAGE_RESERVE_BYTES).hasEnoughSpace
        ) return
        setStopReason(download.request.id, ACTIVE_STORAGE_STOP_REASON)
    }
}

internal data class StoragePreflight(
    val availableBytes: Long,
    val requiredFreeBytes: Long,
) {
    val hasEnoughSpace: Boolean get() = availableBytes >= requiredFreeBytes
}
