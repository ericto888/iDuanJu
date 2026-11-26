package app.iduanju.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitHorizontalTouchSlopOrCancellation
import androidx.compose.foundation.gestures.horizontalDrag
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.progressSemantics
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.ui.theme.IdjColors
import app.iduanju.ui.theme.IdjDarkColors
import app.iduanju.ui.theme.IdjThemeColors
import kotlin.math.roundToInt

// The app's own controls. Everything interactive has a ≥ 44 dp target, a TalkBack role / state, press feedback from
// [Motion], and text that grows with the system font (min heights, never fixed ones).

// MARK: buttons

/** [Primary] one per screen · [Tinted] secondary accent · [Glass] neutral · [Plain] text only · [Danger] destructive. */
enum class ButtonTone { Primary, Tinted, Glass, Plain, Danger, DangerPlain }

enum class ButtonSize(val minHeight: Dp, val hPad: Dp, val font: TextUnit, val icon: Dp) {
    Large(48.dp, 22.dp, 16.sp, 18.dp),
    Regular(42.dp, 18.dp, 15.sp, 17.dp),
    Small(34.dp, 14.dp, 13.sp, 15.dp),
}

/** Capsule button; [loading] swaps the icon for a spinner and blocks taps without changing the width. */
@Composable
fun GlassButton(
    text: String,
    modifier: Modifier = Modifier,
    tone: ButtonTone = ButtonTone.Primary,
    size: ButtonSize = ButtonSize.Regular,
    icon: ImageVector? = null,
    enabled: Boolean = true,
    loading: Boolean = false,
    colors: IdjColors = IdjThemeColors,
    shape: Shape = CircleShape,
    onClick: () -> Unit,
) {
    val src = remember { MutableInteractionSource() }
    val live = enabled && !loading
    val ink = when (tone) {
        ButtonTone.Primary -> colors.onAccent
        ButtonTone.Tinted, ButtonTone.Plain -> colors.accent
        ButtonTone.Glass -> colors.text
        ButtonTone.Danger -> Color.White
        ButtonTone.DangerPlain -> colors.danger
    }
    val surface = when (tone) {
        ButtonTone.Primary -> Modifier.clip(shape).background(colors.accent)
        ButtonTone.Tinted -> Modifier.clip(shape).background(colors.accentSoft)
        ButtonTone.Glass -> Modifier.glassPill(shape, dark = colors.dark, accent = colors.accent)
        ButtonTone.Plain, ButtonTone.DangerPlain -> Modifier.clip(shape)
        ButtonTone.Danger -> Modifier.clip(shape).background(colors.danger)
    }
    val bare = tone == ButtonTone.Plain || tone == ButtonTone.DangerPlain
    Row(
        modifier
            .pressScale(src)
            .graphicsLayer { alpha = if (enabled) 1f else 0.4f }
            .then(surface)
            .clickable(src, null, enabled = live, role = Role.Button, onClick = onClick)
            .heightIn(min = size.minHeight)
            .padding(horizontal = if (bare) size.hPad * 0.65f else size.hPad, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterHorizontally),
    ) {
        if (loading) GlassSpinner(size = size.icon, color = ink, stroke = 2.dp)
        else if (icon != null) Icon(icon, null, Modifier.size(size.icon), tint = ink)
        Text(text, color = ink, fontSize = size.font, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
    }
}

/** Accent text action (dialog buttons, 「清空」, 「编辑」). */
@Composable
fun GlassTextButton(
    text: String, modifier: Modifier = Modifier, color: Color = IdjThemeColors.accent, enabled: Boolean = true,
    fontSize: TextUnit = 15.sp, fontWeight: FontWeight = FontWeight.Medium, icon: ImageVector? = null, onClick: () -> Unit,
) {
    val src = remember { MutableInteractionSource() }
    Row(
        modifier.pressScale(src).clip(RoundedCornerShape(12.dp))
            .clickable(src, null, enabled = enabled, role = Role.Button, onClick = onClick)
            .heightIn(min = 40.dp).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
    ) {
        val ink = if (enabled) color else IdjThemeColors.tertiary
        if (icon != null) Icon(icon, null, Modifier.size(17.dp), tint = ink)
        Text(text, color = ink, fontSize = fontSize, fontWeight = fontWeight, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/** 44 dp icon target without a surface (nav rows, list trailing actions). */
@Composable
fun PlainIconButton(
    icon: ImageVector, label: String, modifier: Modifier = Modifier, tint: Color = IdjThemeColors.text, iconSize: Dp = 22.dp,
    enabled: Boolean = true, onClick: () -> Unit,
) {
    val src = remember { MutableInteractionSource() }
    Box(
        modifier.size(44.dp).pressScale(src, 0.9f).clip(CircleShape)
            .clickable(src, null, enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, label, Modifier.size(iconSize), tint = if (enabled) tint else tint.copy(alpha = tint.alpha * 0.38f)) }
}

// MARK: switch / checkbox / radio

/** 50×30 track, 26 dp thumb. [onCheckedChange] null = drawn only (the row owns the toggle). */
@Composable
fun GlassSwitch(
    checked: Boolean,
    onCheckedChange: ((Boolean) -> Unit)?,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    colors: IdjColors = IdjThemeColors,
    label: String? = null,
) {
    val haptics = rememberHaptics()
    val src = remember { MutableInteractionSource() }
    val on = animateFloatAsState(if (checked) 1f else 0f, DS.select(), label = "switch")
    val track = animateColorAsState(
        if (checked) colors.accent else if (colors.dark) Color.White.copy(0.16f) else Color.Black.copy(0.12f), tween(Motion.SHORT), label = "switchTrack")
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    val rim = if (colors.dark) Color.White.copy(0.14f) else Color.Black.copy(0.06f)
    Box(
        modifier
            .then(
                if (onCheckedChange != null) Modifier.toggleable(checked, src, null, enabled, Role.Switch) { haptics.toggle(it); onCheckedChange(it) }
                    .then(if (label != null) Modifier.semantics { contentDescription = label } else Modifier)
                else Modifier,
            )
            .sizeIn(minWidth = 50.dp, minHeight = if (onCheckedChange != null) 44.dp else 30.dp)
            .graphicsLayer { alpha = if (enabled) 1f else 0.4f },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(50.dp, 30.dp)) {
            val r = size.height / 2f
            drawRoundRect(track.value, cornerRadius = CornerRadius(r, r))
            drawRoundRect(Brush.verticalGradient(listOf(Color.White.copy(0.16f), Color.Transparent)), cornerRadius = CornerRadius(r, r))
            drawRoundRect(rim, cornerRadius = CornerRadius(r, r), style = Stroke(0.8.dp.toPx()))
            val pad = 2.dp.toPx()
            val tr = r - pad
            val travel = size.width - 2 * r
            val k = if (rtl) 1f - on.value else on.value
            val cx = r + travel * k
            drawCircle(Color.Black.copy(0.18f), tr + 0.6.dp.toPx(), Offset(cx, r + 1.dp.toPx()))
            drawCircle(Color.White, tr, Offset(cx, r))
        }
    }
}

/** 22 dp rounded check box. */
@Composable
fun GlassCheckbox(checked: Boolean, onCheckedChange: ((Boolean) -> Unit)?, modifier: Modifier = Modifier, enabled: Boolean = true, label: String? = null) {
    val c = IdjThemeColors
    val haptics = rememberHaptics()
    val src = remember { MutableInteractionSource() }
    val k = animateFloatAsState(if (checked) 1f else 0f, DS.select(), label = "check")
    val shape = RoundedCornerShape(7.dp)
    Box(
        modifier.then(
            if (onCheckedChange != null) Modifier.toggleable(checked, src, null, enabled, Role.Checkbox) { haptics.toggle(it); onCheckedChange(it) }
                .then(if (label != null) Modifier.semantics { contentDescription = label } else Modifier).size(44.dp)
            else Modifier,
        ).graphicsLayer { alpha = if (enabled) 1f else 0.4f },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(22.dp).clip(shape).background(c.glass).border(1.2.dp, if (checked) c.accent else c.secondary.copy(0.55f), shape), contentAlignment = Alignment.Center) {
            Box(Modifier.matchParentSize().graphicsLayer { alpha = k.value.coerceIn(0f, 1f) }.background(c.accent))
            Icon(Icons.Rounded.Check, null, Modifier.size(16.dp).graphicsLayer { scaleX = k.value; scaleY = k.value; alpha = k.value.coerceIn(0f, 1f) }, tint = c.onAccent)
        }
    }
}

/** 22 dp radio dot. */
@Composable
fun GlassRadio(selected: Boolean, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val c = IdjThemeColors
    val k = animateFloatAsState(if (selected) 1f else 0f, DS.select(), label = "radio")
    Canvas(modifier.size(22.dp).graphicsLayer { alpha = if (enabled) 1f else 0.4f }) {
        val r = size.minDimension / 2f
        drawCircle(c.glass, r)
        drawCircle(if (selected) c.accent else c.secondary.copy(0.55f), r - 0.6.dp.toPx(), style = Stroke(1.2.dp.toPx()))
        if (k.value > 0.01f) drawCircle(c.accent, (r - 5.dp.toPx()) * k.value)
    }
}

/** Row with a title / note and a trailing check box; the whole row toggles. */
@Composable
fun CheckRow(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier, note: String? = null, enabled: Boolean = true) {
    val haptics = rememberHaptics()
    OptionRowFrame(title, note, modifier.toggleable(checked, remember { MutableInteractionSource() }, null, enabled, Role.Checkbox) { haptics.toggle(it); onCheckedChange(it) }, enabled) {
        GlassCheckbox(checked, null, enabled = enabled)
    }
}

/** Row with a trailing switch; the whole row toggles. */
@Composable
fun ToggleRow(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier, note: String? = null, enabled: Boolean = true) {
    val haptics = rememberHaptics()
    OptionRowFrame(title, note, modifier.toggleable(checked, remember { MutableInteractionSource() }, null, enabled, Role.Switch) { haptics.toggle(it); onCheckedChange(it) }, enabled) {
        GlassSwitch(checked, null, enabled = enabled)
    }
}

/** Single-choice row: accent-soft fill, accent text and ✓ when selected (`.prow`). */
@Composable
fun SelectRow(title: String, selected: Boolean, modifier: Modifier = Modifier, note: String? = null, detail: String = "", radio: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val c = IdjThemeColors
    val haptics = rememberHaptics()
    val bg by animateColorAsState(if (selected && !radio) c.accentSoft else Color.Transparent, tween(Motion.SHORT), label = "selectRow")
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(bg)
            .selectable(selected, remember { MutableInteractionSource() }, null, enabled, Role.RadioButton) { if (!selected) haptics.select(); onClick() }
            .heightIn(min = 46.dp).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (radio) GlassRadio(selected, enabled = enabled)
        Column(Modifier.weight(1f)) {
            Text(title, color = if (selected) c.accent else c.text, fontSize = 15.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
            if (note != null) Text(note, color = c.secondary, fontSize = 12.sp, lineHeight = 16.sp, modifier = Modifier.padding(top = 2.dp))
        }
        if (detail.isNotEmpty()) Text(detail, color = if (selected) c.accent.copy(0.8f) else c.secondary, fontSize = 12.sp, maxLines = 1)
        if (selected && !radio) Icon(Icons.Rounded.Check, null, Modifier.size(18.dp), tint = c.accent)
    }
}

@Composable
private fun OptionRowFrame(title: String, note: String?, modifier: Modifier, enabled: Boolean, trailing: @Composable () -> Unit) {
    val c = IdjThemeColors
    Row(
        modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 4.dp, vertical = 8.dp).graphicsLayer { alpha = if (enabled) 1f else 0.45f },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = c.text, fontSize = 15.sp)
            if (note != null) Text(note, color = c.secondary, fontSize = 12.sp, lineHeight = 16.sp, modifier = Modifier.padding(top = 2.dp))
        }
        trailing()
    }
}

