package com.example.twitgo.media

import kotlinx.coroutines.flow.StateFlow

enum class PlaybackPhase {
    IDLE,
    LOADING,
    READY,
    PLAYING,
    PAUSED,
    ENDED,
    FAILED,
}

enum class PlaybackSource {
    REMOTE,
    OFFLINE,
}

data class PlaybackState(
    val item: MediaItem? = null,
    val phase: PlaybackPhase = PlaybackPhase.IDLE,
    val source: PlaybackSource? = null,
    val positionMs: Long = 0,
    val durationMs: Long? = null,
    val bufferedPositionMs: Long? = null,
    val speed: Float = 1f,
    val failure: MediaFailure? = null,
)

/**
 * State reflects native controls as well as app commands. Position is playback time, not bytes.
 * [load] prepares paused. The adapter can choose a verified offline asset or start a new request
 * from [MediaItem.originalEnclosureUrl], resolving redirects again for that request.
 */
interface PlaybackController {
    val state: StateFlow<PlaybackState>

    suspend fun load(item: MediaItem, startPositionMs: Long = 0)
    suspend fun play()
    suspend fun pause()
    suspend fun seekTo(positionMs: Long)
    suspend fun setSpeed(speed: Float)
    suspend fun stop()
}
