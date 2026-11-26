package app.iduanju.novel

import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.*
import androidx.compose.foundation.text.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.*
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import app.iduanju.core.novel.*
import app.iduanju.ui.components.*
import app.iduanju.ui.theme.IdjColors
import app.iduanju.ui.theme.IdjDarkColors
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.*

private val Accent=Color(0xFF309714)
private val Digits=TextStyle(fontFeatureSettings="tnum")

/** The app palette on the reading theme's paper, so every shared control inside the reader follows it. */
@Composable internal fun readerColors(theme:Int):IdjColors=remember(theme){
    val p=ReaderPalette.of(theme);val ink=Color(p.ink);val secondary=Color(p.secondary);val track=Color(p.track)
    IdjDarkColors.copy(
        dark=theme==3,bg=Color(p.bg),surface=Color(p.panel),elevated=track,text=ink,secondary=secondary,tertiary=secondary.copy(alpha=.65f),
        accent=Accent,accentSoft=Accent.copy(alpha=.12f),accentLine=Accent.copy(alpha=.6f),onAccent=Color.White,
        glass=track.copy(alpha=.75f),glassBorder=secondary.copy(alpha=.2f),hairline=secondary.copy(alpha=.15f),
        card=Color(p.bg).copy(alpha=.7f),cardBorder=secondary.copy(alpha=.12f),thumb=Color(p.thumb),sheet=Color(p.panel),
        danger=if(theme==3)Color(0xFFFF6B6B) else Color(0xFFB34747),
    )
}

@Composable internal fun ReaderTocPanel(chapters:List<NovelChapter>,current:Int,offset:Int,bodyLength:Int,pages:Int,s:ReaderSettings,onJump:(Int,Int)->Unit,onSearch:suspend(String)->List<NovelCache.SearchHit>){
    val p=ReaderPalette.of(s.theme);val ink=Color(p.ink);val secondary=Color(p.secondary);val colors=readerColors(s.theme)
    var searching by remember{mutableStateOf(false)};var query by remember{mutableStateOf("")};var hits by remember{mutableStateOf<List<NovelCache.SearchHit>>(emptyList())};var searchingText by remember{mutableStateOf(false)};var error by remember{mutableStateOf<String?>(null)}
    val scope=rememberCoroutineScope();val keyboard=LocalSoftwareKeyboardController.current
    fun search(){scope.launch{searchingText=true;error=null;try{hits=onSearch(query)}catch(e:CancellationException){throw e}catch(e:Exception){error=e.message}finally{searchingText=false}}}
    val per=(bodyLength.toDouble()/pages.coerceAtLeast(1)).coerceAtLeast(1.0)
    val state=rememberLazyListState((current-2).coerceAtLeast(0))
    // The field is one half of the capsule switch: it only gets a well of its own while it is the active half.
    val fieldColors=remember(colors,searching){colors.copy(glass=if(searching)colors.bg else Color.Transparent,hairline=Color.Transparent,accentLine=Color.Transparent)}
    Column(Modifier.height(460.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(10.dp)){
        Box(Modifier.size(36.dp,4.dp).background(secondary.copy(alpha=.4f),CircleShape))
        Row(Modifier.fillMaxWidth().background(Color(p.track).copy(alpha=.7f),CircleShape).padding(3.dp),verticalAlignment=Alignment.CenterVertically){
            GlassTextField(query,{query=it;searching=true},Modifier.weight(1f),placeholder="搜本书",icon=Icons.Outlined.Search,capsule=true,minHeight=44.dp,fontSize=14.sp,colors=fieldColors,
                keyboardOptions=KeyboardOptions(imeAction=ImeAction.Search),keyboardActions=KeyboardActions(onSearch={keyboard?.hide();search()}),
                fieldModifier=Modifier.onFocusChanged{if(it.isFocused)searching=true}.testTag("novel.toc.search"))
            val tab=remember{MutableInteractionSource()}
            Box(Modifier.weight(1f).pressScale(tab).clip(CircleShape).background(if(!searching)Color(p.bg) else Color.Transparent).selectable(!searching,tab,null,true,Role.Tab){searching=false;query="";hits=emptyList();keyboard?.hide()}.heightIn(min=44.dp).testTag("novel.toc.tab"),contentAlignment=Alignment.Center){Text("目录",color=ink,fontSize=14.sp,fontWeight=FontWeight.Medium)}
        }
        if(searching){
            if(searchingText)GlassLoadingBar()
            LazyColumn(Modifier.fillMaxWidth().weight(1f).testTag("novel.toc.results")){
                error?.let{item(key="error"){Text(it,color=colors.danger,fontSize=13.sp)}}
                itemsIndexed(hits,key={i,_->i},contentType={_,_->"hit"}){_,h->Column{
                    Column(Modifier.fillMaxWidth().pressClick(.985f){onJump(h.chapter,h.offset)}.padding(vertical=10.dp).testTag("novel.toc.hit.${h.chapter}.${h.offset}")){
                        Text(chapters.getOrNull(h.chapter)?.title.orEmpty(),color=secondary,fontSize=12.sp,lineHeight=14.sp)
                        Spacer(Modifier.height(4.dp));Text(h.snippet,color=ink,fontSize=15.sp,lineHeight=18.sp,maxLines=2)
                    }
                    Hairline()
                }}
                if(hits.isEmpty()&&query.isNotEmpty()&&!searchingText)item(key="none"){Text("没有找到",color=secondary,modifier=Modifier.padding(top=20.dp))}
            }
        } else LazyColumn(state=state,modifier=Modifier.fillMaxWidth().weight(1f).testTag("novel.toc")){
            items(chapters.size,key={it},contentType={"chapter"}){i->Column{
                Row(Modifier.fillMaxWidth().pressClick(.985f){onJump(i,0)}.heightIn(min=46.dp).padding(vertical=13.dp).testTag("novel.chapter.$i"),verticalAlignment=Alignment.CenterVertically){
                    Text(chapters[i].title,color=ink,fontSize=16.sp,lineHeight=19.sp,fontWeight=if(i==current)FontWeight.Bold else FontWeight.Normal,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f))
                    Spacer(Modifier.width(12.dp));Text("${(i*1000/per).toInt()+1}",color=secondary,fontSize=13.sp,lineHeight=16.sp,style=Digits)
                }
                if(i==current)Row(Modifier.fillMaxWidth().padding(start=14.dp,bottom=12.dp),verticalAlignment=Alignment.CenterVertically){Icon(Icons.Outlined.MenuBook,null,tint=Accent,modifier=Modifier.size(15.dp));Spacer(Modifier.width(6.dp));Text("当前读到",color=Accent,fontSize=14.sp,lineHeight=17.sp);Spacer(Modifier.weight(1f));Text("${((i*1000+offset)/per).toInt()+1}",color=secondary,fontSize=13.sp,lineHeight=16.sp,style=Digits)}
                Hairline()
            }}
        }
    }
}

