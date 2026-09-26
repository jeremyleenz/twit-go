package nz.jeremylee.twitgo

import androidx.media3.exoplayer.offline.Download
import nz.jeremylee.twitgo.media.DownloadPhase
import nz.jeremylee.twitgo.media.MediaFailure
import nz.jeremylee.twitgo.media.MediaId
import nz.jeremylee.twitgo.media.MediaItem
import nz.jeremylee.twitgo.media.MediaKind
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
        assertEquals(500L * 1024 * 1024, AndroidDownloadStoragePolicy.MINIMUM_START_FREE_BYTES)
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

    @Test
    fun refreshedEnclosureKeepsTheStableMediaCacheKey() {
        val original = media("https://feed.example/episode.mp3")
        val refreshed = media("https://cdn.example/new-token.mp3")

        assertEquals(original.downloadId(), original.mediaCacheKey())
        assertEquals(original.mediaCacheKey(), refreshed.mediaCacheKey())
    }

    private fun media(url: String) = MediaItem(
        id = MediaId("episode-42", "audio"),
        kind = MediaKind.AUDIO,
        originalEnclosureUrl = url,
        title = "Example",
        showTitle = "Test show",
    )
}
