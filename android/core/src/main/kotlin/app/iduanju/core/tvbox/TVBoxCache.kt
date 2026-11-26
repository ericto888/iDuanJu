package app.iduanju.core.tvbox

import app.iduanju.core.util.Bytes
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** Stale-while-revalidate store for home / category / live texts: one folder per owner, plain files, bounded. */
class TVBoxCache(private val dir: File, private val maxBytes: Long = 48L shl 20) {
    class Hit(val text: String, val at: Long) { val age: Long get() = System.currentTimeMillis() - at }

    private val memory = object : LinkedHashMap<String, Hit>(32, 0.75f, true) { override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Hit>) = size > 24 }
    private val locks = ConcurrentHashMap<String, Any>()

    private fun file(owner: String, key: String) = File(File(dir, owner.filter { it.isLetterOrDigit() || it == '-' || it == '_' }.take(40)), Bytes.hex(Bytes.md5(key)))

    fun get(owner: String, key: String): Hit? {
        val id = "$owner|$key"
        synchronized(memory) { memory[id] }?.let { return it }
        val f = file(owner, key)
        val hit = synchronized(locks.getOrPut(owner) { Any() }) { if (f.isFile) runCatching { Hit(f.readText(), f.lastModified()) }.getOrNull() else null } ?: return null
        // a put that came in between is newer than what was just read
        if (small(hit.text)) synchronized(memory) { if (id !in memory) memory[id] = hit }
        return hit
    }

    /** Larger texts (big live lists) are read from disk each time. */
    private fun small(text: String) = text.length < 1 shl 20

    fun put(owner: String, key: String, text: String) {
        val hit = Hit(text, System.currentTimeMillis())
        synchronized(memory) { if (small(text)) memory["$owner|$key"] = hit else memory.remove("$owner|$key") }
        val f = file(owner, key)
        synchronized(locks.getOrPut(owner) { Any() }) {
            runCatching {
                f.parentFile?.mkdirs()
                val tmp = File(f.path + ".tmp")
                tmp.writeText(text)
                if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
            }
        }
    }

    fun clear(owner: String) {
        synchronized(memory) { memory.keys.removeAll { it.startsWith("$owner|") } }
        file(owner, "").parentFile?.deleteRecursively()
    }

    /** Oldest files first once the folder grows past its budget (called off the main thread at start). */
    fun trim() {
        val files = dir.walkTopDown().filter { it.isFile }.toList()
        var total = files.sumOf { it.length() }
        for (f in files.sortedBy { it.lastModified() }) { if (total <= maxBytes) return; total -= f.length(); f.delete() }
    }
}
