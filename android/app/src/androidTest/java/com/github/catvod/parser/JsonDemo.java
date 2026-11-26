package com.github.catvod.parser;

import org.json.JSONObject;

import java.util.LinkedHashMap;

public class JsonDemo {

    public static JSONObject parse(LinkedHashMap<String, String> jx, String url) throws Exception {
        return new JSONObject().put("parse", 0).put("url", "https://media.invalid/" + jx.size() + ".m3u8").put("header", new JSONObject().put("Referer", url));
    }
}
