package com.github.catvod.utils;

import android.text.TextUtils;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class Json {

    public static JsonElement parse(String json) {
        try {
            return JsonParser.parseString(json);
        } catch (Throwable e) {
            return new JsonObject();
        }
    }

    public static boolean valid(String text) {
        return isObj(text) || isArray(text);
    }

    public static boolean isObj(String text) {
        try {
            new JSONObject(text);
            return true;
        } catch (JSONException | NullPointerException e) {
            return false;
        }
    }

    public static boolean isArray(String text) {
        try {
            new JSONArray(text);
            return true;
        } catch (JSONException | NullPointerException e) {
            return false;
        }
    }

    public static boolean isEmpty(JsonObject obj, String key) {
        return obj.get(key) == null || obj.get(key).isJsonNull() || safeString(obj, key).isEmpty();
    }

    public static String safeString(JsonObject obj, String key) {
        try {
            JsonElement e = obj.get(key);
            return e == null || e.isJsonNull() ? "" : e.getAsString().trim();
        } catch (RuntimeException e) {
            return "";
        }
    }

    public static List<String> safeListString(JsonObject obj, String key) {
        List<String> result = new ArrayList<>();
        JsonElement e = obj.get(key);
        if (e == null || e.isJsonNull()) return result;
        if (e.isJsonObject()) result.add(e.toString());
        else if (e.isJsonArray()) for (JsonElement item : e.getAsJsonArray()) result.add(item.isJsonPrimitive() ? item.getAsString().trim() : item.toString());
        else result.add(e.getAsString().trim());
        return result;
    }

    public static List<JsonElement> safeListElement(JsonObject obj, String key) {
        List<JsonElement> result = new ArrayList<>();
        JsonElement e = obj.get(key);
        if (e == null || e.isJsonNull()) return result;
        if (e.isJsonArray()) for (JsonElement item : e.getAsJsonArray()) result.add(item);
        else result.add(e);
        return result;
    }

    public static JsonObject safeObject(JsonElement element) {
        try {
            if (element == null) return new JsonObject();
            if (element.isJsonObject()) return element.getAsJsonObject();
            return parse(element.getAsJsonPrimitive().getAsString()).getAsJsonObject();
        } catch (RuntimeException e) {
            return new JsonObject();
        }
    }

    public static Map<String, String> toMap(String json) {
        return TextUtils.isEmpty(json) ? null : toMap(parse(json));
    }

    public static Map<String, String> toMap(JsonElement element) {
        Map<String, String> map = new HashMap<>();
        JsonObject object = safeObject(element);
        for (String key : object.keySet()) map.put(key, safeString(object, key));
        return map;
    }

    public static JsonObject toObject(Map<String, String> map) {
        JsonObject object = new JsonObject();
        if (map != null) for (Map.Entry<String, String> e : map.entrySet()) object.addProperty(e.getKey(), e.getValue());
        return object;
    }

    public static JsonArray toArray(List<String> items) {
        JsonArray array = new JsonArray();
        for (String item : items) array.add(item);
        return array;
    }
}
