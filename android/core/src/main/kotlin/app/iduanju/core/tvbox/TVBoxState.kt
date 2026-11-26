package app.iduanju.core.tvbox

import app.iduanju.core.util.Bytes
import app.iduanju.core.util.J
import app.iduanju.core.util.ProviderException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

/** Downloads and decodes a config address (contract §3): never touches the sites inside it. */
class ConfigLoader(private val net: TVBoxNet) {
    data class Loaded(val parsed: ParsedConfig, val text: String, val url: String)

    /** [raw] may carry `;pk;key`. [allowLan] = the user's LAN switch; a private config address implies it for itself. */
    suspend fun load(raw: String, allowLan: Boolean, doh: TVBoxDoh? = null): Loaded = withContext(Dispatchers.Default) {
        val (address, key) = TVBoxDecoder.splitKey(raw)
        val url = normalize(address)
        val scope = net.Scope(NetRules(doh = doh, allowPrivate = allowLan || TVBoxNet.isPrivateAddress(url)))
        val r = try { scope.fetch(NetRequest(url, timeoutMs = TIMEOUT_MS, maxBytes = NetRequest.MAX_BYTES)) } catch (e: IOException) { throw ProviderException.upstream(SpiderErrors.text(e)) }
        if (!r.ok) throw ProviderException.upstream("HTTP ${r.code} · ${TVBoxUrl.host(url)}")
        if (r.body.isEmpty()) throw ProviderException.upstream("配置地址没有返回内容")
        val text = TVBoxDecoder.decode(r.body, key)
        Loaded(TVBoxConfig.parse(text, url), text, raw.trim())
    }

    companion object {
        const val TIMEOUT_MS = 12_000L

        fun normalize(raw: String): String {
            val t = raw.trim()
            return when {
                t.startsWith("clan://", true) || t.startsWith("file://", true) || TVBoxUrl.isHttp(t) -> t
                t.contains("://") -> throw ProviderException.invalid("不支持的地址类型")
                t.contains('.') && !t.contains(' ') && !t.contains('\n') -> "http://$t"
                else -> throw ProviderException.invalid("请输入配置地址")
            }
        }
    }
}

enum class Trust { Ask, Trusted, Denied }

/** One imported config as persisted; its decoded text lives in its own file. */
data class RepoRecord(
    val id: String, val name: String, val url: String, val depot: String = "", val trust: Trust = Trust.Ask, val updatedAt: Long = 0,
    /** Disabled site / live uids. */
    val disabled: Set<String> = emptySet(),
    /** User-chosen default parse. */
    val parse: String = "",
    /** Migrated from store v1: uid → normalised api, until the first refresh maps them onto real site keys. */
    val legacy: Map<String, String> = emptyMap(),
) {
    /** Base for relative addresses. */
    val base: String get() = TVBoxDecoder.splitKey(url).first

    fun toJSON(): JSONObject = JSONObject().put("id", id).put("name", name).put("url", url).put("depot", depot).put("trust", trust.name).put("updatedAt", updatedAt)
        .put("disabled", JSONArray(disabled.toList())).put("parse", parse).apply { if (legacy.isNotEmpty()) put("legacy", JSONObject(legacy as Map<*, *>)) }

    companion object {
        fun id(url: String): String = Bytes.hex(Bytes.md5(url.trim())).take(12)
        fun fromJSON(o: JSONObject): RepoRecord? = J.str(o.opt("id")).takeIf { it.isNotEmpty() }?.let { id ->
            RepoRecord(id, J.str(o.opt("name")).ifEmpty { "TVBox 配置" }, J.str(o.opt("url")), J.str(o.opt("depot")), Trust.entries.firstOrNull { it.name == J.str(o.opt("trust")) } ?: Trust.Ask,
                J.int64(o.opt("updatedAt")), J.arr(o.opt("disabled")).map { J.str(it) }.toSet(), J.str(o.opt("parse")), J.dict(o.opt("legacy")).let { l -> l.keys().asSequence().associateWith { J.str(l.opt(it)) } })
        }
    }
}