// MARK: slider

/**
 * 4 dp track, 22 dp white knob; tap or drag anywhere on the 40 dp row. The track is drawn from a state read in the
 * draw phase, so a drag costs the caller only its own state write. [steps] counts the stops *between* the ends.
 */
@Composable
fun GlassSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
    steps: Int = 0,
    enabled: Boolean = true,
    onValueChangeFinished: (() -> Unit)? = null,
    colors: IdjColors = IdjThemeColors,
    label: String? = null,
    valueText: ((Float) -> String)? = null,
) {
    val haptics = rememberHaptics()
    val change by rememberUpdatedState(onValueChange)
    val finished by rememberUpdatedState(onValueChangeFinished)
    val span = (valueRange.endInclusive - valueRange.start).takeIf { it > 0f } ?: 1f
    fun snap(f: Float): Float {
        val k = f.coerceIn(0f, 1f)
        return if (steps <= 0) k else (k * (steps + 1)).roundToInt() / (steps + 1f)
    }
    val fraction = rememberUpdatedState(((value - valueRange.start) / span).coerceIn(0f, 1f))
    var dragging by remember { mutableStateOf(false) }
    val grow = animateFloatAsState(if (dragging) 1f else 0f, DS.press(), label = "sliderGrow")
    val rail = if (colors.dark) Color.White.copy(0.18f) else Color.Black.copy(0.12f)
    val tickInk = if (colors.dark) Color.White.copy(0.35f) else Color.Black.copy(0.22f)
    Canvas(
        modifier
            .fillMaxWidth()
            .height(40.dp)
            .semantics {
                if (!enabled) disabled()
                if (label != null) contentDescription = label
                if (valueText != null) stateDescription = valueText(value)
                setProgress { target ->
                    if (!enabled) return@setProgress false
                    val v = valueRange.start + snap((target - valueRange.start) / span) * span
                    if (v == value) false else { onValueChange(v); onValueChangeFinished?.invoke(); true }
                }
            }
            .progressSemantics(value.coerceIn(valueRange.start, valueRange.endInclusive), valueRange, steps)
            .graphicsLayer { alpha = if (enabled) 1f else 0.4f }
            .then(
                if (!enabled) Modifier else Modifier.pointerInput(valueRange, steps) {
                    val inset = 11.dp.toPx()
                    var last = -1f
                    fun emit(x: Float) {
                        val k = snap((x - inset) / (size.width - 2 * inset).coerceAtLeast(1f))
                        if (k == last) return
                        if (steps > 0 && last >= 0f) haptics.tick()
                        last = k
                        change(valueRange.start + k * span)
                    }
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        last = -1f
                        val drag = awaitHorizontalTouchSlopOrCancellation(down.id) { ch, _ -> ch.consume() }
                        if (drag != null) {
                            dragging = true
                            emit(drag.position.x)
                            horizontalDrag(drag.id) { ch -> ch.consume(); emit(ch.position.x) }
                            dragging = false
                            finished?.invoke()
                        } else if (currentEvent.changes.all { !it.pressed && !it.isConsumed }) {
                            emit(down.position.x)
                            finished?.invoke()
                        }
                    }
                },
            ),
    ) {
        val inset = 11.dp.toPx()
        val cy = size.height / 2f
        val th = 4.dp.toPx() + 2.dp.toPx() * grow.value
        val w = (size.width - 2 * inset).coerceAtLeast(0f)
        val x = inset + w * fraction.value
        val r = CornerRadius(th / 2f, th / 2f)
        drawRoundRect(rail, Offset(inset, cy - th / 2f), Size(w, th), r)
        drawRoundRect(colors.accent, Offset(inset, cy - th / 2f), Size((x - inset).coerceAtLeast(0f), th), r)
        if (steps in 1..24) for (i in 0..steps + 1) {
            val tx = inset + w * i / (steps + 1f)
            drawCircle(if (tx <= x) Color.White.copy(0.75f) else tickInk, 1.4.dp.toPx(), Offset(tx, cy))
        }
        val kr = 10.dp.toPx() + 1.5.dp.toPx() * grow.value
        drawCircle(Color.Black.copy(0.16f), kr + 1.dp.toPx(), Offset(x, cy + 1.dp.toPx()))
        drawCircle(Color.White, kr, Offset(x, cy))
    }
}

