package app.iduanju.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.core.hongguo.HGEpisode
import app.iduanju.ui.theme.IdjColors
import app.iduanju.ui.theme.IdjThemeColors

/** Episode naming shared by the detail page and the player panel. */
object EpisodeNames {
    private val numeric = Regex("""^(第?\s*0*\d{1,4}\s*[集话話回期章]?|[eE][pP]?\s*\d{1,4}|[sS]\d{1,2}[eE]\d{1,4})$""")

    /** Titles that say more than a number ("HD中字", "20240101期", "正片"): these lists get text cells. */
    fun textual(episodes: List<HGEpisode>): Boolean = episodes.any { val t = it.title.trim(); t.isNotEmpty() && !numeric.matches(t) }

    fun cell(ep: HGEpisode, textual: Boolean): String = if (textual) ep.title.trim().ifEmpty { "第 ${ep.ep} 集" } else "${ep.ep}"

    /** "第 3 集", or the source's own title when it is not just a number. */
    fun full(ep: HGEpisode): String {
        val t = ep.title.trim()
        return if (t.isEmpty() || numeric.matches(t)) "第 ${ep.ep} 集" else t
    }
}

/**
 * One episode cell: 44 dp, radius 12, current = accent tint + line + dot. [onGlass] keeps it a plain well, for grids
 * that already sit on a glass panel.
 */
@Composable
fun EpisodeCell(text: String, current: Boolean, modifier: Modifier = Modifier, textual: Boolean = false, colors: IdjColors = IdjThemeColors, label: String? = null, onClick: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Box(
        modifier.heightIn(min = 44.dp).clip(shape)
            .background(if (current) colors.accentSoft else colors.glass)
            .then(if (current) Modifier.border(1.dp, colors.accentLine, shape) else Modifier)
            .pressClick(0.94f, label = label, onClick = onClick)
            .semantics { selected = current },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text, color = if (current) colors.accent else if (colors.dark) Color.White.copy(0.94f) else colors.text,
            fontSize = if (textual) 13.sp else 15.sp, lineHeight = if (textual) 17.sp else 20.sp, fontWeight = FontWeight.SemiBold,
            maxLines = if (textual) 2 else 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
            modifier = if (textual) Modifier.padding(horizontal = 8.dp, vertical = 6.dp) else Modifier,
        )
        if (current) Box(Modifier.align(Alignment.TopEnd).padding(6.dp).size(5.dp).clip(CircleShape).background(colors.accent))
    }
}

/** Columns for textual cells, from the number grid's columns. */
fun textColumns(numberColumns: Int): Int = when { numberColumns >= 10 -> 5; numberColumns >= 8 -> 4; else -> 3 }

/** Fixed-column rows for grids inside an already scrolling page. */
@Composable
fun EpisodeRows(
    episodes: List<HGEpisode>, range: List<Int>, columns: Int, current: Int?, textual: Boolean, modifier: Modifier = Modifier, gap: Dp = 8.dp,
    colors: IdjColors = IdjThemeColors, onPick: (Int) -> Unit,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(gap)) {
        range.chunked(columns).forEach { row ->
            Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(gap)) {
                row.forEach { i ->
                    val ep = episodes[i]
                    EpisodeCell(EpisodeNames.cell(ep, textual), i == current, Modifier.weight(1f).fillMaxHeight(), textual, colors, label = EpisodeNames.full(ep)) { onPick(i) }
                }
                repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}
