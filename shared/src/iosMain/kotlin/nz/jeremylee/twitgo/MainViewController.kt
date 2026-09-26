package nz.jeremylee.twitgo

import androidx.compose.ui.window.ComposeUIViewController
import platform.UIKit.UIViewController

fun MainViewController(): UIViewController = ComposeUIViewController {
    IosMediaRuntime.controllers().let { adapters -> App(adapters.playback, adapters.downloads) }
}
