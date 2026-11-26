package com.github.catvod.net;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Status, text and headers of one request. */
public class OkResult {

    private final int code;
    private final String body;
    private final Map<String, List<String>> resp;

    public OkResult() {
        this(500, "", new HashMap<>());
    }

    public OkResult(int code, String body, Map<String, List<String>> resp) {
        this.code = code;
        this.body = body;
        this.resp = resp;
    }

    public int getCode() {
        return code;
    }

    public String getBody() {
        return body == null ? "" : body;
    }

    public Map<String, List<String>> getResp() {
        return resp;
    }
}
