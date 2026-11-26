package app.iduanju.ui.components

import android.os.Build
import android.view.Window
import android.view.WindowManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import app.iduanju.ui.theme.IdjThemeColors
import com.kyant.backdrop.Backdrop
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// Dialogs, sheets, menus and toasts of the app. They are real windows (focus, back, IME and TalkBack behave like the
// platform's), with the glass look on top: the content behind is blurred by the window manager on API 31+, and the
// panel gets the same fill / rim as every other glass surface. No glass on glass: controls inside are plain wells.

val SheetShape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
val DialogShape = RoundedCornerShape(26.dp)
val MenuShape = RoundedCornerShape(18.dp)

private fun Window.glassBehind(radiusPx: Int, dim: Float?) {
    if (dim != null) setDimAmount(dim)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && windowManager.isCrossWindowBlurEnabled) {
        addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
        attributes = attributes.apply { blurBehindRadius = radiusPx }
    }
}

/** Blur what is behind the dialog / sheet window this is composed in. */
@Composable
private fun WindowGlass(radius: Dp, dim: Float? = null) {
    val view = LocalView.current
    val px = with(LocalDensity.current) { radius.roundToPx() }
    LaunchedEffect(view, px, dim) { (view.parent as? DialogWindowProvider)?.window?.glassBehind(px, dim) }
}

@Composable
private fun rememberWindowBlur(): Boolean {
    val ctx = LocalContext.current
    return remember(ctx) {
        runCatching { windowBlurSupported(ctx.getSystemService(WindowManager::class.java)) }.getOrDefault(false)
    }
}

/** Panel fill for overlay windows: translucent over a real window blur, dense where the platform cannot blur. */
@Composable
fun Modifier.overlaySurface(shape: Shape): Modifier {
    val c = IdjThemeColors
    val blur = rememberWindowBlur()
    val liquid = GlassStylePref.style == GlassStyle.LIQUID
    val fill = c.sheet.copy(alpha = when {
        !blur -> 0.985f
        liquid -> 0.93f - 0.20f * GlassStylePref.strength
        else -> 0.92f
    })
    val rim = if (c.dark) Color.White.copy(0.08f) else Color.Black.copy(0.06f)
    return this.clip(shape).background(fill)
        .border(0.6.dp, rim, shape)
}

// MARK: dialog

/** Bare glass dialog: centred panel, scrolling body. Prefer [GlassAlert] for question / notice dialogs. */
@Composable
fun GlassDialog(
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    dismissible: Boolean = true,
    maxWidth: Dp = 400.dp,
    title: String? = null,
    contentPadding: PaddingValues = PaddingValues(20.dp),
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(onDismissRequest, DialogProperties(dismissOnBackPress = dismissible, dismissOnClickOutside = dismissible, usePlatformDefaultWidth = false)) {
        WindowGlass(18.dp, if (IdjThemeColors.dark) 0.42f else 0.26f)
        val cfg = LocalConfiguration.current
        val width = minOf(cfg.screenWidthDp.dp - 48.dp, maxWidth)
        val shown = remember { MutableTransitionState(false).apply { targetState = true } }
        AnimatedVisibility(shown, enter = Motion.modalEnter, exit = Motion.modalExit) {
            Column(
                modifier.width(width).heightIn(max = cfg.screenHeightDp.dp * 0.86f).overlaySurface(DialogShape)
                    .semantics { if (title != null) paneTitle = title }
                    .padding(contentPadding),
                content = content,
            )
        }
    }
}

/** One dialog action. */
@Immutable
class DialogAction(val text: String, val tone: ButtonTone = ButtonTone.Glass, val enabled: Boolean = true, val loading: Boolean = false, val onClick: () -> Unit)

/**
 * Title · message · body · actions. Two actions sit side by side and stack when the font is large or a label is long;
 * three or more always stack.
 */
@Composable
fun GlassAlert(
    onDismissRequest: () -> Unit,
    title: String,
    actions: List<DialogAction>,
    modifier: Modifier = Modifier,
    message: String? = null,
    icon: ImageVector? = null,
    dismissible: Boolean = true,
    maxWidth: Dp = 400.dp,
    content: (@Composable ColumnScope.() -> Unit)? = null,
) {
    val c = IdjThemeColors
    GlassDialog(onDismissRequest, modifier, dismissible, maxWidth, title) {
        if (icon != null) {
            IconWell(icon, 44.dp)
            Spacer(Modifier.height(12.dp))
        }
        Text(title, color = c.text, fontSize = 18.sp, lineHeight = 24.sp, fontWeight = FontWeight.Bold, modifier = Modifier.semantics { heading() })
        Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())) {
            if (!message.isNullOrEmpty()) Text(message, color = c.secondary, fontSize = 14.sp, lineHeight = 21.sp, modifier = Modifier.padding(top = 8.dp))
            if (content != null) {
                Spacer(Modifier.height(12.dp))
                content()
            }
        }
        if (actions.isNotEmpty()) {
            Spacer(Modifier.height(18.dp))
            DialogActions(actions)
        }
    }
}

