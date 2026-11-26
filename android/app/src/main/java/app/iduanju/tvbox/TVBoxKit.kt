package app.iduanju.tvbox

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.iduanju.core.tvbox.SiteKind
import app.iduanju.ui.components.ButtonTone
import app.iduanju.ui.components.DSStatus
import app.iduanju.ui.components.DialogAction
import app.iduanju.ui.components.EmptyState
import app.iduanju.ui.components.GlassAlert
import app.iduanju.ui.components.GlassBottomSheet
import app.iduanju.ui.components.GlassSpinner
import app.iduanju.ui.components.GlassSwitch
import app.iduanju.ui.components.GlassTextField
import app.iduanju.ui.components.Hairline
import app.iduanju.ui.components.PillTone
import app.iduanju.ui.components.StatusTone
import app.iduanju.ui.components.dsCard
import app.iduanju.ui.components.rowClick
import app.iduanju.ui.theme.IdjThemeColors

// Building blocks of the TVBox screens on the app's design tokens (no stock Material dialogs, switches or text fields).

/** Bottom sheet: title on the left, optional action on the right, at most 86 % of the height. */
@Composable
fun TvSheet(title: String, onDismiss: () -> Unit, trailing: @Composable () -> Unit = {}, content: @Composable ColumnScope.() -> Unit) {
    val c = IdjThemeColors
    val max = LocalConfiguration.current.screenHeightDp.dp * 0.86f
    GlassBottomSheet(onDismiss, Modifier.heightIn(max = max), contentPadding = PaddingValues(0.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 14.dp, top = 6.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = c.text, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).semantics { heading() })
            trailing()
        }
        content()
    }
}

/** Centred glass dialog with one or two actions; [PillTone.Ink] marks a destructive one. */
@Composable
fun TvDialog(title: String, confirm: String, onConfirm: () -> Unit, onDismiss: () -> Unit, dismiss: String? = "取消", tone: PillTone = PillTone.Accent, enabled: Boolean = true, content: @Composable ColumnScope.() -> Unit) =
    GlassAlert(
        onDismiss, title,
        listOfNotNull(
            dismiss?.let { DialogAction(it, onClick = onDismiss) },
            DialogAction(confirm, if (tone == PillTone.Ink) ButtonTone.Danger else ButtonTone.Primary, enabled, onClick = onConfirm),
        ),
        content = content,
    )

@Composable
fun TvText(text: String, modifier: Modifier = Modifier) = Text(text, modifier, color = IdjThemeColors.secondary, fontSize = 14.sp, lineHeight = 21.sp)

@Composable
fun TvSwitch(checked: Boolean, label: String, enabled: Boolean = true, onChange: (Boolean) -> Unit) = GlassSwitch(checked, onChange, enabled = enabled, label = label)

/** Single- or multi-line input of the design kit. */
@Composable
fun TvField(
    value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier, icon: ImageVector? = null, singleLine: Boolean = true, minHeight: Int = 44,
    ime: ImeAction = ImeAction.Done, keyboard: KeyboardOptions = KeyboardOptions.Default, onAction: () -> Unit = {}, trailing: @Composable RowScope.() -> Unit = {},
) = GlassTextField(
    value, onChange, modifier.fillMaxWidth(), placeholder = placeholder, icon = icon, singleLine = singleLine, capsule = singleLine, minHeight = minHeight.dp,
    keyboardOptions = keyboard.copy(imeAction = ime), keyboardActions = KeyboardActions(onDone = { onAction() }, onSearch = { onAction() }, onGo = { onAction() }),
    fieldModifier = Modifier.semantics { contentDescription = placeholder }, trailing = trailing,
)

@Composable
fun TvSearchField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier, onSearch: () -> Unit = {}, trailing: @Composable RowScope.() -> Unit = {}) =
    TvField(value, onChange, placeholder, modifier, Icons.Rounded.Search, ime = ImeAction.Search, onAction = onSearch, trailing = trailing)

/** Settings-style row. */
@Composable
fun TvRow(title: String, sub: String? = null, modifier: Modifier = Modifier, selected: Boolean = false, warn: Boolean = false, leading: @Composable () -> Unit = {}, onClick: (() -> Unit)? = null, trailing: @Composable RowScope.() -> Unit = {}) {
    val c = IdjThemeColors
    Row(
        modifier.fillMaxWidth().then(if (onClick != null) Modifier.rowClick(onClick = onClick) else Modifier).heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        leading()
        Column(Modifier.weight(1f)) {
            Text(title, color = if (selected) c.accent else c.text, fontSize = 15.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!sub.isNullOrEmpty()) Text(sub, color = if (warn) c.accentWarm else c.secondary, fontSize = 12.sp, lineHeight = 17.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 2.dp))
        }
        trailing()
        if (selected) Icon(Icons.Rounded.Check, "当前", Modifier.size(18.dp), tint = c.accent)
    }
}

@Composable
fun TvGroup(title: String? = null, note: String? = null, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val c = IdjThemeColors
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        if (title != null) Text(title, color = c.secondary, fontSize = 13.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 4.dp, bottom = 8.dp))
        Column(Modifier.fillMaxWidth().dsCard(18.dp), content = content)
        if (note != null) Text(note, color = c.tertiary, fontSize = 12.sp, lineHeight = 17.sp, modifier = Modifier.padding(start = 4.dp, end = 4.dp, top = 8.dp))
    }
}

@Composable
fun TvDivider() = Hairline(Modifier.padding(start = 16.dp))

@Composable
fun KindBadge(kind: SiteKind) = DSStatus(kind.badge, when (kind) {
    SiteKind.CmsXml, SiteKind.CmsJson -> StatusTone.Ok
    SiteKind.Remote -> StatusTone.Accent
    SiteKind.Js, SiteKind.Py, SiteKind.Jar -> StatusTone.Warn
    SiteKind.Unsupported -> StatusTone.Muted
})

@Composable
fun TvSpinner(size: Int = 22) = GlassSpinner(size = size.dp, stroke = 2.dp)

/** Centred message with an optional action. */
@Composable
fun TvEmpty(title: String, note: String? = null, action: String? = null, modifier: Modifier = Modifier, onAction: () -> Unit = {}) =
    EmptyState(title, modifier.padding(vertical = 20.dp), note, actionText = action, onAction = onAction)

/** Trust question, asked once per config before any of its code runs. */
@Composable
fun TrustDialog(repo: TVBoxRepo, onAnswer: (Boolean) -> Unit, onDismiss: () -> Unit) {
    val counts = remember(repo.id, repo.config) {
        val kinds = repo.config.sites.groupingBy { it.kind }.eachCount()
        listOf(SiteKind.Jar, SiteKind.Js, SiteKind.Py).mapNotNull { k -> kinds[k]?.let { "${k.badge} $it 个" } }.joinToString("、").ifEmpty { "扩展解析或直播脚本" }
    }
    TvDialog("信任「${repo.name}」？", "信任并启用", { onAnswer(true) }, onDismiss, dismiss = "暂不", content = {
        TvText("这个配置包含会在你的设备上运行的代码：$counts。请只信任来源可靠的配置。")
        Spacer(Modifier.height(8.dp))
        TvText("不信任时这些站点不会加载，CMS、T4 和直播照常使用；之后可以在配置管理里随时更改。")
    })
}
