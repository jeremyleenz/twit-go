package nz.jeremylee.twitgo

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import nz.jeremylee.twitgo.media.DownloadController
import nz.jeremylee.twitgo.media.DownloadNetworkPolicy
import nz.jeremylee.twitgo.media.DownloadPhase
import nz.jeremylee.twitgo.media.MediaId
import nz.jeremylee.twitgo.media.MediaItem
import nz.jeremylee.twitgo.media.MediaKind
import nz.jeremylee.twitgo.media.PlaybackController
import nz.jeremylee.twitgo.media.PlaybackPhase
import kotlinx.coroutines.launch

@Composable
fun App(
    playbackController: PlaybackController? = null,
    downloadController: DownloadController? = null,
) {
    LaunchedEffect(downloadController) {
        downloadController?.reconcile()
    }
    val activePlaybackController = playbackController
    val activeDownloadController = downloadController
    if (activePlaybackController == null || activeDownloadController == null) {
        UnavailableMediaApp()
        return
    }
    val scope = rememberCoroutineScope()
    val playback by activePlaybackController.state.collectAsStateWithLifecycle()
    val downloads by activeDownloadController.state.collectAsStateWithLifecycle()
    val download = downloads.items[sampleMedia.id]

    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                horizontalAlignment = Alignment.Start,
            ) {
                Text("TWiT Go", style = MaterialTheme.typography.headlineLarge)
                Card {
                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text(sampleMedia.showTitle, style = MaterialTheme.typography.labelLarge)
                        Text(sampleMedia.title, style = MaterialTheme.typography.titleLarge)
                        Text(playback.statusText(), style = MaterialTheme.typography.bodyMedium)
                        Button(onClick = {
                            scope.launch {
                                activePlaybackController.load(sampleMedia)
                                activePlaybackController.play()
                            }
                        }) {
                            Text("Play")
                        }
                        Button(onClick = { scope.launch { activePlaybackController.pause() } }) {
                            Text("Pause")
                        }
                        Text(download.statusText(), style = MaterialTheme.typography.bodyMedium)
                        when (download?.phase) {
                            DownloadPhase.DOWNLOADING, DownloadPhase.QUEUED -> Button(onClick = {
                                scope.launch { activeDownloadController.pause(sampleMedia.id) }
                            }) { Text("Pause download") }
                            DownloadPhase.PAUSED, DownloadPhase.FAILED -> Button(onClick = {
                                scope.launch {
                                    activeDownloadController.resume(sampleMedia, DownloadNetworkPolicy.ALLOW_CELLULAR)
                                }
                            }) { Text("Resume download") }
                            DownloadPhase.COMPLETED -> Button(onClick = {
                                scope.launch {
                                    activePlaybackController.load(sampleMedia)
                                    activePlaybackController.play()
                                }
                            }) { Text("Play downloaded") }
                            null -> Button(onClick = {
                                scope.launch {
                                    activeDownloadController.enqueue(sampleMedia, DownloadNetworkPolicy.ALLOW_CELLULAR)
                                }
                            }) { Text("Download") }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun UnavailableMediaApp() {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("TWiT Go", style = MaterialTheme.typography.headlineLarge)
                Text("Media controls are unavailable on this platform.")
            }
        }
    }
}

private fun nz.jeremylee.twitgo.media.PlaybackState.statusText(): String = when (phase) {
    PlaybackPhase.PLAYING -> "Playing ${positionMs / 1_000}s"
    PlaybackPhase.READY, PlaybackPhase.PAUSED -> "Ready at ${positionMs / 1_000}s"
    PlaybackPhase.LOADING -> "Loading media"
    PlaybackPhase.FAILED -> "Playback failed: ${failure ?: "unknown error"}"
    PlaybackPhase.ENDED -> "Playback finished"
    PlaybackPhase.IDLE -> "Ready to play"
}

private fun nz.jeremylee.twitgo.media.DownloadState?.statusText(): String = when (this?.phase) {
    null -> "Not downloaded"
    DownloadPhase.QUEUED -> "Download queued"
    DownloadPhase.DOWNLOADING -> "Downloading ${bytesDownloaded / (1024 * 1024)} MB"
    DownloadPhase.PAUSED -> "Download paused"
    DownloadPhase.COMPLETED -> "Downloaded and ready offline"
    DownloadPhase.FAILED -> "Download failed: ${failure ?: "unknown error"}"
}

private val sampleMedia = MediaItem(
    id = MediaId(episodeKey = "hoai-c", variantKey = "audio"),
    kind = MediaKind.AUDIO,
    originalEnclosureUrl = "https://pdst.fm/e/pscrb.fm/rss/p/mgln.ai/e/294/cdn.twit.tv/audio/hoai/hoai_C/hoai_C.mp3",
    title = "Hands-On Android C",
    showTitle = "TWiT media sample",
)
