group = "com.tvrain.barometer_flutter"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.21"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Umbrella mode: the Gradle property `barometerUmbrellaArtifact` names the Maven
// coordinates (`group:name:version`) of a host-supplied gomobile artifact that binds the
// `barometermobile` facade together with the host's own Go packages. The plugin then
// compiles against that artifact's classes and ships no native library of its own; the
// host application declares the repository that serves it and packages it once. Without the
// property (standalone mode, the default) the plugin uses its own library built by
// scripts/build-native.sh.
val barometerUmbrellaArtifact: String? =
    (findProperty("barometerUmbrellaArtifact") as String?)?.trim()?.takeIf { it.isNotEmpty() }

if (barometerUmbrellaArtifact == null) {
    // The application resolves this plugin's dependencies, so the repository that
    // serves the native library is registered for every project of the build.
    val barometerRepository = file("libs/maven")
    rootProject.allprojects {
        repositories {
            maven {
                url = uri(barometerRepository)
                content { includeGroup("com.tvrain.barometer") }
            }
        }
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.tvrain.barometer_flutter"

    compileSdk = 35

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 21
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    if (barometerUmbrellaArtifact == null) {
        // Built by scripts/build-native.sh; not tracked in Git.
        implementation("com.tvrain.barometer:barometer:local")
    } else {
        // The host application packages the umbrella artifact; tests need it at run time.
        compileOnly(barometerUmbrellaArtifact)
        testImplementation(barometerUmbrellaArtifact)
        androidTestImplementation(barometerUmbrellaArtifact)
    }

    // Test-only; not part of the plugin's runtime dependencies.
    testImplementation("junit:junit:4.13.2")
    // The Android SDK's org.json is a stub in host tests.
    testImplementation("org.json:json:20240303")
    androidTestImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
