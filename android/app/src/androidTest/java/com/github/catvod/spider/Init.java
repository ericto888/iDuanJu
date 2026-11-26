package com.github.catvod.spider;

import android.content.Context;

/** Fixture jar (the test APK itself is loaded as the jar): same entry points a published CatVod jar has. */
public class Init {

    public static Context context;

    public static void init(Context context) {
        Init.context = context;
    }
}
