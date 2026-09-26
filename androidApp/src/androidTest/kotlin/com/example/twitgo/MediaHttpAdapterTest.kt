package com.example.twitgo

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

/** Local HTTP fixtures exercise the same redirect-capable source used by the debug download store. */
@RunWith(AndroidJUnit4::class)
class MediaHttpAdapterTest {
    private val sourceFactory = DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true)
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun redirectIsResolvedAgainAndExpiredTargetFails() = FixtureServer().use { server ->
        val first = read(server.originalUrl)
        assertArrayEquals("version-one".toByteArray(), first.bytes)
        assertEquals(11L, first.reportedLength)

        server.expired = true
        val error = assertThrows(HttpDataSource.InvalidResponseCodeException::class.java) {
            read(server.originalUrl)
        }
        assertEquals(403, error.responseCode)
        assertEquals(2, server.originalRequests)
    }

    @Test
    fun resumedRangeReportsChangedRepresentationLength() = FixtureServer().use { server ->
        val first = read(server.originalUrl, position = 0, maxBytes = 5)
        assertArrayEquals("versi".toByteArray(), first.bytes)
        assertEquals(11L, first.reportedLength)

        server.body = "replacement-media".toByteArray()
        val resumed = read(server.originalUrl, position = 5)
        assertArrayEquals("cement-media".toByteArray(), resumed.bytes)
        assertEquals(server.body.size.toLong() - 5, resumed.reportedLength)
        assertEquals(server.body.size, resumed.observedTotal)
    }

    @Test
    fun partialCacheRetainsOldBytesAfterValidatorAndLengthChange() = FixtureServer().use { server ->
        val cacheDirectory = File(context.cacheDir, "changed-representation-${System.nanoTime()}")
        val databaseProvider = StandaloneDatabaseProvider(context)
        val cache = SimpleCache(cacheDirectory, NoOpCacheEvictor(), databaseProvider)
        try {
            val cachedSourceFactory = CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(sourceFactory)

            val first = read(cachedSourceFactory, server.originalUrl, position = 0, maxBytes = 5)
            assertArrayEquals("versi".toByteArray(), first.bytes)

            server.body = "replacement-media".toByteArray()
            server.etag = "\"two\""
            val resumed = read(cachedSourceFactory, server.originalUrl)

            assertArrayEquals("versi".toByteArray(), resumed.bytes.copyOfRange(0, 5))
            assertFalse(resumed.bytes.contentEquals(server.body))
        } finally {
            cache.release()
            SimpleCache.delete(cacheDirectory, databaseProvider)
        }
    }

    private fun read(url: String, position: Long = 0, maxBytes: Int = Int.MAX_VALUE): Response {
        return read(sourceFactory, url, position, maxBytes)
    }

    private fun read(
        factory: androidx.media3.datasource.DataSource.Factory,
        url: String,
        position: Long = 0,
        maxBytes: Int = Int.MAX_VALUE,
    ): Response {
        val source = factory.createDataSource()
        val spec = DataSpec.Builder().setUri(Uri.parse(url)).setPosition(position).build()
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(1024)
        try {
            val length = source.open(spec)
            val headers = source.responseHeaders
            val total = headers["Content-Range"]?.firstOrNull()?.substringAfterLast('/')?.toIntOrNull()
            while (output.size() < maxBytes) {
                val count = source.read(buffer, 0, minOf(buffer.size, maxBytes - output.size()))
                if (count == C.RESULT_END_OF_INPUT) break
                output.write(buffer, 0, count)
            }
            return Response(output.toByteArray(), length, total)
        } finally {
            source.close()
        }
    }

    private data class Response(val bytes: ByteArray, val reportedLength: Long, val observedTotal: Int?)

    private class FixtureServer : Closeable {
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val worker = Thread({ serve() }, "media-http-fixture").apply { start() }
        val originalUrl = "http://127.0.0.1:${socket.localPort}/original"
        @Volatile var body = "version-one".toByteArray()
        @Volatile var etag = "\"one\""
        @Volatile var expired = false
        @Volatile var originalRequests = 0

        private fun serve() {
            while (!socket.isClosed) {
                val client = try { socket.accept() } catch (_: SocketException) { break }
                client.use { connection ->
                    connection.soTimeout = 5_000
                    val input = connection.getInputStream().bufferedReader(StandardCharsets.US_ASCII)
                    val path = input.readLine()?.split(' ')?.getOrNull(1) ?: return@use
                    var rangeStart: Int? = null
                    while (true) {
                        val header = input.readLine() ?: break
                        if (header.isEmpty()) break
                        if (header.startsWith("Range:", ignoreCase = true)) {
                            rangeStart = header.substringAfter("bytes=").substringBefore('-').toIntOrNull()
                        }
                    }
                    val output = connection.getOutputStream()
                    when (path) {
                        "/original" -> {
                            originalRequests++
                            output.write("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:${socket.localPort}/hop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                        }
                        "/hop" -> output.write("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:${socket.localPort}/target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                        "/target" -> {
                            if (expired) {
                                output.write("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                            } else {
                                val current = body
                                val start = rangeStart ?: 0
                                val payload = current.copyOfRange(start, current.size)
                                val status = if (rangeStart == null) "200 OK" else "206 Partial Content"
                                val range = if (rangeStart == null) "" else "Content-Range: bytes $start-${current.size - 1}/${current.size}\r\n"
                                output.write("HTTP/1.1 $status\r\nContent-Length: ${payload.size}\r\n$range".toByteArray())
                                output.write("ETag: $etag\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n".toByteArray())
                                output.write(payload)
                            }
                        }
                    }
                    output.flush()
                }
            }
        }

        override fun close() {
            socket.close()
            worker.join(5_000)
        }
    }
}