data class DepotRecord(val id: String, val name: String, val url: String, val entries: List<TVBoxDepotEntry>) {
    fun toJSON(): JSONObject = JSONObject().put("id", id).put("name", name).put("url", url).put("entries", JSONArray(entries.map { JSONObject().put("name", it.name).put("url", it.url) }))

    companion object {
        fun fromJSON(o: JSONObject): DepotRecord? = J.str(o.opt("id")).takeIf { it.isNotEmpty() }?.let { id ->
            DepotRecord(id, J.str(o.opt("name")), J.str(o.opt("url")), J.arr(o.opt("entries")).mapNotNull { e -> (e as? JSONObject)?.let { TVBoxDepotEntry(J.str(it.opt("name")), J.str(it.opt("url"))) } })
        }
    }
}

/** A watch record of store v1, on its way into the app's history. */
data class LegacyWatch(val sid: String, val title: String, val cover: String, val episodeIndex: Int, val positionMs: Long, val durationMs: Long, val updatedAt: Long)

/** Persistent TVBox state (`tvbox_store_v2.json`). Immutable: the store swaps whole snapshots and writes them in the background. */
data class TVBoxState(
    val repos: List<RepoRecord> = emptyList(), val depots: List<DepotRecord> = emptyList(), val active: String = "",
    val lastSite: Map<String, String> = emptyMap(), val lastLive: Map<String, String> = emptyMap(), val favorites: List<String> = emptyList(),
    /** Live uid → names of password groups the user opened. */
    val unlocked: Map<String, Set<String>> = emptyMap(), val aliases: Map<String, String> = emptyMap(),
    val allowLan: Boolean = false, val doh: String = "", val bridgeOn: Boolean = false, val bridgeCode: String = "", val latency: Map<String, Int> = emptyMap(),
) {
    fun toJSON(): JSONObject = JSONObject().put("v", VERSION).put("repos", JSONArray(repos.map { it.toJSON() })).put("depots", JSONArray(depots.map { it.toJSON() })).put("active", active)
        .put("lastSite", JSONObject(lastSite as Map<*, *>)).put("lastLive", JSONObject(lastLive as Map<*, *>)).put("favorites", JSONArray(favorites))
        .put("unlocked", JSONObject().apply { unlocked.forEach { (k, v) -> put(k, JSONArray(v.toList())) } }).put("aliases", JSONObject(aliases as Map<*, *>))
        .put("allowLan", allowLan).put("doh", doh).put("bridgeOn", bridgeOn).put("bridgeCode", bridgeCode).put("latency", JSONObject(latency as Map<*, *>))

    companion object {
        const val VERSION = 2

        fun fromJSON(o: JSONObject): TVBoxState {
            fun map(k: String) = J.dict(o.opt(k)).let { m -> m.keys().asSequence().associateWith { J.str(m.opt(it)) } }
            return TVBoxState(
                J.arr(o.opt("repos")).mapNotNull { (it as? JSONObject)?.let(RepoRecord::fromJSON) }, J.arr(o.opt("depots")).mapNotNull { (it as? JSONObject)?.let(DepotRecord::fromJSON) }, J.str(o.opt("active")),
                map("lastSite"), map("lastLive"), J.arr(o.opt("favorites")).map { J.str(it) }.filter { it.isNotEmpty() },
                J.dict(o.opt("unlocked")).let { m -> m.keys().asSequence().associateWith { k -> J.arr(m.opt(k)).map { J.str(it) }.toSet() } }, map("aliases"),
                J.bool(o.opt("allowLan")), J.str(o.opt("doh")), J.bool(o.opt("bridgeOn")), J.str(o.opt("bridgeCode")), J.dict(o.opt("latency")).let { m -> m.keys().asSequence().associateWith { J.int(m.opt(it)) } },
            )
        }

        class Migrated(val state: TVBoxState, val configs: Map<String, String>, val watches: List<LegacyWatch>)

        fun normalApi(api: String): String = api.trim().lowercase().substringAfter("://").substringBefore('?').trimEnd('/')

        /** `tvbox_store_v1.json` → v2: configs are rebuilt from the saved sites so everything works before the first refresh. */
        fun migrateV1(root: JSONObject): Migrated {
            val configs = LinkedHashMap<String, String>()
            val uidOf = HashMap<String, Pair<String, String>>() // v1 site key → repo id, uid
            val records = J.arr(root.opt("repos")).mapNotNull { e ->
                val r = e as? JSONObject ?: return@mapNotNull null
                val url = J.str(r.opt("url"))
                val id = J.str(r.opt("id")).ifEmpty { RepoRecord.id(url.ifEmpty { J.str(r.opt("name")) }) }
                val disabled = HashSet<String>()
                val legacy = LinkedHashMap<String, String>()
                val sites = JSONArray()
                for (x in J.arr(r.opt("sites"))) {
                    val s = x as? JSONObject ?: continue
                    val key = J.str(s.opt("key")); val api = J.str(s.opt("api"))
                    if (key.isEmpty() || api.isEmpty()) continue
                    val uid = TVBoxConfig.siteUid(id, key)
                    sites.put(JSONObject().put("key", key).put("name", J.str(s.opt("name"))).put("type", 1).put("api", api).put("adult", J.bool(s.opt("adult"))))
                    legacy[uid] = normalApi(api)
                    uidOf.putIfAbsent(key, id to uid)
                    if (s.has("enabled") && !J.bool(s.opt("enabled"))) disabled += uid
                }
                val lives = JSONArray()
                for (x in J.arr(r.opt("lives"))) {
                    val l = x as? JSONObject ?: continue
                    val lurl = J.str(l.opt("url"))
                    val o = JSONObject().put("name", J.str(l.opt("name"))).put("url", lurl)
                    if (lurl.isEmpty()) {
                        val groups = LinkedHashMap<String, JSONArray>()
                        for (c in J.arr(l.opt("channels"))) (c as? JSONObject)?.let { ch -> groups.getOrPut(J.str(ch.opt("group")).ifEmpty { "默认分组" }) { JSONArray() }.put(JSONObject().put("name", J.str(ch.opt("name"))).put("urls", ch.optJSONArray("urls") ?: JSONArray()).put("logo", J.str(ch.opt("logo")))) }
                        if (groups.isEmpty()) continue
                        o.put("groups", JSONArray(groups.map { (n, a) -> JSONObject().put("name", n).put("channel", a) }))
                    }
                    lives.put(o)
                    if (l.has("enabled") && !J.bool(l.opt("enabled"))) disabled += TVBoxConfig.liveUid(id, lurl.ifEmpty { J.str(l.opt("name")) })
                }
                configs[id] = JSONObject().put("sites", sites).put("lives", lives).put("name", J.str(r.opt("name"))).toString()
                RepoRecord(id, J.str(r.opt("name")).ifEmpty { "TVBox 配置" }, url, updatedAt = J.int64(r.opt("updatedAt")), disabled = disabled, legacy = if (url.isEmpty()) emptyMap() else legacy)
            }
            val watches = J.arr(root.opt("recentWatches")).mapNotNull { e ->
                val w = e as? JSONObject ?: return@mapNotNull null
                val (_, uid) = uidOf[J.str(w.opt("siteKey"))] ?: return@mapNotNull null
                val vod = J.str(w.opt("seriesId")).let { if (it.startsWith("cms:")) it.removePrefix("cms:").substringAfter(':') else it }
                if (vod.isEmpty()) null else LegacyWatch(TVBoxId.vod(uid, vod), J.str(w.opt("title")), J.str(w.opt("cover")), J.int(w.opt("episodeIndex")), J.int64(w.opt("positionMs")), J.int64(w.opt("durationMs")), J.int64(w.opt("updatedAt")))
            }
            return Migrated(TVBoxState(records, active = J.str(root.opt("activeRepoId")), favorites = J.arr(root.opt("favoriteChannels")).map { J.str(it) }.filter { it.isNotEmpty() }), configs, watches)
        }

        /** First refresh of a migrated config: old uid → uid of the site with the same api. */
        fun aliases(record: RepoRecord, config: TVBoxConfig): Map<String, String> {
            if (record.legacy.isEmpty()) return emptyMap()
            val byApi = config.sites.associateBy({ normalApi(it.api) }, { TVBoxConfig.siteUid(record.id, it.key) })
            return record.legacy.mapNotNull { (uid, api) -> byApi[api]?.takeIf { it != uid }?.let { uid to it } }.toMap()
        }
    }
}
