package com.github.catvod.utils;

import android.content.Context;
import android.content.SharedPreferences;

import com.github.catvod.Init;

import java.util.Map;

/** Key-value store of jar spiders, kept apart from the app's own settings. */
public class Prefers {

    private static final String FILE = "tvbox_spider";

    public static SharedPreferences getPrefers() {
        return Init.context().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    public static String getString(String key) {
        return getString(key, "");
    }

    public static String getString(String key, String defaultValue) {
        try {
            return getPrefers().getString(key, defaultValue);
        } catch (ClassCastException e) {
            return defaultValue;
        }
    }

    public static int getInt(String key) {
        return getInt(key, 0);
    }

    public static int getInt(String key, int defaultValue) {
        try {
            return getPrefers().getInt(key, defaultValue);
        } catch (ClassCastException e) {
            return defaultValue;
        }
    }

    public static long getLong(String key) {
        return getLong(key, 0L);
    }

    public static long getLong(String key, long defaultValue) {
        try {
            return getPrefers().getLong(key, defaultValue);
        } catch (ClassCastException e) {
            return defaultValue;
        }
    }

    public static float getFloat(String key) {
        return getFloat(key, 0f);
    }

    public static float getFloat(String key, float defaultValue) {
        try {
            return getPrefers().getFloat(key, defaultValue);
        } catch (ClassCastException e) {
            return defaultValue;
        }
    }

    public static boolean getBoolean(String key) {
        return getBoolean(key, false);
    }

    public static boolean getBoolean(String key, boolean defaultValue) {
        try {
            return getPrefers().getBoolean(key, defaultValue);
        } catch (ClassCastException e) {
            return defaultValue;
        }
    }

    public static Map<String, ?> getAll() {
        return getPrefers().getAll();
    }

    public static void put(String key, Object obj) {
        if (obj == null) return;
        SharedPreferences.Editor editor = getPrefers().edit();
        if (obj instanceof Boolean) editor.putBoolean(key, (Boolean) obj);
        else if (obj instanceof Float) editor.putFloat(key, (Float) obj);
        else if (obj instanceof Integer) editor.putInt(key, (Integer) obj);
        else if (obj instanceof Long) editor.putLong(key, (Long) obj);
        else editor.putString(key, obj.toString());
        editor.apply();
    }

    public static void remove(String key) {
        getPrefers().edit().remove(key).apply();
    }
}
