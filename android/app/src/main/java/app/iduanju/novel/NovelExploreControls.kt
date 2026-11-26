package app.iduanju.novel

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import app.iduanju.core.novel.NovelCategory
import app.iduanju.ui.components.*
import app.iduanju.ui.theme.IdjThemeColors
import kotlinx.coroutines.delay

/** Source-defined controls are not URL categories. Flex width/wrap is honored outside the narrow rail. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun NovelExploreControls(controls:List<NovelCategory>,enabled:Boolean,onAction:(NovelCategory,String?)->Unit) {
    if(controls.isEmpty())return
    Box(Modifier.fillMaxWidth().heightIn(max=240.dp).verticalScroll(rememberScrollState()).padding(horizontal=16.dp,vertical=4.dp)) {
        SourceControlFlex(controls) {
            controls.forEach { c ->
                Box(Modifier.testTag("novel.filter."+c.title)) {
                    when(c.type) {
                        "text" -> {
                            var text by remember(c.selectionKey,c.value){mutableStateOf(c.value)}
                            val action by rememberUpdatedState(onAction)
                            LaunchedEffect(text,enabled){if(enabled&&text!=c.value){delay(450);action(c,text)}}
                            GlassTextField(text,{text=it},Modifier.widthIn(min=140.dp),label=c.displayTitle,enabled=enabled)
                        }
                        "select" -> {
                            var open by remember{mutableStateOf(false)}
                            ControlPill(c.displayTitle+"："+c.value+" ▾",false,enabled){open=true}
                            GlassMenu(expanded=open,onDismissRequest={open=false}){c.chars.forEach { value -> GlassMenuItem(value,selected=value==c.value){open=false;onAction(c,value)} }}
                        }
                        "toggle" -> ControlPill(c.value+c.displayTitle,c.chars.indexOf(c.value)>0,enabled,toggle=true){onAction(c,null)}
                        else -> ControlPill(c.displayTitle,false,enabled){onAction(c,null)}
                    }
                }
            }
        }
    }
}

/** [OptionChip] with a centred label: the source's flex layout stretches these cells across the row. */
@Composable
private fun ControlPill(text:String,selected:Boolean,enabled:Boolean,toggle:Boolean=false,onClick:()->Unit) {
    val c=IdjThemeColors
    val haptics=rememberHaptics()
    val src=remember{MutableInteractionSource()}
    Box(
        Modifier.fillMaxWidth().pressScale(src).graphicsLayer{alpha=if(enabled)1f else 0.4f}
            .glassPill(CircleShape,selected=selected)
            .then(if(toggle)Modifier.toggleable(selected,src,null,enabled,Role.Checkbox){haptics.toggle(it);onClick()} else Modifier.clickable(src,null,enabled=enabled,role=Role.Button,onClick=onClick))
            .heightIn(min=40.dp).padding(horizontal=13.dp,vertical=6.dp),
        contentAlignment=Alignment.Center,
    ) {
        Text(text,color=if(selected)c.accent else c.text,fontSize=13.sp,fontWeight=if(selected)FontWeight.SemiBold else FontWeight.Normal,maxLines=1,overflow=TextOverflow.Ellipsis,textAlign=TextAlign.Center)
    }
}

/** Same flex-basis + flex-grow + wrap-before contract as the source, without synthetic blank rows.
 * FlowRow's weight is not equivalent: combining it with a fixed basis previously discarded grow,
 * leaving three filter chips squeezed into 60% of the row. This layout distributes remaining width.
 */
@Composable
private fun SourceControlFlex(controls:List<NovelCategory>,content:@Composable ()->Unit) {
    Layout(content=content,modifier=Modifier.fillMaxWidth()) { nodes,constraints ->
        val width=constraints.maxWidth
        val gap=6.dp.roundToPx()
        val rows=mutableListOf<MutableList<Pair<Int,Int>>>()
        var row=mutableListOf<Pair<Int,Int>>()
        var used=0
        nodes.forEachIndexed { i,node ->
            val style=controls[i].style
            val basis=if(style.basis>0)(width*style.basis.coerceAtMost(1.0)).roundToInt() else node.maxIntrinsicWidth(Constraints.Infinity)
            val w=basis.coerceIn(0,width)
            if(row.isNotEmpty()&&(style.wrapBefore||used+gap+w>width)){rows.add(row);row=mutableListOf();used=0}
            if(row.isNotEmpty())used+=gap
            row.add(i to w);used+=w
        }
        if(row.isNotEmpty())rows.add(row)
        val measured=rows.map { r ->
            val extra=(width-r.sumOf{it.second}-gap*(r.size-1)).coerceAtLeast(0)
            val grow=r.sumOf { controls[it.first].style.grow.coerceAtLeast(0.0) }
            r.map { (i,w) ->
                val share=if(grow>0)(extra*controls[i].style.grow.coerceAtLeast(0.0)/grow).toInt() else 0
                nodes[i].measure(Constraints.fixedWidth((w+share).coerceAtMost(width)))
            }
        }
        val height=measured.sumOf{r->r.maxOfOrNull{it.height}?:0}+gap*(measured.size-1).coerceAtLeast(0)
        layout(width,height){
            var y=0
            measured.forEach { r -> var x=0;r.forEach{it.placeRelative(x,y);x+=it.width+gap};y+=(r.maxOfOrNull{it.height}?:0)+gap }
        }
    }
}
