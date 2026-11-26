package app.iduanju.ui.profile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import app.iduanju.IdjApp
import app.iduanju.core.hongguo.*
import app.iduanju.ui.LocalNavigate
import app.iduanju.ui.components.ErrorState
import app.iduanju.ui.components.LocalLayoutMetrics
import app.iduanju.ui.components.PosterSkeleton
import app.iduanju.ui.components.pressClick
import app.iduanju.ui.home.HomePosterCard
import app.iduanju.ui.theme.IdjThemeColors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Kept per page so coming back from a drama shows the same list without a reload. */
class ActorProfileState : ViewModel() {
    val profile = mutableStateOf<HGActorProfile?>(null)
    val works = mutableStateOf<HGActorWorks?>(null)
}

@Composable
fun ActorProfileScreen(actor: HGCelebrity, onBack: () -> Unit, onOpen: (String) -> Unit) {
    val client = IdjApp.instance.hongguo
    val vm: ActorProfileState = viewModel()
    var profile by vm.profile
    var works by vm.works
    var error by remember(actor.id) { mutableStateOf<String?>(null) }
    var attempt by remember(actor.id) { mutableIntStateOf(0) }
    LaunchedEffect(actor.id, attempt) {
        error = null
        if (works != null && profile != null) return@LaunchedEffect
        launch {
            try { profile = withContext(Dispatchers.IO) { client.celebrityProfile(actor.id) } }
            catch (e: CancellationException) { throw e }
            catch (_: Exception) { /* The ranking provides the initial profile. */ }
        }
        try { works = withContext(Dispatchers.IO) { client.celebrityWorks(actor.id) } }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { error = e.message ?: "作品加载失败" }
    }
    val c = IdjThemeColors
    val go = LocalNavigate.current
    val name = profile?.actor?.name.orEmpty().ifBlank { actor.name }
    val intro = profile?.actor?.intro.orEmpty().ifBlank { actor.intro }
    val cols = LocalLayoutMetrics.current.posterCols
    val grid = rememberLazyGridState()
    val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val full: LazyGridItemSpanScope.() -> GridItemSpan = { GridItemSpan(maxLineSpan) }
    SubPage(name, onBack, { grid.firstVisibleItemIndex > 0 || grid.firstVisibleItemScrollOffset > 4 }) { top ->
        LazyVerticalGrid(GridCells.Fixed(cols), Modifier.fillMaxSize(), grid, PaddingValues(start = 16.dp, end = 16.dp, top = top + 12.dp, bottom = bottom + 24.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item("actor", full, "actor") {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    ActorAvatar(profile?.actor?.avatar.orEmpty().ifBlank { actor.avatar }, 104.dp)
                    Text(name, fontSize = 26.sp, fontWeight = FontWeight.Bold, color = c.text, modifier = Modifier.semantics { heading() })
                    if (actor.role.isNotBlank()) Text(actor.role, color = c.secondary, fontSize = 14.sp)
                }
            }
            if (intro.isNotBlank()) item("intro", full, "intro") {
                SelectionContainer { Text(intro, color = c.secondary, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 4.dp)) }
            }
            val related = profile?.related.orEmpty()
            if (related.isNotEmpty()) item("related", full, "related") {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("合作演员", color = c.text, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.semantics { heading() })
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        items(related, key = { it.id }, contentType = { "actor" }) { other ->
                            Column(Modifier.width(68.dp).pressClick(label = other.name) { go(actorRoute(other)) }, horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                ActorAvatar(other.avatar, 56.dp)
                                Text(other.name, color = c.text, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
            item("works", full, "header") {
                Text(works?.total?.takeIf { it > 0 }?.let { "参演作品 · $it" } ?: "参演作品", color = c.text, fontSize = 20.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.semantics { heading() })
            }
            items(works?.items.orEmpty(), key = { it.seriesId }, contentType = { "poster" }) { HomePosterCard(it, onOpen) }
            if (works?.items.isNullOrEmpty()) when {
                error != null -> item("error", full, "state") { ErrorState("加载失败", note = error) { attempt++ } }
                works == null -> items(cols * 2, key = { "skeleton$it" }, contentType = { "skeleton" }) { PosterSkeleton() }
                else -> item("empty", full, "state") { Text("暂无作品", color = c.secondary, fontSize = 15.sp) }
            }
        }
    }
}
