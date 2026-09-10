import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}

android {
    namespace = "com.timbertrail.stg"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.timbertrail.stg"
        minSdk = 28
        targetSdk = 36
        versionCode = 9
        versionName = "1.1.8"
        val googleSecret = providers.environmentVariable("STG_GOOGLE_CLIENT_SECRET")
            .orElse(localProperties.getProperty("STG_GOOGLE_CLIENT_SECRET", "")).get()
            .replace("\\", "\\\\").replace("\"", "\\\"")
        buildConfigField("String", "GOOGLE_CLIENT_SECRET", "\"$googleSecret\"")
    }
    buildFeatures { buildConfig = true }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    sourceSets.getByName("main").assets.srcDir("../../apple/STGCore/Sources/STGCore/Resources")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.core:core-ktx:1.13.1")
}
