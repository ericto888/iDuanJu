plugins { id("org.jetbrains.kotlin.jvm") }
kotlin { jvmToolchain(21) }
dependencies {
    api("com.squareup.okhttp3:okhttp:4.12.0")
    api("org.json:json:20240303")
    api("org.jsoup:jsoup:1.18.3")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("com.squareup.okhttp3:okhttp-dnsoverhttps:4.12.0")
    implementation("org.mozilla:rhino:1.7.15")
    // Android provides XmlPullParser; JVM tests use KXml2 (permissive notice retained).
    compileOnly("xmlpull:xmlpull:1.1.3.1")
    testImplementation("net.sf.kxml:kxml2:2.3.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    // Runs shared/tvbox/js (the QuickJS bootstrap and its libraries) on the JVM; test scope only.
    testImplementation("org.graalvm.polyglot:polyglot:24.1.1")
    testRuntimeOnly("org.graalvm.js:js-language:24.1.1") // interpreter only, no native runtime
}
tasks.test {
    // live network tests only when -Plive is passed
    systemProperty("idj.live", project.findProperty("live")?.toString() ?: "")
    systemProperty("idj.probe", project.findProperty("probe")?.toString() ?: "")
    project.findProperty("cmsApi")?.let { systemProperty("idj.cmsApi", it.toString()) }
    testLogging { showStandardStreams = true }
    project.findProperty("hgDevice")?.let { systemProperty("idj.hgDevice", it.toString()) }
    project.findProperty("bindLocal")?.let { systemProperty("idj.bindLocal", it.toString()) }
    testLogging { events("passed", "failed", "skipped"); showStandardStreams = true; exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

sourceSets.test { resources.srcDirs("../../shared/legado-port", "../../shared/tvbox") }
