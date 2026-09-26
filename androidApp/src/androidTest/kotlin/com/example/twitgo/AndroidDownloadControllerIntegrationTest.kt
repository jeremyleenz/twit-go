package com.example.twitgo

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.twitgo.media.DownloadNetworkPolicy
import com.example.twitgo.media.DownloadPhase
import com.example.twitgo.media.MediaId
import com.example.twitgo.media.MediaItem
import com.example.twitgo.media.MediaKind
import java.io.Closeable
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the normal controller, persistent Media3 store, and DownloadService together. */
@RunWith(AndroidJUnit4::class)
class AndroidDownloadControllerIntegrationTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun productionControllerCompletesAFixtureDownload() = FixtureServer().use { server ->
        val item = MediaItem(
            id = MediaId("controller-fixture-${System.nanoTime()}", "audio"),
            kind = MediaKind.AUDIO,
            originalEnclosureUrl = server.url,
            title = "Controller fixture",
            showTitle = "Instrumentation",
        )
        val controller = AndroidDownloadController(context)
        runBlocking {
            try {
                controller.enqueue(item, DownloadNetworkPolicy.ALLOW_CELLULAR)
                repeat(100) {
                    controller.reconcile()
                    val state = controller.state.value.items[item.id]
                    if (state?.phase == DownloadPhase.COMPLETED) return@runBlocking
                    delay(100)
                }
                fail("Production download did not complete within 10 seconds: ${controller.state.value.items[item.id]}")
            } finally {
                controller.delete(item.id)
            }
        }
    }

    private class FixtureServer : Closeable {
        private val body = "production-media-fixture".toByteArray()
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val worker = Thread({ serve() }, "production-download-fixture").apply { start() }
        val url = "http://127.0.0.1:${socket.localPort}/fixture.mp3"

        private fun serve() {
            while (!socket.isClosed) {
                val client = try { socket.accept() } catch (_: SocketException) { break }
                client.use { connection ->
                    connection.soTimeout = 5_000
                    val input = connection.getInputStream().bufferedReader()
                    if (input.readLine() == null) return@use
                    while (input.readLine()?.isNotEmpty() == true) {
                        // Consume request headers.
                    }
                    connection.getOutputStream().use { output ->
                        output.write(
                            (
                                "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n" +
                                    "Content-Length: ${body.size}\r\nETag: \"fixture\"\r\n" +
                                    "Connection: close\r\n\r\n"
                            ).toByteArray(),
                        )
                        output.write(body)
                        output.flush()
                    }
                }
            }
        }

        override fun close() {
            socket.close()
            worker.join(5_000)
        }
    }
}