@Composable internal fun ReaderInfoPanel(title:String,author:String,cover:String,chapters:Int,source:String,addedAt:Long,timeMs:Long,s:ReaderSettings){
    val p=ReaderPalette.of(s.theme);val ink=Color(p.ink);val secondary=Color(p.secondary)
    val added=remember(addedAt){if(addedAt>0)java.text.SimpleDateFormat(android.text.format.DateFormat.getBestDateTimePattern(java.util.Locale.getDefault(),"MMMd"),java.util.Locale.getDefault()).format(java.util.Date(addedAt)) else "—"}
    @Composable fun cell(v:String,k:String){Column(horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(4.dp)){Text(v,color=ink,fontSize=15.sp,lineHeight=18.sp,fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis);Text(k,color=secondary,fontSize=11.sp,lineHeight=13.sp)}}
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Color(p.bg).copy(alpha=.7f)).padding(16.dp),verticalArrangement=Arrangement.spacedBy(14.dp)){
        Row(verticalAlignment=Alignment.Top,horizontalArrangement=Arrangement.spacedBy(12.dp)){
            Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)){Text(title,color=ink,fontSize=18.sp,lineHeight=22.sp,fontWeight=FontWeight.Bold,maxLines=2);Text((if(author.isBlank())"" else "$author · ")+"时长 ${timeMs/3600000}时${timeMs/60000%60}分",color=secondary,fontSize=13.sp,lineHeight=16.sp)}
            if(cover.isNotBlank()){
                val context=LocalContext.current;val density=LocalDensity.current
                val request=remember(cover,density){with(density){ImageRequest.Builder(context).data(cover).size(52.dp.roundToPx(),72.dp.roundToPx()).build()}}
                AsyncImage(request,null,Modifier.size(52.dp,72.dp).clip(RoundedCornerShape(5.dp)),contentScale=ContentScale.Crop)
            }
        }
        Hairline()
        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp)){listOf("$chapters" to "章节",source to "书源",added to "导入").forEach{(v,k)->Box(Modifier.weight(1f),contentAlignment=Alignment.Center){cell(v,k)}}}
    }
}

@Composable internal fun ReaderProgressStats(fraction:Float,current:Int,total:Int,timeMs:Long,s:ReaderSettings){
    val p=ReaderPalette.of(s.theme)
    @Composable fun cell(big:String,unit:String,sub:String){Column(horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(4.dp)){Row(verticalAlignment=Alignment.Bottom){Text(big,color=Color(p.ink),fontSize=22.sp,lineHeight=26.sp,fontWeight=FontWeight.SemiBold,style=Digits);Text(unit,color=Color(p.ink),fontSize=12.sp,modifier=Modifier.padding(bottom=2.dp))};Text(sub,color=Color(p.secondary),fontSize=11.sp,lineHeight=13.sp)}}
    @Composable fun rule()=Box(Modifier.width(1.dp).height(34.dp).background(Color(p.secondary).copy(alpha=.2f)))
    Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){Box(Modifier.weight(1f),contentAlignment=Alignment.Center){cell("${(fraction*100).toInt()}","%","还剩 ${(total-current-1).coerceAtLeast(0)} 章")};rule();Box(Modifier.weight(1f),contentAlignment=Alignment.Center){cell("${if(timeMs>=3600000)timeMs/3600000 else timeMs/60000}",if(timeMs>=3600000)"小时${timeMs/60000%60}分钟" else "分钟","阅读时长")};rule();Box(Modifier.weight(1f),contentAlignment=Alignment.Center){cell("${current+1}","/$total","章节")}}
}
