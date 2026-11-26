package app.iduanju.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.ui.theme.IdjColors
import app.iduanju.ui.theme.IdjThemeColors

/**
 * Text field of the design kit: 46 dp glass well (grows with the text), hairline that turns accent on focus and red on
 * [error], optional caption above. [capsule] = search style. [fieldModifier] goes on the editable node itself (test
 * tags, focus requesters); [modifier] on the whole block including caption and footnote.
 */
@Composable
fun GlassTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "",
    label: String? = null,
    icon: ImageVector? = null,
    singleLine: Boolean = true,
    minLines: Int = 1,
    maxLines: Int = if (singleLine) 1 else 8,
    enabled: Boolean = true,
    readOnly: Boolean = false,
    secure: Boolean = false,
    clearable: Boolean = singleLine,
    error: String? = null,
    supporting: String? = null,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    fontSize: TextUnit = 15.sp,
    capsule: Boolean = false,
    minHeight: Dp = 46.dp,
    colors: IdjColors = IdjThemeColors,
    fieldModifier: Modifier = Modifier,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    val c = colors
    val src = remember { MutableInteractionSource() }
    val focused by src.collectIsFocusedAsState()
    var reveal by remember { mutableStateOf(false) }
    val line by animateColorAsState(
        when { error != null -> c.danger; focused -> c.accentLine; else -> c.hairline }, tween(Motion.SHORT), label = "fieldLine")
    val shape: Shape = if (capsule) CircleShape else RoundedCornerShape(14.dp)
    val edge = if (clearable || secure || trailing != null) 6.dp else 14.dp
    Column(modifier) {
        if (label != null) Text(label, color = c.secondary, fontSize = 13.sp, modifier = Modifier.padding(start = 4.dp, bottom = 6.dp))
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = fieldModifier.fillMaxWidth()
                .semantics {
                    if (label != null) contentDescription = label
                    if (error != null) error(error)
                },
            enabled = enabled,
            readOnly = readOnly,
            singleLine = singleLine,
            minLines = minLines,
            maxLines = maxLines,
            textStyle = TextStyle(color = if (enabled) c.text else c.tertiary, fontSize = fontSize, lineHeight = fontSize * 1.4f),
            cursorBrush = SolidColor(c.accent),
            visualTransformation = if (secure && !reveal) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = keyboardOptions,
            keyboardActions = keyboardActions,
            interactionSource = src,
            decorationBox = { inner ->
                Row(
                    Modifier.fillMaxWidth().clip(shape).background(c.glass).border(1.dp, line, shape)
                        .heightIn(min = minHeight)
                        .padding(start = if (capsule) 16.dp else 14.dp, end = edge, top = if (singleLine) 4.dp else 11.dp, bottom = if (singleLine) 4.dp else 11.dp),
                    verticalAlignment = if (singleLine) Alignment.CenterVertically else Alignment.Top,
                ) {
                    if (icon != null) { Icon(icon, null, Modifier.size(19.dp), tint = c.secondary); Spacer(Modifier.width(10.dp)) }
                    Box(Modifier.weight(1f), contentAlignment = if (singleLine) Alignment.CenterStart else Alignment.TopStart) {
                        if (value.isEmpty() && placeholder.isNotEmpty()) {
                            Text(placeholder, color = c.tertiary, fontSize = fontSize, lineHeight = fontSize * 1.4f, maxLines = if (singleLine) 1 else 4)
                        }
                        inner()
                    }
                    if (secure) FieldIcon(if (reveal) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility, if (reveal) "隐藏" else "显示", c) { reveal = !reveal }
                    if (clearable && value.isNotEmpty() && enabled && !readOnly) FieldIcon(Icons.Rounded.Cancel, "清除", c) { onValueChange("") }
                    trailing?.invoke(this)
                }
            },
        )
        val foot = error ?: supporting
        if (foot != null) Text(foot, color = if (error != null) c.danger else c.secondary, fontSize = 12.sp, lineHeight = 16.sp, modifier = Modifier.padding(start = 4.dp, top = 5.dp))
    }
}

/** Capsule search field with a magnifier and the search IME action. */
@Composable
fun GlassSearchField(
    value: String, onValueChange: (String) -> Unit, modifier: Modifier = Modifier, placeholder: String = "搜索", colors: IdjColors = IdjThemeColors,
    minHeight: Dp = 44.dp, fieldModifier: Modifier = Modifier, onSearch: () -> Unit = {},
) = GlassTextField(
    value, onValueChange, modifier, placeholder = placeholder, icon = Icons.Rounded.Search, capsule = true, colors = colors, minHeight = minHeight,
    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { onSearch() }), fieldModifier = fieldModifier,
)

@Composable
private fun FieldIcon(icon: ImageVector, label: String, c: IdjColors, onClick: () -> Unit) {
    Box(Modifier.size(36.dp).clickable(remember { MutableInteractionSource() }, null, role = Role.Button, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, Modifier.size(18.dp), tint = c.secondary)
    }
}
