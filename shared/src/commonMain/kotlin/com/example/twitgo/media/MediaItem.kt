package com.example.twitgo.media

/** Stable app identity assigned by feed parsing, independent of every media URL. */
data class MediaId(
    val episodeKey: String,
    val variantKey: String,
)

enum class MediaKind {
    AUDIO,
    VIDEO,
}

/** The source can change on feed refresh while [id] stays the same. */
data class MediaItem(
    val id: MediaId,
    val kind: MediaKind,
    val originalEnclosureUrl: String,
    val title: String,
    val showTitle: String,
    val artworkUrl: String? = null,
)

/** Categories safe for shared UI; adapters retain native errors for diagnostics. */
enum class MediaFailure {
    NETWORK,
    UNAVAILABLE,
    UNSUPPORTED_FORMAT,
    INSUFFICIENT_STORAGE,
    INVALID_DOWNLOAD,
    UNKNOWN,
}
