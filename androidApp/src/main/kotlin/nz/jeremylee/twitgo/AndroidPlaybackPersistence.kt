package nz.jeremylee.twitgo

import android.content.Context
import nz.jeremylee.twitgo.media.MediaId
import nz.jeremylee.twitgo.media.MediaItem
import nz.jeremylee.twitgo.media.MediaKind
import org.json.JSONObject

/** Durable playback identity and position for restoring the process-wide player after restart. */
internal object AndroidPlaybackPersistence {
    private const val PREFERENCES = "playback-state"
    private const val SAVED_ITEM = "item"

    fun save(context: Context, item: MediaItem, positionMs: Long) {
        val payload = JSONObject()
            .put("episodeKey", item.id.episodeKey)
            .put("variantKey", item.id.variantKey)
            .put("kind", item.kind.name)
            .put("url", item.originalEnclosureUrl)
            .put("title", item.title)
            .put("showTitle", item.showTitle)
            .put("artworkUrl", item.artworkUrl)
            .put("positionMs", positionMs.coerceAtLeast(0))
        preferences(context).edit().putString(SAVED_ITEM, payload.toString()).apply()
    }

    fun updatePosition(context: Context, positionMs: Long) {
        val saved = restore(context) ?: return
        save(context, saved.item, positionMs)
    }

    fun restore(context: Context): SavedPlayback? {
        val raw = preferences(context).getString(SAVED_ITEM, null) ?: return null
        return runCatching {
            val json = JSONObject(raw)
            SavedPlayback(
                MediaItem(
                    id = MediaId(json.getString("episodeKey"), json.getString("variantKey")),
                    kind = MediaKind.valueOf(json.getString("kind")),
                    originalEnclosureUrl = json.getString("url"),
                    title = json.getString("title"),
                    showTitle = json.getString("showTitle"),
                    artworkUrl = json.optString("artworkUrl").takeIf { it.isNotBlank() && it != "null" },
                ),
                json.optLong("positionMs", 0).coerceAtLeast(0),
            )
        }.getOrNull()
    }

    fun clear(context: Context) {
        preferences(context).edit().remove(SAVED_ITEM).apply()
    }

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
}

internal data class SavedPlayback(val item: MediaItem, val positionMs: Long)