// MARK: progress

/** Indeterminate arc; the sweep is animated in the draw phase only. */
@Composable
fun GlassSpinner(modifier: Modifier = Modifier, size: Dp = 26.dp, color: Color = IdjThemeColors.accent, stroke: Dp = 2.4.dp) {
    val t = rememberInfiniteTransition(label = "spin")
    val angle = t.animateFloat(0f, 360f, infiniteRepeatable(tween(900, easing = LinearEasing)), label = "angle")
    val sweep = t.animateFloat(60f, 220f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "sweep")
    Canvas(modifier.size(size).progressSemantics()) {
        val s = Stroke(stroke.toPx(), cap = StrokeCap.Round)
        val inset = s.width / 2f
        val arc = Size(this.size.width - s.width, this.size.height - s.width)
        drawArc(color.copy(alpha = color.alpha * 0.18f), 0f, 360f, false, Offset(inset, inset), arc, style = s)
        drawArc(color, angle.value, sweep.value, false, Offset(inset, inset), arc, style = s)
    }
}

/** Determinate bar; [progress] is read in the draw phase. */
@Composable
fun GlassProgressBar(progress: () -> Float, modifier: Modifier = Modifier, height: Dp = 4.dp, colors: IdjColors = IdjThemeColors) {
    Box(
        modifier.fillMaxWidth().height(height).clip(CircleShape)
            .semantics { stateDescription = "${(progress().coerceIn(0f, 1f) * 100).roundToInt()}%" }
            .drawBehind {
                drawRect(if (colors.dark) Color.White.copy(0.16f) else Color.Black.copy(0.10f))
                val k = progress().coerceIn(0f, 1f)
                if (k > 0f) drawRoundRect(colors.accent, size = Size(size.width * k, size.height), cornerRadius = CornerRadius(size.height / 2f, size.height / 2f))
            },
    )
}

