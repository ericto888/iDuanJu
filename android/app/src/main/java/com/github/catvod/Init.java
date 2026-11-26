package com.github.catvod;

import android.annotation.SuppressLint;
import android.content.Context;

/** Host API for CatVod-style jars: the application context. */
@SuppressLint("StaticFieldLeak") // application context only
public final class Init {

    private static volatile Context context;

    private Init() {
    }

    public static void set(Context context) {
        Init.context = context.getApplicationContext();
    }

    public static Context context() {
        return context;
    }
}
