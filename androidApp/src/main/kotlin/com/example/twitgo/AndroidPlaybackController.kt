package com.example.twitgo

import android.content.Context
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import com.example.twitgo.media.MediaFailure
import com.example.twitgo.media.PlaybackController
import com.example.twitgo.media.PlaybackPhase
import com.example.twitgo.media.PlaybackSource
import com.example.twitgo.media.PlaybackState
import com.example.twitgo.media.MediaItem
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Native playback implementation. The future player screen owns the PlayerView surface. */
class AndroidPlaybackController(private val context: Context) : PlaybackController {
    private val player = AndroidMediaStore.createPlayer(context)
    private val mutableState = MutableStateFlow(PlaybackState())
    override val state: StateFlow<PlaybackState> = mutableState.asStateFlow()

    init {
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) = publish()
            override fun onIsPlayingChanged(isPlaying: Boolean) = publish()
            override fun onPlayerError(error: PlaybackException) {
                mutableState.value = mutableState.value.copy(
                    phase = PlaybackPhase.FAILED,
                    failure = if (error.errorCodeName.contains("NETWORK")) MediaFailure.NETWORK else MediaFailure.UNKNOWN,
                )
            }
        })
    }

    override suspend fun load(item: MediaItem, startPositionMs: Long) {
        val source = if (AndroidMediaStore.isOfflineReady(context, item.downloadId())) {
            PlaybackSource.OFFLINE
        } else {
            PlaybackSource.REMOTE
        }
        mutableState.value = PlaybackState(item = item, phase = PlaybackPhase.LOADING, source = source)
        player.setMediaItem(item.toPlatformMediaItem(), startPositionMs)
        player.prepare()
        publish()
    }

    override suspend fun play() {
        player.play()
        publish()
    }

    override suspend fun pause() {
        player.pause()
        publish()
    }

    override suspend fun seekTo(positionMs: Long) {
        player.seekTo(positionMs.coerceAtLeast(0))
        publish()
    }

    override suspend fun setSpeed(speed: Float) {
        player.playbackParameters = PlaybackParameters(speed.coerceIn(0.5f, 3f))
        publish()
    }

    override suspend fun stop() {
        player.stop()
        mutableState.value = PlaybackState()
    }

    private fun publish() {
        val prior = mutableState.value
        if (prior.item == null) return
        val phase = when {
            player.isPlaying -> PlaybackPhase.PLAYING
            player.playbackState == Player.STATE_IDLE -> PlaybackPhase.IDLE
            player.playbackState == Player.STATE_BUFFERING -> PlaybackPhase.LOADING
            player.playbackState == Player.STATE_READY -> PlaybackPhase.READY
            player.playbackState == Player.STATE_ENDED -> PlaybackPhase.ENDED
            else -> PlaybackPhase.IDLE
        }
        mutableState.value = prior.copy(
            phase = phase,
            positionMs = player.currentPosition,
            durationMs = player.duration.takeIf { it >= 0 },
            bufferedPositionMs = player.bufferedPosition,
            speed = player.playbackParameters.speed,
            failure = null,
        )
    }
}