/** Thin indeterminate bar for list footers / page refreshes. */
@Composable
fun GlassLoadingBar(modifier: Modifier = Modifier, height: Dp = 3.dp, colors: IdjColors = IdjThemeColors) {
    val t = rememberInfiniteTransition(label = "bar")
    val k = t.animateFloat(-0.4f, 1f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "k")
    Box(modifier.fillMaxWidth().height(height).clip(CircleShape).progressSemantics().drawBehind {
        drawRect(if (colors.dark) Color.White.copy(0.10f) else Color.Black.copy(0.06f))
        drawRoundRect(colors.accent, Offset(size.width * k.value, 0f), Size(size.width * 0.4f, size.height), CornerRadius(size.height / 2f, size.height / 2f))
    })
}

// MARK: chips / segments

/** Single- or multi-choice capsule; [onMedia] = over video / artwork (dark palette). */
@Composable
fun OptionChip(text: String, selected: Boolean, modifier: Modifier = Modifier, onMedia: Boolean = false, enabled: Boolean = true, minHeight: Dp = 32.dp, icon: ImageVector? = null, onClick: () -> Unit) {
    val c = if (onMedia) IdjDarkColors else IdjThemeColors
    val haptics = rememberHaptics()
    val src = remember { MutableInteractionSource() }
    Row(
        modifier.pressScale(src).graphicsLayer { alpha = if (enabled) 1f else 0.4f }
            .glassPill(CircleShape, selected = selected, dark = c.dark, accent = c.accent)
            .selectable(selected, src, null, enabled, Role.RadioButton) { if (!selected) haptics.select(); onClick() }
            .heightIn(min = minHeight).padding(horizontal = 13.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally),
    ) {
        val ink = if (selected) c.accent else if (onMedia) Color.White.copy(0.86f) else c.text
        if (icon != null) Icon(icon, null, Modifier.size(15.dp), tint = ink)
        Text(text, color = ink, fontSize = 13.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1, softWrap = false)
    }
}

