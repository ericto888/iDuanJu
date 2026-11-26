package com.github.catvod.spider;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

public class Proxy {

    private static Object[] text(String mime, String body) {
        return new Object[]{200, mime, new ByteArrayInputStream(body.getBytes(StandardCharsets.UTF_8))};
    }

    public static Object[] proxy(Map<String, String> params) throws Exception {
        switch (String.valueOf(params.get("do"))) {
            case "video":
                return video(params.get("range"));
            case "page":
                return text("text/html; charset=utf-8", "<html><body><script>setTimeout(function(){var v=document.createElement('video');v.src='https://media.invalid/path/stream.m3u8?sign=1';document.body.appendChild(v);v.load();},100)</script></body></html>");
            case "empty":
                return text("text/html; charset=utf-8", "<html><body>nothing</body></html>");
            default:
                return null;
        }
    }

    /** Byte ranges of the bundled colour-bar clip, the way real jar proxies stream. */
    private static Object[] video(String range) throws Exception {
        byte[] all;
        try (InputStream in = Init.context.getAssets().open("player_landscape.mp4")) {
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[65536];
            for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
            all = out.toByteArray();
        }
        int from = 0;
        int to = all.length - 1;
        if (range != null && range.startsWith("bytes=")) {
            String[] parts = range.substring(6).split("-", 2);
            if (!parts[0].isEmpty()) from = Integer.parseInt(parts[0]);
            if (parts.length > 1 && !parts[1].isEmpty()) to = Math.min(to, Integer.parseInt(parts[1]));
        }
        Map<String, String> headers = new HashMap<>();
        headers.put("Accept-Ranges", "bytes");
        headers.put("Content-Length", String.valueOf(to - from + 1));
        if (range != null) headers.put("Content-Range", "bytes " + from + "-" + to + "/" + all.length);
        return new Object[]{range == null ? 200 : 206, "video/mp4", new ByteArrayInputStream(all, from, to - from + 1), headers};
    }
}
