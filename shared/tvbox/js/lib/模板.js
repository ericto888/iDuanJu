// Rule presets for common 苹果 CMS themes (`模板: '…'` in drpy rules). Selectors written for this project from the themes' public
// markup, GPL-3.0. A rule set that ships its own 模板.js next to its engine keeps using that one.

const common = {
  host: '', headers: { 'User-Agent': 'MOBILE_UA' }, timeout: 5000, searchable: 2, quickSearch: 0, filterable: 0, limit: 6, double: true, play_parse: true,
  lazy: "js:var html=JSON.parse(request(input).match(/r player_.*?=(.*?)</)[1]);var url=html.url;if(html.encrypt=='1'){url=unescape(url)}else if(html.encrypt=='2'){url=unescape(base64Decode(url))}if(/\\.(m3u8|mp4|flv)/.test(url)){input={jx:0,parse:0,url:url}}else{input}",
};
const theme = extra => Object.assign({}, common, extra);

const mubanDict = {
  mxpro: theme({
    url: '/vodshow/fyclass--------fypage---.html', searchUrl: '/vodsearch/**----------fypage---.html',
    class_parse: '.navbar-items li:gt(0):lt(10);a&&Text;a&&href;/(\\d+)',
    推荐: '.tab-list.active;a.module-poster-item.module-item;.module-poster-item-title&&Text;.lazyload&&data-original;.module-item-note&&Text;a&&href',
    一级: 'body a.module-poster-item.module-item;a&&title;.lazyload&&data-original;.module-item-note&&Text;a&&href',
    二级: {
      title: 'h1&&Text;.module-info-tag-link:eq(-1)&&Text', img: '.lazyload&&data-original||data-src||src',
      desc: '.module-info-item:eq(-2)&&Text;.module-info-tag-link&&Text;.module-info-tag-link:eq(1)&&Text;.module-info-item:eq(2)&&Text;.module-info-item:eq(1)&&Text',
      content: '.module-info-introduction&&Text', tabs: '.module-tab-item', lists: '.module-play-list:eq(#id) a', tab_text: 'div--small&&Text',
    },
    搜索: 'body .module-item;.module-card-item-title&&Text;.lazyload&&data-original;.module-item-note&&Text;a&&href;.module-info-item-content&&Text',
  }),
  首图: theme({
    url: '/vodshow/fyclass--------fypage---/', searchUrl: '/vodsearch/**----------fypage---.html',
    class_parse: '.myui-header__menu li.hidden-sm:gt(0):lt(7);a&&Text;a&&href;/(\\d+).html',
    推荐: 'ul.myui-vodlist.clearfix;li;a&&title;a&&data-original;.pic-text&&Text;a&&href',
    一级: '.myui-vodlist li;a&&title;a&&data-original;.pic-text&&Text;a&&href',
    二级: {
      title: '.myui-content__detail .title--span&&Text;.myui-content__detail p.data:eq(3)&&Text', img: '.myui-content__thumb .lazyload&&data-original',
      desc: '.myui-content__detail p.otherbox&&Text;.year&&Text;.myui-content__detail p.data:eq(4)&&Text;.myui-content__detail p.data:eq(2)&&Text;.myui-content__detail p.data:eq(0)&&Text',
      content: '.content&&Text', tabs: '.myui-panel__head:has(h3) h3', lists: '.myui-content__list:eq(#id) li',
    },
    搜索: '#searchList li;a&&title;.lazyload&&data-original;.pic-text&&Text;a&&href;.detail&&Text',
  }),
  首图2: theme({
    url: '/list/fyclass-fypage.html', searchUrl: '/vodsearch/**----------fypage---.html',
    class_parse: '.stui-header__menu li:gt(0):lt(7);a&&Text;a&&href;/(\\d+)',
    推荐: 'ul.stui-vodlist.clearfix;li;a&&title;.lazyload&&data-original;.pic-text&&Text;a&&href',
    一级: '.stui-vodlist li;a&&title;a&&data-original;.pic-text&&Text;a&&href',
    二级: {
      title: '.stui-content__detail .title&&Text;.stui-content__detail p:eq(-2)&&Text', img: '.stui-content__thumb .lazyload&&data-original',
      desc: '.stui-content__detail p:eq(0)&&Text;.stui-content__detail p:eq(1)&&Text;;.stui-content__detail p:eq(2)&&Text;.stui-content__detail p:eq(3)&&Text',
      content: '.detail&&Text', tabs: '.stui-vodlist__head h3', lists: '.stui-content__playlist:eq(#id) li',
    },
    搜索: 'ul.stui-vodlist__media li;a&&title;.lazyload&&data-original;.pic-text&&Text;a&&href;.detail&&Text',
  }),
  vfed: theme({
    url: '/index.php/vod/show/id/fyclass/page/fypage.html', searchUrl: '/index.php/vod/search/page/fypage/wd/**.html',
    class_parse: '.fed-pops-navbar&&ul.fed-part-rows&&a;a&&Text;a&&href;.*/(.*?).html',
    推荐: 'ul.fed-list-info.fed-part-rows;li;a.fed-list-title&&Text;a&&data-original;.fed-list-remarks&&Text;a&&href',
    一级: '.fed-list-info&&li;a.fed-list-title&&Text;a&&data-original;.fed-list-remarks&&Text;a&&href',
    二级: {
      title: 'h1.fed-part-eone&&Text;.fed-deta-content&&.fed-part-rows&&li&&Text', img: '.fed-list-info&&a&&data-original',
      desc: '.fed-deta-content&&.fed-part-rows&&li:eq(1)&&Text;.fed-deta-content&&.fed-part-rows&&li:eq(2)&&Text;.fed-deta-content&&.fed-part-rows&&li:eq(3)&&Text',
      content: '.fed-part-esan&&Text', tabs: '.fed-drop-boxs&&.fed-part-rows&&li', lists: '.fed-play-item:eq(#id)&&ul:eq(1)&&li',
    },
    搜索: '.fed-deta-info;h1&&Text;.lazyload&&data-original;.fed-list-remarks&&Text;a&&href;.fed-deta-content&&Text',
  }),
  采集1: theme({
    class_parse: 'json:class;', url: '/api.php/provide/vod/?ac=detail&pg=fypage&t=fyclass', homeUrl: '/api.php/provide/vod/?ac=list',
    detailUrl: '/api.php/provide/vod/?ac=detail&ids=fyid', searchUrl: '/api.php/provide/vod/?wd=**&pg=fypage', double: false,
    推荐: 'json:list;vod_name;vod_pic;vod_remarks;vod_id;vod_play_from', 一级: 'json:list;vod_name;vod_pic;vod_remarks;vod_id;vod_play_from',
    二级: "js:let html=request(input);html=JSON.parse(html);let data=html.list;VOD=data[0];", 搜索: '*',
  }),
};
mubanDict.mxone5 = mubanDict.mxpro;
mubanDict.默认 = mubanDict.mxpro;

const clone = o => JSON.parse(JSON.stringify(o));
export const muban = clone(mubanDict);
export function getMubans() { return clone(mubanDict); }
export default { muban, getMubans };
