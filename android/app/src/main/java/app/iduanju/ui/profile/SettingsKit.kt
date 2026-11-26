package app.iduanju.ui.profile

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.ui.components.BackButton
import app.iduanju.ui.components.DS
import app.iduanju.ui.components.DSNavBar
import app.iduanju.ui.components.pressWash
import app.iduanju.ui.components.rowClick
import app.iduanju.ui.components.GlassSwitch
import app.iduanju.ui.components.GlassTextButton
import app.iduanju.ui.components.Hairline
import app.iduanju.ui.components.dsCard
import app.iduanju.ui.components.dsPinned
import app.iduanju.ui.components.rememberHaptics
import app.iduanju.ui.theme.IdjThemeColors
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource

/** Shared building blocks for 我的 / 片源管理 / 插件 — iOS grouped rows (ProfileView.link, SourcesView.group). */

/**
 * Sub-page frame: [content] fills the page and scrolls under one pinned header, a [DSNavBar] on the iOS pinned glass
 * (page colour over a single blur + hairline) that fades in once [pinned]. [content] gets the header height as its top
 * inset. With [under] false the content starts below the header instead (pull-to-refresh pages).
 */
@Composable
internal fun SubPage(
    title: String, onBack: () -> Unit, pinned: () -> Boolean, under: Boolean = true, trailing: @Composable () -> Unit = {},
    content: @Composable BoxScope.(top: Dp) -> Unit,
) {
    val haze = remember { HazeState() }
    val latest by rememberUpdatedState(pinned)
    val on by remember { derivedStateOf { latest() } }
    if (under) Box(Modifier.fillMaxSize().background(IdjThemeColors.bg)) {
        val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + 44.dp
        Box(Modifier.fillMaxSize().then(if (android.os.Build.VERSION.SDK_INT >= 31) Modifier.hazeSource(haze) else Modifier)) { content(top) }
        SubPageHeader(title, onBack, on, haze, trailing)
    } else Column(Modifier.fillMaxSize().background(IdjThemeColors.bg)) {
        SubPageHeader(title, onBack, on, null, trailing)
        Box(Modifier.fillMaxWidth().weight(1f)) { content(0.dp) }
    }
}

@Composable
private fun SubPageHeader(title: String, onBack: () -> Unit, pinned: Boolean, haze: HazeState?, trailing: @Composable () -> Unit) =
    // The empty pointer input keeps taps on the bar from reaching the rows scrolling under it.
    Box(Modifier.fillMaxWidth().dsPinned(pinned, haze).pointerInput(Unit) {}.statusBarsPadding()) {
        DSNavBar(title, leading = { BackButton(onClick = onBack) }, trailing = trailing)
    }

/** Sub-page scaffold: back button + centred title on the pinned glass header, scrolling column below. */
@Composable
internal fun SettingsPage(title: String, onBack: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    val scroll = rememberScrollState()
    SubPage(title, onBack, { scroll.value > 4 }) { top ->
        Column(
            Modifier.fillMaxSize().imePadding().verticalScroll(scroll).padding(horizontal = 16.dp).padding(top = top + 12.dp, bottom = 40.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(18.dp),
            content = content,
        )
    }
}

/** [SettingsPage] for pages with many groups: each group is one lazy item. */
@Composable
internal fun SettingsListPage(title: String, onBack: () -> Unit, spacing: Dp = 18.dp, content: LazyListScope.() -> Unit) {
    val list = rememberLazyListState()
    val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    SubPage(title, onBack, { list.firstVisibleItemIndex > 0 || list.firstVisibleItemScrollOffset > 4 }) { top ->
        LazyColumn(
            Modifier.fillMaxSize().imePadding(), list, PaddingValues(start = 16.dp, end = 16.dp, top = top + 12.dp, bottom = bottom + 40.dp),
            verticalArrangement = Arrangement.spacedBy(spacing), content = content,
        )
    }
}

/** iOS SourcesView.group: small grey caption, then a rounded card of rows with inset hairlines. */
@Composable
internal fun Group(title: String? = null, footer: String? = null, rows: @Composable ColumnScope.() -> Unit) {
    val c = IdjThemeColors
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        title?.let { Text(it, color = c.secondary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 4.dp).semantics { heading() }) }
        Column(Modifier.fillMaxWidth().dsCard(18.dp), content = rows)
        footer?.let { Text(it, color = c.secondary, fontSize = 12.sp, lineHeight = 17.sp, modifier = Modifier.padding(horizontal = 4.dp)) }
    }
}