/**
 * Compact segmented control with a sliding thumb for 2–5 short options; [onMedia] draws on the dark player palette.
 * For page-level tabs use [SegmentedTabs].
 */
@Composable
fun <T> GlassSegments(
    options: List<Pair<String, T>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    onMedia: Boolean = false,
    enabled: Boolean = true,
) {
    val c = if (onMedia) IdjDarkColors else IdjThemeColors
    val haptics = rememberHaptics()
    val idx = options.indexOfFirst { it.second == selected }
    val track = RoundedCornerShape(12.dp)
    val thumb = RoundedCornerShape(9.5.dp)
    BoxWithConstraints(
        modifier.fillMaxWidth().graphicsLayer { alpha = if (enabled) 1f else 0.45f }
            .clip(track).background(if (c.dark) Color.Black.copy(0.28f) else Color.Black.copy(0.05f))
            .border(0.8.dp, if (c.dark) Color.White.copy(0.10f) else Color.Black.copy(0.06f), track).padding(2.5.dp),
    ) {
        val w = maxWidth / options.size.coerceAtLeast(1)
        if (idx >= 0) {
            val x by animateDpAsState(w * idx, DS.select(), label = "segX")
            Box(Modifier.matchParentSize()) {
                Box(
                    Modifier.offset { IntOffset(x.roundToPx(), 0) }.width(w).fillMaxHeight()
                        .then(if (c.dark) Modifier else Modifier.shadow(2.dp, thumb, ambientColor = c.shadowThumb, spotColor = c.shadowThumb))
                        .clip(thumb).background(if (c.dark) Color.White.copy(0.17f) else Color.White)
                        .border(0.8.dp, if (c.dark) Color.White.copy(0.16f) else Color.Black.copy(0.04f), thumb),
                )
            }
        }
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
            options.forEachIndexed { i, (label, value) ->
                val on = i == idx
                Box(
                    Modifier.weight(1f).fillMaxHeight().heightIn(min = 32.dp).clip(thumb)
                        .selectable(on, remember { MutableInteractionSource() }, null, enabled, Role.Tab) { if (!on) { haptics.select(); onSelect(value) } }
                        .padding(horizontal = 4.dp, vertical = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(label, color = if (on) (if (onMedia) Color.White else c.text) else c.secondary, fontSize = 12.5.sp,
                        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}
