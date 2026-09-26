package com.example.twitgo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.core.view.WindowCompat

class MainActivity : ComponentActivity() {
    private val mediaAdapters by lazy { AndroidMediaAdapters(applicationContext) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = true
            isAppearanceLightNavigationBars = true
        }
        setContent {
            App(
                playbackController = mediaAdapters.playback,
                downloadController = mediaAdapters.downloads,
            )
        }
    }
}