@Composable
private fun DialogActions(actions: List<DialogAction>) {
    val large = LocalDensity.current.fontScale > 1.25f
    val sideBySide = actions.size == 2 && !large && actions.all { it.text.length <= 8 }
    if (sideBySide) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        actions.forEach { a -> GlassButton(a.text, Modifier.weight(1f), a.tone, ButtonSize.Regular, enabled = a.enabled, loading = a.loading, shape = RoundedCornerShape(14.dp), onClick = a.onClick) }
    } else Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        // The confirming action is listed last, so it comes first when stacked.
        (if (actions.size == 2) actions.reversed() else actions).forEach { a ->
            GlassButton(a.text, Modifier.fillMaxWidth(), a.tone, ButtonSize.Regular, enabled = a.enabled, loading = a.loading, shape = RoundedCornerShape(14.dp), onClick = a.onClick)
        }
    }
}

/** Question dialog with 取消 and one confirming action; runs [onConfirm] (which closes it). */
@Composable
fun GlassConfirm(
    onDismissRequest: () -> Unit, title: String, confirmText: String, onConfirm: () -> Unit, modifier: Modifier = Modifier, message: String? = null,
    dismissText: String = "取消", destructive: Boolean = false, confirmEnabled: Boolean = true, icon: ImageVector? = null,
    content: (@Composable ColumnScope.() -> Unit)? = null,
) = GlassAlert(
    onDismissRequest, title,
    listOf(
        DialogAction(dismissText, onClick = onDismissRequest),
        DialogAction(confirmText, if (destructive) ButtonTone.Danger else ButtonTone.Primary, confirmEnabled, onClick = onConfirm),
    ),
    modifier, message, icon, content = content,
)

// MARK: bottom sheet

/**
 * Bottom sheet with the app's glass panel: 28 dp top corners, grabber, optional centred title with 完成. [scroll] wraps
 * the body in a vertical scroll; pass false when it already is a lazy list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GlassBottomSheet(
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    title: String? = null,
    doneText: String? = null,
    onDone: () -> Unit = onDismissRequest,
    skipPartiallyExpanded: Boolean = true,
    scroll: Boolean = false,
    maxWidth: Dp = 640.dp,
    contentPadding: PaddingValues = PaddingValues(horizontal = 20.dp),
    leading: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) = GlassBottomSheet(
    onDismissRequest, rememberModalBottomSheetState(skipPartiallyExpanded = skipPartiallyExpanded), modifier, title, doneText, onDone,
    scroll, maxWidth, contentPadding, leading, content,
)

/** [GlassBottomSheet] with a caller-owned [SheetState] (to hide it with an animation first). */
@ExperimentalMaterial3Api
@Composable
fun GlassBottomSheet(
    onDismissRequest: () -> Unit,
    sheetState: SheetState,
    modifier: Modifier = Modifier,
    title: String? = null,
    doneText: String? = null,
    onDone: () -> Unit = onDismissRequest,
    scroll: Boolean = false,
    maxWidth: Dp = 640.dp,
    contentPadding: PaddingValues = PaddingValues(horizontal = 20.dp),
    leading: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val c = IdjThemeColors
    val scope = rememberCoroutineScope()
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        sheetState = sheetState,
        sheetMaxWidth = maxWidth,
        shape = SheetShape,
        containerColor = Color.Transparent,
        contentColor = c.text,
        tonalElevation = 0.dp,
        scrimColor = Color.Black.copy(alpha = if (c.dark) 0.46f else 0.28f),
        dragHandle = null,
        contentWindowInsets = { WindowInsets(0, 0, 0, 0) },
    ) {
        WindowGlass(14.dp)
        Column(modifier.fillMaxWidth().overlaySurface(SheetShape).navigationBarsPadding().imePadding()) {
            Box(Modifier.fillMaxWidth().padding(top = 9.dp, bottom = 4.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.size(38.dp, 5.dp).clip(CircleShape).background(c.text.copy(0.22f)))
            }
            // 完成 slides the sheet away before it leaves composition.
            if (title != null) SheetHeader(title, doneText, { scope.launch { sheetState.hide() }.invokeOnCompletion { onDone() } }, leading)
            Column(
                Modifier.fillMaxWidth().weight(1f, fill = false)
                    .then(if (scroll) Modifier.verticalScroll(rememberScrollState()) else Modifier)
                    .padding(contentPadding),
                content = content,
            )
            Spacer(Modifier.height(14.dp))
        }
    }
}

