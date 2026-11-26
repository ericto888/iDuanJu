package com.github.catvod.crawler;

import android.text.TextUtils;
import android.util.Log;

import java.util.Locale;

/** Log sink of jar spiders. */
public class SpiderDebug {

    private static final String TAG = "TVBoxSpider";

    public static void log(Throwable th) {
        if (th != null) Log.d(TAG, th.toString(), th);
    }

    public static void log(String msg) {
        if (!TextUtils.isEmpty(msg)) Log.d(TAG, msg);
    }

    public static void log(String tag, String msg, Object... args) {
        if (TextUtils.isEmpty(msg)) return;
        String text = msg;
        try {
            if (args != null && args.length > 0) text = String.format(Locale.getDefault(), msg, args);
        } catch (RuntimeException ignored) {
            // a spider's format string is not worth an exception
        }
        Log.d(TAG, "[" + tag + "] " + text);
    }

    public static void e(String tag, String msg) {
        log(tag, msg);
    }
}
