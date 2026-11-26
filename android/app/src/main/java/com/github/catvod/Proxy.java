package com.github.catvod;

/** Host API for CatVod-style jars: address of the app's loopback proxy. */
public final class Proxy {

    public interface PortSource {
        int get();
    }

    private static volatile PortSource source = () -> 9978;

    private Proxy() {
    }

    public static void set(PortSource source) {
        Proxy.source = source;
    }

    public static void set(int port) {
        source = () -> port;
    }

    public static int getPort() {
        return source.get();
    }

    /** The proxy only listens on the device itself, whatever {@code local} asks for. */
    public static String getUrl(boolean local) {
        return "http://127.0.0.1:" + getPort() + "/proxy";
    }

    public static String getUrl() {
        return getUrl(true);
    }

    public static String getUrl(String siteKey, String param) {
        return getUrl(true) + "?do=csp&siteKey=" + siteKey + param;
    }
}
