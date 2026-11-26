package com.github.catvod.spider;

import android.content.Context;

import com.github.catvod.crawler.Spider;
import com.github.catvod.utils.Json;
import com.github.catvod.utils.Prefers;
import com.github.catvod.utils.Util;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;

import org.jsoup.Jsoup;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class Demo extends Spider {

    public static int destroyed;
    private String ext = "";

    @Override
    public void init(Context context, String extend) throws Exception {
        super.init(context, extend);
        ext = extend;
        Prefers.put("demo", siteKey);
    }

    private JsonObject vod(String id, String name, String tag) {
        JsonObject o = new JsonObject();
        o.addProperty("vod_id", id);
        o.addProperty("vod_name", name);
        o.addProperty("vod_remarks", Util.md5("a").substring(0, 4));
        if (tag != null) o.addProperty("vod_tag", tag);
        return o;
    }

    @Override
    public String homeContent(boolean filter) {
        JsonObject root = new JsonObject();
        JsonArray classes = new JsonArray();
        JsonObject c = new JsonObject();
        c.addProperty("type_id", "1");
        c.addProperty("type_name", "演示分类");
        classes.add(c);
        root.add("class", classes);
        root.add("filters", Json.parse("{\"1\":[{\"key\":\"area\",\"name\":\"地区\",\"value\":[{\"n\":\"全部\",\"v\":\"\"},{\"n\":\"大陆\",\"v\":\"cn\"}]}]}"));
        JsonArray list = new JsonArray();
        list.add(vod("id/1?x=%20&y={\"a\":1}#z", "演示影片 " + Jsoup.parse("<b>" + ext + "</b>").text() + Prefers.getString("demo"), null));
        list.add(vod("folder", "演示目录", "folder"));
        root.add("list", list);
        return root.toString();
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        JsonObject root = new JsonObject();
        JsonArray list = new JsonArray();
        for (int i = 0; i < 6; i++) list.add(vod(tid + i, "第 " + i + " 部 " + tid + extend, null));
        root.add("list", list);
        root.addProperty("pagecount", 1);
        return root.toString();
    }

    @Override
    public String detailContent(List<String> ids) {
        JsonObject root = new JsonObject();
        JsonArray list = new JsonArray();
        JsonObject v = vod(ids.get(0), "演示影片", null);
        v.addProperty("vod_content", "本地样例数据，不代表真实片源。");
        v.addProperty("vod_play_from", "本地$$$嗅探");
        v.addProperty("vod_play_url", "第1集$video#第2集$video$$$第1集$page");
        list.add(v);
        root.add("list", list);
        return root.toString();
    }

    @Override
    public String searchContent(String key, boolean quick) {
        return "{\"list\":[{\"vod_id\":\"s\",\"vod_name\":\"" + key + "\"}]}";
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        JsonObject root = new JsonObject();
        root.addProperty("parse", "page".equals(id) || "empty".equals(id) ? 1 : 0);
        root.addProperty("url", com.github.catvod.Proxy.getUrl(true) + "?do=" + id);
        return root.toString();
    }

    @Override
    public Object[] proxyLocal(Map<String, String> params) {
        return new Object[]{200, "text/plain", "csp:" + params.get("a")};
    }

    @Override
    public void destroy() {
        destroyed++;
    }

    /** Looks up a class the host does not have: must surface as a readable error, not as a crash. */
    @Override
    public String action(String action) {
        return new Missing().call();
    }

    private static class Missing {
        String call() {
            throw new NoClassDefFoundError("com/github/catvod/bean/Nothing");
        }
    }
}
