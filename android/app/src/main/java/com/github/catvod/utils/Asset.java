package com.github.catvod.utils;

import com.github.catvod.Init;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;

public class Asset {

    public static InputStream open(String fileName) {
        try {
            return Init.context().getAssets().open(fileName.replace("assets://", ""));
        } catch (IOException e) {
            return new ByteArrayInputStream(new byte[0]);
        }
    }

    public static String read(String fileName) {
        return Path.read(open(fileName));
    }
}
