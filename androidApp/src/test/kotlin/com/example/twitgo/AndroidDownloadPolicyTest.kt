package com.example.twitgo

import androidx.media3.exoplayer.offline.Download
import com.example.twitgo.media.DownloadPhase
import com.example.twitgo.media.MediaFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidDownloadPolicyTest {
    @Test
    fun storagePreflightRequiresTheConfiguredFreeSpaceReserve() {
        assertFalse(StoragePreflight(availableBytes = 499, requiredFreeBytes = 500).hasEnoughSpace)
        assertTrue(StoragePreflight(availableBytes = 500, requiredFreeBytes = 500).hasEnoughSpace)
    }

    @Test
    fun activeStorageStopMapsToClearSharedFailure() {
        assertEquals(
            DownloadPhase.FAILED,
            downloadPhase(Download.STATE_STOPPED, AndroidDownloadStoragePolicy.ACTIVE_STORAGE_STOP_REASON),
        )
        assertEquals(
            MediaFailure.INSUFFICIENT_STORAGE,
            downloadFailure(Download.STATE_STOPPED, AndroidDownloadStoragePolicy.ACTIVE_STORAGE_STOP_REASON),
        )
    }

    @Test
    fun ordinaryStopRemainsResumableAndNetworkFailureRemainsDistinct() {
        assertEquals(DownloadPhase.PAUSED, downloadPhase(Download.STATE_STOPPED, 1))
        assertNull(downloadFailure(Download.STATE_STOPPED, 1))
        assertEquals(MediaFailure.NETWORK, downloadFailure(Download.STATE_FAILED, 0))
    }
}