@Composable
private fun SheetHeader(title: String, doneText: String?, onDone: () -> Unit, leading: (@Composable () -> Unit)?) {
    val c = IdjThemeColors
    Box(Modifier.fillMaxWidth().heightIn(min = 46.dp).padding(horizontal = 14.dp, vertical = 2.dp)) {
        if (leading != null) Box(Modifier.align(Alignment.CenterStart)) { leading() }
        Text(title, color = c.text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
            modifier = Modifier.align(Alignment.Center).padding(horizontal = 76.dp).semantics { heading() })
        if (doneText != null) GlassTextButton(doneText, Modifier.align(Alignment.CenterEnd), fontWeight = FontWeight.SemiBold, fontSize = 16.sp, onClick = onDone)
    }
}

// MARK: menu

/** Anchored popup menu; fill it with [GlassMenuItem]s. */
@Composable
fun GlassMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    offset: DpOffset = DpOffset(0.dp, 6.dp),
    content: @Composable ColumnScope.() -> Unit,
) {
    val c = IdjThemeColors
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        modifier = modifier.widthIn(min = 168.dp, max = 320.dp).padding(horizontal = 6.dp),
        offset = offset,
        shape = MenuShape,
        containerColor = c.sheet.copy(alpha = 0.985f),
        tonalElevation = 0.dp,
        shadowElevation = 14.dp,
        border = androidx.compose.foundation.BorderStroke(0.8.dp, Brush.verticalGradient(
            if (c.dark) listOf(Color.White.copy(0.20f), Color.White.copy(0.06f)) else listOf(Color.White, Color.Black.copy(0.08f)))),
        content = content,
    )
}

@Composable
fun GlassMenuItem(
    text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, selected: Boolean = false, destructive: Boolean = false,
    enabled: Boolean = true, detail: String? = null, onClick: () -> Unit,
) {
    val c = IdjThemeColors
    val src = remember { MutableInteractionSource() }
    val ink = when { !enabled -> c.tertiary; destructive -> c.danger; selected -> c.accent; else -> c.text }
    Row(
        modifier.fillMaxWidth().pressScale(src, 0.98f).clip(RoundedCornerShape(12.dp)).background(if (selected) c.accentSoft else Color.Transparent)
            .clickable(src, null, enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { if (selected) this.selected = true }
            .heightIn(min = 44.dp).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (icon != null) Icon(icon, null, Modifier.size(19.dp), tint = ink)
        Text(text, color = ink, fontSize = 15.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, modifier = Modifier.weight(1f))
        if (detail != null) Text(detail, color = c.secondary, fontSize = 12.sp, maxLines = 1)
        if (selected) Icon(Icons.Rounded.Check, null, Modifier.size(17.dp), tint = c.accent)
    }
}

@Composable
fun GlassMenuDivider() = Box(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 4.dp).height(1.dp).background(IdjThemeColors.hairline))

// MARK: toast

/** App-wide short notices. [GlassToastHost] (root) draws them; without a host the system toast is used. */
object GlassToast {
    internal class Message(val text: String, val icon: ImageVector?, val durationMs: Long)

    internal var current by mutableStateOf<Message?>(null)
    internal var hosts = 0

    fun show(text: String, icon: ImageVector? = null, long: Boolean = false) {
        if (text.isBlank()) return
        if (hosts <= 0) {
            runCatching { android.widget.Toast.makeText(app.iduanju.IdjApp.instance, text, if (long) android.widget.Toast.LENGTH_LONG else android.widget.Toast.LENGTH_SHORT).show() }
            return
        }
        current = Message(text, icon, if (long) 3200L else 1900L)
    }
}

@Composable
fun GlassToastHost(modifier: Modifier = Modifier, backdrop: Backdrop? = null) {
    DisposableEffect(Unit) {
        GlassToast.hosts++
        onDispose { GlassToast.hosts-- }
    }
    val msg = GlassToast.current
    val last = remember { arrayOfNulls<GlassToast.Message>(1) }
    if (msg != null) last[0] = msg
    LaunchedEffect(msg) {
        if (msg != null) { delay(msg.durationMs); if (GlassToast.current === msg) GlassToast.current = null }
    }
    AnimatedVisibility(msg != null, modifier, enter = Motion.riseEnter, exit = Motion.riseExit) {
        val m = last[0] ?: return@AnimatedVisibility
        val c = IdjThemeColors
        Row(
            Modifier.widthIn(max = 420.dp).glassSurface(CircleShapeCorner, backdrop = backdrop, shadowRadius = 16.dp, fallbackAlpha = 2.2f)
                .semantics { liveRegion = LiveRegionMode.Polite }
                .padding(horizontal = 18.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (m.icon != null) Icon(m.icon, null, Modifier.size(18.dp), tint = c.accent)
            Text(m.text, color = c.text, fontSize = 14.sp, lineHeight = 19.sp, fontWeight = FontWeight.Medium, maxLines = 4)
        }
    }
}

private val CircleShapeCorner = RoundedCornerShape(22.dp)
