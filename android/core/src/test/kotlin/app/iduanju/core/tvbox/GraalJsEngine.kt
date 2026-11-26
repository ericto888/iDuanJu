package app.iduanju.core.tvbox

import org.graalvm.polyglot.Context
import org.graalvm.polyglot.HostAccess
import org.graalvm.polyglot.PolyglotException
import org.graalvm.polyglot.Source
import org.graalvm.polyglot.io.FileSystem
import org.graalvm.polyglot.io.IOAccess
import org.graalvm.polyglot.proxy.ProxyExecutable
import java.net.URI
import java.nio.ByteBuffer
import java.nio.channels.SeekableByteChannel
import java.nio.file.AccessMode
import java.nio.file.DirectoryStream
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.OpenOption
import java.nio.file.Path
import java.nio.file.attribute.FileAttribute

/** Stand-in for QuickJS so the shared bootstrap and libraries run in JVM tests (module addresses are mapped onto fake paths). */
class GraalJsEngine : JsEngine {
    private var normalize: (String, String) -> String = { _, n -> n }
    private var load: (String) -> String = { throw NoSuchFileException(it) }
    private val spec = Regex("(\\bfrom\\s*|\\bimport\\s*\\(?\\s*)(['\"])([^'\"\\n]+)\\2")

    private fun hex(name: String) = "/idj/" + name.toByteArray().joinToString("") { "%02x".format(it) } + ".mjs"
    private fun unhex(p: Path) = p.fileName.toString().removeSuffix(".mjs").chunked(2).map { it.toInt(16).toByte() }.toByteArray().toString(Charsets.UTF_8)
    private fun rewrite(code: String, base: String) = spec.replace(code) { m -> m.groupValues[1] + "'" + hex(normalize(base, m.groupValues[3])) + "'" }

    private val fs = object : FileSystem {
        override fun parsePath(uri: URI): Path = Path.of(uri)
        override fun parsePath(path: String): Path = Path.of(path)
        override fun checkAccess(path: Path, modes: MutableSet<out AccessMode>, vararg linkOptions: LinkOption) { if (!path.fileName.toString().endsWith(".mjs")) throw NoSuchFileException(path.toString()) }
        override fun createDirectory(dir: Path, vararg attrs: FileAttribute<*>) = throw UnsupportedOperationException()
        override fun delete(path: Path) = throw UnsupportedOperationException()
        override fun newDirectoryStream(dir: Path, filter: DirectoryStream.Filter<in Path>): DirectoryStream<Path> = throw UnsupportedOperationException()
        override fun toAbsolutePath(path: Path): Path = path.toAbsolutePath()
        override fun toRealPath(path: Path, vararg linkOptions: LinkOption): Path = path.toAbsolutePath()
        override fun readAttributes(path: Path, attributes: String, vararg options: LinkOption): MutableMap<String, Any> = throw UnsupportedOperationException()
        override fun newByteChannel(path: Path, options: MutableSet<out OpenOption>, vararg attrs: FileAttribute<*>): SeekableByteChannel {
            val name = unhex(path)
            return Bytes(rewrite(load(name), name).toByteArray())
        }
    }

    private class Bytes(private val b: ByteArray) : SeekableByteChannel {
        private var at = 0
        override fun read(dst: ByteBuffer): Int { if (at >= b.size) return -1; val n = minOf(dst.remaining(), b.size - at); dst.put(b, at, n); at += n; return n }
        override fun write(src: ByteBuffer): Int = throw UnsupportedOperationException()
        override fun position(): Long = at.toLong()
        override fun position(p: Long): SeekableByteChannel { at = p.toInt(); return this }
        override fun size(): Long = b.size.toLong()
        override fun truncate(size: Long): SeekableByteChannel = this
        override fun isOpen() = true
        override fun close() {}
    }

    private val ctx = Context.newBuilder("js").allowExperimentalOptions(true).option("engine.WarnInterpreterOnly", "false").option("js.ecmascript-version", "2023")
        .allowHostAccess(HostAccess.NONE).allowIO(IOAccess.newBuilder().fileSystem(fs).build()).build()

    override fun install(call: (String, String) -> String) {
        ctx.getBindings("js").putMember("__tv", ProxyExecutable { a -> call(a[0].asString(), a[1].asString()) })
        // QuickJS has no host timers, URL, TextEncoder … : make sure the bootstrap provides them itself
        ctx.eval("js", "for (const k of ['console','print','load','setTimeout','clearTimeout','setInterval','clearInterval','URL','URLSearchParams','TextEncoder','TextDecoder','queueMicrotask','fetch','crypto']) delete globalThis[k]")
    }

    override fun modules(normalize: (base: String, name: String) -> String, load: (name: String) -> String) { this.normalize = normalize; this.load = load }

    private fun <T> guard(f: () -> T): T = try { f() } catch (e: PolyglotException) { throw RuntimeException(e.message) }

    override fun script(code: String, name: String): Any? = guard { ctx.eval(Source.newBuilder("js", if (name == "bootstrap.js") code else rewrite(code, name), name).build()).let { if (it.isString) it.asString() else it.toString() } }
    override fun module(code: String, name: String) { guard { ctx.eval(Source.newBuilder("js", rewrite(code, name), name).mimeType("application/javascript+module").build()) } }
    override fun close() = ctx.close(true)
}
