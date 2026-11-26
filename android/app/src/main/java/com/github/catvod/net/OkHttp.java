package com.github.catvod.net;

import android.text.TextUtils;
import android.util.ArrayMap;

import java.io.IOException;
import java.net.URLEncoder;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import okhttp3.Call;
import okhttp3.Dns;
import okhttp3.FormBody;
import okhttp3.Headers;
import okhttp3.HttpUrl;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;

/** HTTP helper jars call on the host; one shared client, the method set is the union of the published CatVod variants. */
public class OkHttp {

    public static final String GET = "GET";
    public static final String POST = "POST";
    private static final long TIMEOUT = TimeUnit.SECONDS.toMillis(15);
    private static final MediaType JSON = MediaType.parse("application/json; charset=utf-8");

    private static class Holder {
        static final OkHttp INSTANCE = new OkHttp();
    }

    public interface ClientSource {
        OkHttpClient get();
    }

    private volatile ClientSource source;
    private volatile OkHttpClient client;

    private OkHttp() {
    }

    public static OkHttp get() {
        return Holder.INSTANCE;
    }

    /** Set once at start: shares the app's connection pool and dispatcher, built when the first jar needs it. */
    public static void setClient(ClientSource source) {
        get().source = source;
    }

    public static Dns dns() {
        return Dns.SYSTEM;
    }

    public static OkHttpClient client() {
        OkHttp self = get();
        if (self.client == null) {
            synchronized (OkHttp.class) {
                if (self.client == null) self.client = (self.source == null ? getBuilder() : self.source.get().newBuilder().followRedirects(true).followSslRedirects(true)).build();
            }
        }
        return self.client;
    }

    public static OkHttpClient client(long timeout) {
        return client().newBuilder().connectTimeout(timeout, TimeUnit.MILLISECONDS).readTimeout(timeout, TimeUnit.MILLISECONDS).writeTimeout(timeout, TimeUnit.MILLISECONDS).build();
    }

    public static OkHttpClient client(int timeout) {
        return client((long) timeout);
    }

    public static OkHttpClient client(boolean redirect, long timeout) {
        return client(timeout).newBuilder().followRedirects(redirect).followSslRedirects(redirect).build();
    }

    public static OkHttpClient noRedirect() {
        return client(false, TIMEOUT);
    }

    public static OkHttpClient player() {
        return client();
    }

    public static OkHttpClient.Builder getBuilder() {
        return new OkHttpClient.Builder().connectTimeout(TIMEOUT, TimeUnit.MILLISECONDS).readTimeout(TIMEOUT, TimeUnit.MILLISECONDS).writeTimeout(TIMEOUT, TimeUnit.MILLISECONDS);
    }

    // ---------------------------------------------------------------------------------------------- text helpers

    public static String string(String url) {
        return string(client(), url);
    }

    public static String string(String url, long timeout) {
        return string(client(timeout), url);
    }

    public static String string(String url, Map<String, String> headers) {
        return string(client(), url, headers);
    }

    public static String string(String url, Map<String, String> params, Map<String, String> headers) {
        return string(client(), url, params, headers);
    }

    public static String string(OkHttpClient client, String url) {
        return string(client, url, null);
    }

    public static String string(OkHttpClient client, String url, Map<String, String> headers) {
        return string(client, url, null, headers);
    }

    public static String string(OkHttpClient client, String url, Map<String, String> params, Map<String, String> headers) {
        if (url == null || !url.startsWith("http")) return "";
        return execute(client, request(withQuery(url, params), headers)).getBody();
    }

    public static byte[] bytes(String url) {
        try (Response res = newCall(url).execute()) {
            ResponseBody body = res.body();
            return body == null ? new byte[0] : body.bytes();
        } catch (IOException | IllegalArgumentException e) {
            return new byte[0];
        }
    }

    public static OkResult get(String url, Map<String, String> params, Map<String, String> headers) {
        return execute(client(), request(withQuery(url, params), headers));
    }

    public static String post(String url, Map<String, String> params) {
        return post(url, params, null).getBody();
    }

    public static OkResult post(String url, Map<String, String> params, Map<String, String> headers) {
        return post(client(), url, params, headers);
    }

    public static OkResult post(OkHttpClient client, String url, Map<String, String> params, Map<String, String> headers) {
        return execute(client, builder(url, headers).post(form(params)).build());
    }

    public static String post(String url, String json) {
        return post(url, json, null).getBody();
    }

    public static OkResult post(String url, String json, Map<String, String> headers) {
        return execute(client(), builder(url, headers).post(RequestBody.create(json, JSON)).build());
    }

