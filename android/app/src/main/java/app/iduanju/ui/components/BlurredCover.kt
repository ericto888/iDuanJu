package app.iduanju.ui.components

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import coil.compose.AsyncImage
import coil.request.ImageRequest
import coil.transform.Transformation

/**
 * Three-pass box blur on a tiny decode, done once when the image is loaded: no RenderEffect per frame and the same
 * look on every Android version.
 */
internal class SoftBlur(private val radius: Int = 4) : Transformation {
    override val cacheKey = "soft-blur-$radius"

    override suspend fun transform(input: Bitmap, size: coil.size.Size): Bitmap {
        val w = input.width; val h = input.height
        var a = IntArray(w * h).also { input.getPixels(it, 0, w, 0, 0, w, h) }
        var b = IntArray(w * h)
        repeat(3) {
            pass(a, b, w, h, 1, w); a = b.also { b = a }
            pass(a, b, h, w, w, 1); a = b.also { b = a }
        }
        return Bitmap.createBitmap(a, w, h, Bitmap.Config.ARGB_8888)
    }

    /** Blurs [lines] runs of [n] pixels; neighbours are [step] apart, runs start [stride] apart. */
    private fun pass(src: IntArray, dst: IntArray, n: Int, lines: Int, step: Int, stride: Int) {
        val span = 2 * radius + 1
        for (line in 0 until lines) {
            val base = line * stride
            var r = 0; var g = 0; var b = 0
            fun at(i: Int) = src[base + i.coerceIn(0, n - 1) * step]
            for (i in -radius..radius) { val p = at(i); r += p shr 16 and 0xFF; g += p shr 8 and 0xFF; b += p and 0xFF }
            for (i in 0 until n) {
                dst[base + i * step] = (0xFF shl 24) or (r / span shl 16) or (g / span shl 8) or (b / span)
                val out = at(i - radius); val inn = at(i + radius + 1)
                r += (inn shr 16 and 0xFF) - (out shr 16 and 0xFF)
                g += (inn shr 8 and 0xFF) - (out shr 8 and 0xFF)
                b += (inn and 0xFF) - (out and 0xFF)
            }
        }
    }
}

/**
 * Blurred cover backdrop: a 48×64 decode softened by [SoftBlur] and upscaled by the GPU. The sharp cover the user just
 * tapped stands in from the memory cache until it is ready, so a page never opens on a blank header.
 */
@Composable
fun BlurredCover(url: String?, modifier: Modifier = Modifier, alpha: Float = 1f) {
    val ctx = LocalContext.current
    val req = remember(url) {
        ImageRequest.Builder(ctx).data(url).size(48, 64).transformations(SoftBlur()).memoryCacheKey("blur:$url")
            .apply { if (!url.isNullOrEmpty()) placeholderMemoryCacheKey(url) }.build()
    }
    AsyncImage(req, null, modifier, contentScale = ContentScale.Crop, alpha = alpha, filterQuality = FilterQuality.Medium)
}
