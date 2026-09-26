package com.example.twitgo

import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/** Media-session owner for the process-wide player, including lock-screen/background playback. */
@UnstableApi
class AndroidPlaybackService : MediaSessionService() {
    private var mediaSession: MediaSession? = null
    private val handler = Handler(Looper.getMainLooper())
    private val persistProgress = object : Runnable {
        override fun run() {
            AndroidPlaybackPersistence.updatePosition(this@AndroidPlaybackService, player.currentPosition)
            handler.postDelayed(this, POSITION_SAVE_INTERVAL_MS)
        }
    }

    private val player get() = AndroidMediaStore.playbackPlayer(this)

    override fun onCreate() {
        super.onCreate()
        mediaSession = MediaSession.Builder(this, player).build()
        handler.post(persistProgress)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onDestroy() {
        handler.removeCallbacks(persistProgress)
        AndroidPlaybackPersistence.updatePosition(this, player.currentPosition)
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }

    private companion object {
        const val POSITION_SAVE_INTERVAL_MS = 1_000L
    }
}
