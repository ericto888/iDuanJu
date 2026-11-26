package app.iduanju.core.cms

import app.iduanju.core.tvbox.LenientJson
import app.iduanju.core.tvbox.ParsedConfig
import app.iduanju.core.tvbox.SiteKind
import app.iduanju.core.tvbox.TVBoxConfig

/**
 * The part of a TVBox config the plugin page can add as 采集站 (HTTPS CMS interfaces and HTTPS live lists). The TVBox tab reads
 * the whole config with [TVBoxConfig] instead; this view only exists so a config pasted among plugins is not lost.
 */
object TVBoxImport {
    data class Site(val name: String, val api: String, val adult: Boolean)
    data class Live(val name: String, val url: String)
    data class Config(val name: String, val sites: List<Site>, val skipped: Int, val lives: List<Live>)

    fun parse(text: String): Config {
        val parsed = try { TVBoxConfig.parse(text, "") } catch (e: LenientJson.Malformed) { throw IllegalArgumentException(e.message) }
        val config = when (parsed) {
            is ParsedConfig.Config -> parsed.config
            is ParsedConfig.Depot -> throw IllegalArgumentException("这是多仓配置，请在 TVBox 页添加后选择其中一个")
            is ParsedConfig.Live -> throw IllegalArgumentException("这是直播列表，请在 TVBox 页添加")
        }
        val sites = ArrayList<Site>()
        val seen = HashSet<String>()
        for (s in config.sites) {
            val cms = s.kind == SiteKind.CmsJson || s.kind == SiteKind.CmsXml || (s.kind == SiteKind.Remote && s.ext.isEmpty())
            val api = if (cms) runCatching { MacCMS.normalize(s.api) }.getOrNull() else null
            if (api != null && seen.add(api)) sites += Site(s.name, api, s.adult)
        }
        val lives = config.lives.filter { it.url.startsWith("https://") && runCatching { MacCMS.normalize(it.url) }.isSuccess }.map { Live(it.name, it.url) }
        require(sites.isNotEmpty() || lives.isNotEmpty()) { "没有可以当作采集站添加的 CMS 接口（type=0 / type=1 / 无参数的 type=4）；脚本与 JAR 站点请在 TVBox 页添加整个配置" }
        return Config(config.name.ifEmpty { "TVBox 配置" }, sites, config.sites.size - sites.size, lives)
    }
}