    public static String getLocation(String url, Map<String, String> headers) {
        try (Response res = noRedirect().newCall(request(url, headers)).execute()) {
            return getLocation(res.headers().toMultimap());
        } catch (IOException | IllegalArgumentException e) {
            return null;
        }
    }

    public static String getLocation(Map<String, List<String>> headers) {
        for (Map.Entry<String, List<String>> e : headers.entrySet()) {
            if ("location".equalsIgnoreCase(e.getKey()) && !e.getValue().isEmpty()) return e.getValue().get(0);
        }
        return null;
    }

    // ---------------------------------------------------------------------------------------------- calls

    public static Call newCall(String url) {
        return newCall(client(), url);
    }

    public static Call newCall(String url, String tag) {
        return client().newCall(new Request.Builder().url(url).tag(tag).build());
    }

    public static Call newCall(String url, Headers headers) {
        return newCall(client(), url, headers);
    }

    public static Call newCall(String url, Map<String, String> headers) {
        return client().newCall(request(url, headers));
    }

    public static Call newCall(String url, Headers headers, ArrayMap<String, String> params) {
        return client().newCall(new Request.Builder().url(buildUrl(url, params)).headers(headers).build());
    }

    public static Call newCall(String url, Headers headers, RequestBody body) {
        return client().newCall(new Request.Builder().url(url).headers(headers).post(body).build());
    }

    public static Call newCall(String url, RequestBody body) {
        return newCall(client(), url, body);
    }

    public static Call newCall(OkHttpClient client, String url) {
        return client.newCall(new Request.Builder().url(url).build());
    }

    public static Call newCall(OkHttpClient client, String url, String tag) {
        return client.newCall(new Request.Builder().url(url).tag(tag).build());
    }

    public static Call newCall(OkHttpClient client, String url, Headers headers) {
        return client.newCall(new Request.Builder().url(url).headers(headers).build());
    }

    public static Call newCall(OkHttpClient client, String url, RequestBody body) {
        return client.newCall(new Request.Builder().url(url).post(body).build());
    }

    public static Call newCall(Request request) {
        return client().newCall(request);
    }

    public static void cancel(String tag) {
        cancel(client(), tag);
    }

    public static void cancel(Object tag) {
        cancel(client(), tag);
    }

    public static void cancel(OkHttpClient client, Object tag) {
        for (Call call : client.dispatcher().queuedCalls()) if (tag.equals(call.request().tag())) call.cancel();
        for (Call call : client.dispatcher().runningCalls()) if (tag.equals(call.request().tag())) call.cancel();
    }

    public static void cancelAll() {
        // the dispatcher is shared with the app: a jar may only cancel what it tagged
    }

    public static FormBody toBody(ArrayMap<String, String> params) {
        return form(params);
    }

    public static HttpUrl buildUrl(String url, ArrayMap<String, String> params) {
        HttpUrl.Builder builder = HttpUrl.get(url).newBuilder();
        if (params != null) for (Map.Entry<String, String> e : params.entrySet()) builder.addQueryParameter(e.getKey(), e.getValue());
        return builder.build();
    }

    // ---------------------------------------------------------------------------------------------- internals

    private static FormBody form(Map<String, String> params) {
        FormBody.Builder body = new FormBody.Builder();
        if (params != null) for (Map.Entry<String, String> e : params.entrySet()) body.add(e.getKey(), e.getValue() == null ? "" : e.getValue());
        return body.build();
    }

    private static String withQuery(String url, Map<String, String> params) {
        if (params == null || params.isEmpty()) return url;
        StringBuilder sb = new StringBuilder(url).append(url.contains("?") ? "&" : "?");
        for (Map.Entry<String, String> e : params.entrySet()) {
            try {
                sb.append(e.getKey()).append('=').append(URLEncoder.encode(e.getValue() == null ? "" : e.getValue(), "UTF-8")).append('&');
            } catch (IOException ignored) {
                // UTF-8 always exists
            }
        }
        return sb.substring(0, sb.length() - 1);
    }

    private static Request.Builder builder(String url, Map<String, String> headers) {
        Request.Builder builder = new Request.Builder().url(url);
        if (headers != null) for (Map.Entry<String, String> e : headers.entrySet()) if (!TextUtils.isEmpty(e.getKey()) && e.getValue() != null) builder.header(e.getKey(), e.getValue());
        return builder;
    }

    private static Request request(String url, Map<String, String> headers) {
        return builder(url, headers).build();
    }

    private static OkResult execute(OkHttpClient client, Request request) {
        try (Response res = client.newCall(request).execute()) {
            ResponseBody body = res.body();
            return new OkResult(res.code(), body == null ? "" : body.string(), res.headers().toMultimap());
        } catch (IOException | IllegalArgumentException e) {
            return new OkResult(500, "", new HashMap<>());
        }
    }
}
