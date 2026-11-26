package com.github.catvod.utils;

import com.github.catvod.Init;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** File locations jars may use: always inside the app's own storage. */
public class Path {

    private static File base() {
        return mkdir(new File(Init.context().getFilesDir(), "tvbox/jar-data"));
    }

    private static File mkdir(File file) {
        if (!file.exists()) file.mkdirs();
        return file;
    }

    public static boolean exists(String path) {
        return path != null && new File(path.replace("file://", "")).exists();
    }

    public static boolean exists(File file) {
        return file != null && file.length() > 0;
    }

    public static File root() {
        return base();
    }

    public static File root(String name) {
        return new File(root(), name);
    }

    public static String rootPath() {
        return root().getAbsolutePath();
    }

    public static File cache() {
        return mkdir(new File(Init.context().getCacheDir(), "tvbox-jar"));
    }

    public static File cache(String name) {
        return new File(cache(), name);
    }

    public static String cachePath() {
        return cache().getAbsolutePath();
    }

    public static File files() {
        return base();
    }

    public static File files(String name) {
        return new File(files(), name);
    }

    public static File tv() {
        return mkdir(new File(base(), "TV"));
    }

    public static File tv(String name) {
        return new File(tv(), name);
    }

    public static File so() {
        return mkdir(new File(base(), "so"));
    }

    public static File so(String name) {
        return new File(so(), name);
    }

    public static File js() {
        return mkdir(new File(base(), "js"));
    }

    public static File js(String name) {
        return new File(js(), Util.md5(name));
    }

    public static File py() {
        return mkdir(new File(base(), "py"));
    }

    public static File py(String name) {
        return new File(py(), name);
    }

    public static File jar() {
        return mkdir(new File(base(), "jar"));
    }

    public static File jar(String name) {
        return new File(jar(), Util.md5(name) + ".jar");
    }

    public static File download() {
        return mkdir(new File(base(), "download"));
    }

    public static File download(String name) {
        return new File(download(), name);
    }

    public static File local(String path) {
        File file = new File(path.replace("file:/", "").replace("file://", ""));
        return file.exists() ? file : root(file.getName());
    }

    public static String read(File file) {
        try (FileInputStream in = new FileInputStream(file)) {
            return read(in);
        } catch (IOException e) {
            return "";
        }
    }

    public static String read(String path) {
        return read(local(path));
    }

    public static String read(InputStream is) {
        try (InputStream in = is) {
            return new String(readAll(in), StandardCharsets.UTF_8);
        } catch (IOException | NullPointerException e) {
            return "";
        }
    }

    public static byte[] readToByte(File file) {
        try (FileInputStream in = new FileInputStream(file)) {
            return readAll(in);
        } catch (IOException e) {
            return new byte[0];
        }
    }

    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[16384];
        for (int n; (n = in.read(buffer)) != -1; ) out.write(buffer, 0, n);
        return out.toByteArray();
    }

    public static File write(File file, InputStream is) {
        copy(is, file);
        return file;
    }

    public static File write(File file, String data) {
        return write(file, data.getBytes(StandardCharsets.UTF_8));
    }

    public static File write(File file, byte[] data) {
        return write(file, new ByteArrayInputStream(data));
    }

    public static void move(File in, File out) {
        if (in.renameTo(out)) return;
        copy(in, out);
        clear(in);
    }

    public static void copy(File in, File out) {
        try (FileInputStream is = new FileInputStream(in)) {
            copy(is, out);
        } catch (IOException ignored) {
            // best effort, like every host implementation
        }
    }

    public static void copy(InputStream in, File out) {
        try (InputStream is = in; OutputStream os = new FileOutputStream(create(out))) {
            byte[] buffer = new byte[16384];
            for (int n; (n = is.read(buffer)) != -1; ) os.write(buffer, 0, n);
        } catch (IOException | NullPointerException ignored) {
            // best effort, like every host implementation
        }
    }

    public static List<File> list(File dir) {
        File[] files = dir == null ? null : dir.listFiles();
        if (files == null) return new ArrayList<>();
        List<File> result = new ArrayList<>(Arrays.asList(files));
        Collections.sort(result, (a, b) -> a.isDirectory() != b.isDirectory() ? (a.isDirectory() ? -1 : 1) : a.getName().compareToIgnoreCase(b.getName()));
        return result;
    }

    public static void clear(File dir) {
        if (dir == null) return;
        if (dir.isDirectory()) for (File file : list(dir)) clear(file);
        dir.delete();
    }

    public static File create(File file) {
        try {
            if (file.getParentFile() != null) mkdir(file.getParentFile());
            if (!file.canWrite()) file.setWritable(true);
            if (!file.exists()) file.createNewFile();
        } catch (IOException ignored) {
            // the following write reports the failure
        }
        return file;
    }

    public static File chmod(File file) {
        file.setReadable(true);
        file.setExecutable(true);
        return file;
    }
}
