package app.iduanju.ui

import android.net.Uri
import app.iduanju.data.WatchProgress

/**
 * Route strings. Series ids are URI-encoded: TVBox ids (`tvb:<uid>:<vod_id>`) may contain slashes, `?` or whole URLs,
 * which would otherwise split the path. Navigation decodes the argument again.
 */
object Routes {
    fun detail(sid: String): String = "detail/${Uri.encode(sid)}"

    /** [ep] = `HGEpisode.ep` (1-based; the channel number of live lists). */
    fun player(sid: String, ep: Int): String = "player/${Uri.encode(sid)}/$ep"

    /** 继续观看: straight into the player at the recorded episode (live: the last channel). */
    fun resume(p: WatchProgress): String = player(p.seriesId, p.episodeNumber)
}
