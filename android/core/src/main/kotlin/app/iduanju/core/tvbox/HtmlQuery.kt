package app.iduanju.core.tvbox

import org.jsoup.Jsoup
import org.jsoup.helper.W3CDom
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import org.jsoup.select.Elements
import org.w3c.dom.Node
import org.w3c.dom.NodeList
import javax.xml.xpath.XPathConstants
import javax.xml.xpath.XPathFactory

/** jQuery-flavoured selection on jsoup: positional pseudos (`:eq :first :last :gt :lt :even :odd`) count inside the matched set. */
object HtmlQuery {
    fun parse(html: String): Document = Jsoup.parse(html).apply { outputSettings().prettyPrint(false) }

    private val POSITIONAL = Regex(":(eq|gt|lt|nth)\\(\\s*(-?\\d+)\\s*\\)|:(first|last|even|odd)(?![\\w-])")
    private val QUOTED = Regex(":(contains|containsOwn)\\(\\s*(['\"])(.*?)\\2\\s*\\)")
    private val DROP = Regex(":(visible|enabled|selected)(?![\\w-])")

    fun select(roots: List<Element>, css: String): List<Element> {
        val clean = DROP.replace(QUOTED.replace(css.trim()) { ":${it.groupValues[1]}(${it.groupValues[3]})" }, "")
        if (clean.isEmpty()) return emptyList()
        val out = LinkedHashSet<Element>()
        for (g in splitTop(clean)) if (g.isNotBlank()) out += runCatching { group(roots, g.trim()) }.getOrDefault(emptyList())
        return out.toList()
    }

    /** Commas outside brackets and quotes. */
    private fun splitTop(s: String): List<String> {
        val out = ArrayList<String>(); val sb = StringBuilder(); var depth = 0; var quote = '\u0000'
        for (c in s) {
            when {
                quote != '\u0000' -> if (c == quote) quote = '\u0000'
                c == '"' || c == '\'' -> quote = c
                c == '(' || c == '[' -> depth++
                c == ')' || c == ']' -> depth--
                c == ',' && depth == 0 -> { out += sb.toString(); sb.clear(); continue }
            }
            sb.append(c)
        }
        out += sb.toString()
        return out
    }

    /** First positional pseudo that is not inside `:has(…)` / `:not(…)` / an attribute. */
    private fun positional(s: String): MatchResult? = POSITIONAL.findAll(s).firstOrNull { m ->
        var depth = 0
        for (i in 0 until m.range.first) when (s[i]) { '(', '[' -> depth++; ')', ']' -> depth-- }
        depth == 0
    }

    private fun group(roots: List<Element>, selector: String): List<Element> {
        var ctx = roots
        var rest = selector
        var self = false
        while (true) {
            val m = positional(rest)
            val part = if (m == null) rest else rest.substring(0, m.range.first)
            ctx = apply(ctx, part, self)
            if (m == null) return ctx
            ctx = pick(ctx, m)
            rest = rest.substring(m.range.last + 1)
            if (rest.isBlank()) return ctx
            self = !(rest[0].isWhitespace() || rest[0] in ">+~")
        }
    }

    private fun pick(list: List<Element>, m: MatchResult): List<Element> {
        val n = m.groupValues[2].toIntOrNull() ?: 0
        return when (m.groupValues[1].ifEmpty { m.groupValues[3] }) {
            "eq", "nth" -> listOfNotNull(list.getOrNull(if (n < 0) list.size + n else n))
            "gt" -> list.drop((if (n < 0) list.size + n else n) + 1)
            "lt" -> list.take(if (n < 0) maxOf(0, list.size + n) else n)
            "first" -> list.take(1)
            "last" -> list.takeLast(1)
            "even" -> list.filterIndexed { i, _ -> i % 2 == 0 }
            else -> list.filterIndexed { i, _ -> i % 2 == 1 }
        }
    }

    /** [self]: [part] continues the compound of the current elements (`li:eq(0).on a`). */
    private fun apply(ctx: List<Element>, part: String, self: Boolean): List<Element> {
        if (part.isBlank()) return if (self) ctx else descend(ctx, "*")
        if (!self) return descend(ctx, part.trim())
        var depth = 0
        val end = part.indices.firstOrNull { i ->
            when (part[i]) { '(', '[' -> depth++; ')', ']' -> depth-- }
            depth == 0 && (part[i].isWhitespace() || part[i] in ">+~")
        } ?: part.length
        val kept = ctx.filter { it.`is`(part.substring(0, end)) }
        val tail = part.substring(end)
        return if (tail.isBlank()) kept else descend(kept, tail.trim())
    }

    private fun descend(ctx: List<Element>, part: String): List<Element> {
        val out = LinkedHashSet<Element>()
        for (el in ctx) when (part[0]) {
            '+', '~' -> {
                val body = part.substring(1).trim()
                val cut = body.indexOfFirst { it.isWhitespace() || it == '>' }.let { if (it < 0) body.length else it }
                val sibs = if (part[0] == '+') listOfNotNull(el.nextElementSibling()) else generateSequence(el.nextElementSibling()) { it.nextElementSibling() }.toList()
                val hit = sibs.filter { it.`is`(body.substring(0, cut)) }
                out += if (cut == body.length) hit else descend(hit, body.substring(cut).trim())
            }
            else -> el.select(part).forEach { if (it !== el) out += it }
        }
        return out.toList()
    }