@Composable
internal fun RowDivider() = Hairline(Modifier.padding(start = 50.dp))

/** iOS ProfileView.link: icon · title · trailing secondary text · chevron. */
@Composable
internal fun LinkRow(title: String, icon: ImageVector?, trailing: String? = null, sub: String? = null, tint: Color? = null, onClick: () -> Unit) {
    val c = IdjThemeColors
    Row(Modifier.fillMaxWidth().rowClick(onClick = onClick).heightIn(min = 50.dp).padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Icon(icon, null, tint = tint ?: c.text, modifier = Modifier.size(22.dp)); Spacer(Modifier.width(14.dp)) }
        Column(Modifier.weight(1f)) {
            Text(title, color = tint ?: c.text, fontSize = 16.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            sub?.let { Text(it, color = c.secondary, fontSize = 12.sp, lineHeight = 16.sp, modifier = Modifier.padding(top = 2.dp)) }
        }
        trailing?.let { Text(it, color = c.secondary, fontSize = 14.sp, maxLines = 1, modifier = Modifier.padding(start = 8.dp)) }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = c.secondary, modifier = Modifier.size(20.dp))
    }
}

/** iOS Toggle row with icon, title and caption; the whole row toggles. */
@Composable
internal fun SwitchRow(title: String, icon: ImageVector?, sub: String?, on: Boolean, onChange: (Boolean) -> Unit) {
    val c = IdjThemeColors
    val haptics = rememberHaptics()
    val src = remember { MutableInteractionSource() }
    Row(
        Modifier.fillMaxWidth().pressWash(src).toggleable(on, src, null, role = Role.Switch) { haptics.toggle(it); onChange(it) }
            .heightIn(min = 50.dp).padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { Icon(icon, null, tint = c.text, modifier = Modifier.size(22.dp)); Spacer(Modifier.width(14.dp)) }
        Column(Modifier.weight(1f)) {
            Text(title, color = c.text, fontSize = 16.sp)
            sub?.let { Text(it, color = c.secondary, fontSize = 12.sp, lineHeight = 16.sp, modifier = Modifier.padding(top = 2.dp)) }
        }
        Spacer(Modifier.width(10.dp))
        GlassSwitch(on, null)
    }
}

/** Small grey capsule tag ("内置", "漫画", "18+"). */
@Composable
internal fun Tag(text: String) {
    val c = IdjThemeColors
    Text(text, color = c.secondary, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
        modifier = Modifier.clip(CircleShape).background(c.glass).padding(horizontal = 8.dp, vertical = 3.dp))
}

@Composable
internal fun Note(text: String?, error: Boolean = false) {
    text ?: return
    val c = IdjThemeColors
    Text(text, color = if (error) c.accentWarm else c.accent, fontSize = 13.sp, lineHeight = 18.sp,
        modifier = Modifier.padding(horizontal = 4.dp).semantics { liveRegion = LiveRegionMode.Polite })
}

@Composable
internal fun TextAction(text: String, enabled: Boolean = true, onClick: () -> Unit) = GlassTextButton(text, enabled = enabled, onClick = onClick)

internal object ProfileIcons {
    val history = Icons.Outlined.History
    val star = Icons.Outlined.StarOutline
    val heart = Icons.Outlined.FavoriteBorder
    val telegram = Icons.Outlined.Send
    val manga = Icons.AutoMirrored.Outlined.MenuBook
    val download = Icons.Outlined.Download
    val sources = Icons.Outlined.Layers
    val plugin = Icons.Outlined.Extension
    val license = Icons.Outlined.Description
    val update = Icons.Outlined.SystemUpdate
    val reset = Icons.Outlined.Refresh
    val key = Icons.Outlined.Key
    val photos = Icons.Outlined.PhotoLibrary
    val trash = Icons.Outlined.Delete
    val play = Icons.Outlined.SmartDisplay
    val film = Icons.Outlined.Movie
    val globe = Icons.Outlined.Language
    val link = Icons.Outlined.Link
    val file = Icons.Outlined.NoteAdd
    val paste = Icons.Outlined.ContentPaste
    val sync = Icons.Outlined.Sync
    val add = Icons.Outlined.AddCircleOutline
    val server = Icons.Outlined.Dns
    val adblock = Icons.Outlined.Block
    val device = Icons.Outlined.PhoneAndroid
}
