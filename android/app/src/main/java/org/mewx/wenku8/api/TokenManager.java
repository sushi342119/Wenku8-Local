package org.mewx.wenku8.api;

/** JNI entry point retained from the Android v1.30 release API runtime. */
public final class TokenManager {
    static {
        System.loadLibrary("cpp");
    }

    private TokenManager() { }

    public static native String getMagicVersionCpp(String version);
}