    fun xpath(el: Element, q: String): List<Any> {
        val w3c = W3CDom().namespaceAware(false)
        val doc = w3c.fromJsoup(el)
        val ctx = w3c.contextNode(doc) ?: doc
        val xp = XPathFactory.newInstance().newXPath()
        val nodes = try { xp.evaluate(q, ctx, XPathConstants.NODESET) as NodeList } catch (_: Exception) {
            return listOf(xp.evaluate(q, ctx, XPathConstants.STRING) as String)
        }
        return (0 until nodes.length).mapNotNull { i ->
            val n = nodes.item(i)
            when (n.nodeType) {
                Node.ELEMENT_NODE -> n.getUserData(W3CDom.SourceProperty) as? Element ?: n.textContent
                else -> n.nodeValue
            }
        }
    }
}

/** drpy / Hiker rules: `a&&b&&Text`, `a&&href||data-src`, `.x--.ad&&Text`, `li:eq(1)`, `Html`. */
object PdfRule {
    private val NO_INDEX = Regex(":eq|:lt|:gt|:first|:last|:not|:even|:odd|:has|:contains|:matches|:empty|^body$|^#")
    private val STYLE_URL = Regex("url\\((.*?)\\)", RegexOption.DOT_MATCHES_ALL)
    private val LINK_ATTR = Regex("(url|src|href|-original|-src|-play|-url|style)$|^(data-|url-|src-)", RegexOption.IGNORE_CASE)
    private val KEEP_SCHEME = Regex("^(ftp|magnet|thunder|ws|data|javascript):", RegexOption.IGNORE_CASE)

    fun one(doc: Element, rule: String, base: String = ""): String {
        val alternatives = alternatives(rule)
        for (r in alternatives) single(doc, r.trim(), base).let { if (it.isNotEmpty()) return it }
        return ""
    }

    fun list(doc: Element, rule: String): List<String> {
        for (r in alternatives(rule)) { val els = elements(doc, r.trim(), first = false); if (els.isNotEmpty()) return els.map { it.outerHtml() } }
        return emptyList()
    }

    fun pairs(doc: Element, rule: String, text: String, url: String, base: String): List<String> =
        elements(doc, rule.trim(), first = false).map { el -> HtmlQuery.parse(el.outerHtml()).let { one(it, text).trim() + "$" + one(it, url, base) } }

    /** `x&&Text||y&&Text` are whole alternatives; `x&&href||src` only alternates the attribute. */
    private fun alternatives(rule: String): List<String> {
        val parts = rule.split("||")
        if (parts.size == 1) return parts
        val out = ArrayList<String>()
        for (p in parts) if (out.isNotEmpty() && !p.contains("&&") && out.last().contains("&&")) out[out.lastIndex] = out.last() + "||" + p else out += p
        return out
    }

    private fun single(doc: Element, rule: String, base: String): String {
        if (rule.isEmpty()) return ""
        if (rule == "body&&Text" || rule == "Text") return doc.text()
        if (rule == "body&&Html" || rule == "Html") return doc.html()
        val cut = rule.lastIndexOf("&&")
        val option = if (cut < 0) "" else rule.substring(cut + 2).trim()
        val els = Elements(elements(doc, if (cut < 0) rule else rule.substring(0, cut), first = true))
        if (els.isEmpty()) return ""
        return when (option) {
            "" -> els.outerHtml()
            "Text" -> els.text()
            "Html" -> els.html()
            else -> option.split("||").firstNotNullOfOrNull { attr(els, it.trim(), base).ifEmpty { null } }.orEmpty()
        }
    }

    private fun attr(els: Elements, name: String, base: String): String {
        var v = els.attr(name)
        if (name.contains("style", true) && v.contains("url(")) v = STYLE_URL.find(v)?.groupValues?.get(1)?.trim()?.trim('\'', '"').orEmpty()
        if (v.isNotEmpty() && base.isNotEmpty() && LINK_ATTR.containsMatchIn(name) && !KEEP_SCHEME.containsMatchIn(v)) {
            v = if (v.contains("http") && !v.startsWith("/")) v.substring(v.indexOf("http")) else TVBoxUrl.join(base, v)
        }
        return v
    }

    private fun elements(doc: Element, rule: String, first: Boolean): List<Element> {
        val segs = rule.split("&&").map { it.trim() }.filter { it.isNotEmpty() }
        var ctx: List<Element> = listOf(doc)
        segs.forEachIndexed { i, seg ->
            val bits = seg.split("--")
            var css = bits[0].trim()
            val indexed = NO_INDEX.containsMatchIn(css.substringAfterLast(' '))
            if (!indexed && (first || i < segs.lastIndex)) css += ":eq(0)"
            ctx = HtmlQuery.select(ctx, css)
            if (ctx.isEmpty()) return ctx
            val drop = bits.drop(1).map { it.trim() }.filter { it.isNotEmpty() }
            if (drop.isNotEmpty()) ctx = ctx.map { el -> el.clone().also { c -> drop.forEach { d -> HtmlQuery.select(listOf(c), d).forEach { x -> x.remove() } } } }
        }
        return ctx
    }
}
