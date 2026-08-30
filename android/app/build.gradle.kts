plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.timbertrail.stg"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.timbertrail.stg"
        minSdk = 25
        targetSdk = 36
        versionCode = 6
        versionName = "1.1.6"
    }
    buildFeatures { buildConfig = true }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    sourceSets.getByName("main").assets.srcDir("../../shared/openrouter")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.documentfile:documentfile:1.0.0")
}
