package app.iduanju.core.tvbox

import org.json.JSONArray
import org.json.JSONObject

/**
 * JSON as TVBox configs are really written: `//`, `/* */` and `#` comments, single quotes, bare keys and values, trailing or
 * missing commas, raw line breaks inside strings, a BOM, unknown escapes. Produces org.json values (JSONObject / JSONArray /
 * String / Number / Boolean / JSONObject.NULL).
 */
object LenientJson {
    class Malformed(message: String) : Exception(message)

    fun parse(text: String): Any = Parser(text).root()

    fun objectOrNull(text: String): JSONObject? = runCatching { parse(text) as? JSONObject }.getOrNull()
    fun arrayOrNull(text: String): JSONArray? = runCatching { parse(text) as? JSONArray }.getOrNull()

    private class Parser(private val s: String) {
        private var i = 0
        private var depth = 0

        fun root(): Any {
            skip()
            if (i >= s.length) throw Malformed("内容为空")
            return value()
        }

        private fun fail(what: String): Nothing {
            val line = s.substring(0, i.coerceAtMost(s.length)).count { it == '\n' } + 1
            throw Malformed("JSON 第 $line 行：$what")
        }

        private fun skip() {
            while (i < s.length) {
                val c = s[i]
                when {
                    c <= ' ' || c == '﻿' || c == ' ' || c == '​' -> i++
                    c == '#' -> line()
                    c == '/' && i + 1 < s.length && s[i + 1] == '/' -> line()
                    c == '/' && i + 1 < s.length && s[i + 1] == '*' -> { val e = s.indexOf("*/", i + 2); i = if (e < 0) s.length else e + 2 }
                    else -> return
                }
            }
        }

        private fun line() { val e = s.indexOf('\n', i); i = if (e < 0) s.length else e + 1 }

        private fun value(): Any {
            skip()
            if (i >= s.length) fail("内容不完整")
            if (++depth > 256) fail("嵌套过深")
            val v: Any = when (val c = s[i]) {
                '{' -> obj()
                '[' -> arr()
                '"', '\'' -> str(c)
                else -> bare()
            }
            depth--
            return v
        }

        private fun obj(): JSONObject {
            val out = JSONObject()
            i++
            while (true) {
                skip()
                if (i >= s.length) fail("对象没有结束")
                when (s[i]) {
                    '}' -> { i++; return out }
                    ',', ';' -> { i++; continue }
                }
                val key = if (s[i] == '"' || s[i] == '\'') str(s[i]) else bareKey()
                skip()
                if (i >= s.length || (s[i] != ':' && s[i] != '=')) fail("键 $key 后面缺少冒号")
                i++
                skip()
                if (i < s.length && (s[i] == ',' || s[i] == '}')) { out.put(key, JSONObject.NULL); continue }
                out.put(key, value())
            }
        }

        private fun arr(): JSONArray {
            val out = JSONArray()
            i++
            while (true) {
                skip()
                if (i >= s.length) fail("数组没有结束")
                when (s[i]) {
                    ']' -> { i++; return out }
                    ',' -> { i++; continue }
                    '}' -> fail("数组没有结束")
                }
                out.put(value())
            }
        }

        private fun bareKey(): String {
            val start = i
            while (i < s.length && s[i] != ':' && s[i] != '=' && s[i] != ',' && s[i] != '}' && s[i] != '{' && s[i] != '\n') i++
            if (i == start) fail("键名为空")
            return s.substring(start, i).trim()
        }

        private fun bare(): Any {
            val start = i
            while (i < s.length) {
                val c = s[i]
                if (c == ',' || c == '}' || c == ']' || c == '\n' || c == '\r') break
                if (c == '/' && i + 1 < s.length && s[i + 1] == '*') break
                if (c == '/' && i + 1 < s.length && s[i + 1] == '/' && i > start && s[i - 1] != ':') break
                i++
            }
            val t = s.substring(start, i).trim()
            return when {
                t.isEmpty() -> fail("缺少值")
                t == "true" || t == "True" -> true
                t == "false" || t == "False" -> false
                t == "null" || t == "None" || t == "undefined" -> JSONObject.NULL
                else -> number(t) ?: t
            }
        }

        private fun number(t: String): Any? {
            val c = t[0]
            if (!(c in '0'..'9' || c == '-' || c == '+' || c == '.')) return null
            if (t.startsWith("0x") || t.startsWith("0X")) return t.substring(2).toLongOrNull(16)?.let(::narrow)
            val n = t.removePrefix("+")
            n.toLongOrNull()?.let { return narrow(it) }
            return if (n.all { it in "0123456789.eE+-" }) n.toDoubleOrNull()?.takeIf { !it.isNaN() && !it.isInfinite() } else null
        }

        private fun narrow(v: Long): Any = if (v in Int.MIN_VALUE..Int.MAX_VALUE) v.toInt() else v

        private fun str(quote: Char): String {
            val sb = StringBuilder()
            i++
            while (i < s.length) {
                val c = s[i++]
                when {
                    c == quote -> return sb.toString()
                    c != '\\' -> sb.append(c)
                    i >= s.length -> fail("字符串没有结束")
                    else -> when (val e = s[i++]) {
                        'n' -> sb.append('\n')
                        't' -> sb.append('\t')
                        'r' -> sb.append('\r')
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C')
                        '0' -> sb.append('\u0000')
                        'u' -> {
                            val code = if (i + 4 <= s.length) s.substring(i, i + 4).toIntOrNull(16) else null
                            if (code == null) sb.append("\\u") else { sb.append(code.toChar()); i += 4 }
                        }
                        'x' -> {
                            val code = if (i + 2 <= s.length) s.substring(i, i + 2).toIntOrNull(16) else null
                            if (code == null) sb.append("\\x") else { sb.append(code.toChar()); i += 2 }
                        }
                        '\n' -> {}
                        '\r' -> if (i < s.length && s[i] == '\n') i++
                        '"', '\'', '\\', '/', '`' -> sb.append(e)
                        // unknown escape: keep both characters (regex rules are often written with a single backslash)
                        else -> sb.append('\\').append(e)
                    }
                }
            }
            fail("字符串没有结束")
        }
    }
}
