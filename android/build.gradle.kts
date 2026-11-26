plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
    id("org.jetbrains.kotlin.jvm") version "2.1.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0" apply false
    // Embedded CPython for TVBox Python sites; only applied to :app with -Pidj.python=true.
    id("com.chaquo.python") version "16.1.0" apply false
}
