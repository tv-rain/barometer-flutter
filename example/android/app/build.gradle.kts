import java.time.Instant
import java.time.temporal.ChronoUnit

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.tvrain.barometer_flutter_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.tvrain.barometer_flutter_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

/**
 * Writes the example's synthetic Barometer files from `example/barometer/` into the
 * generated assets as `barometer/trust.json` and `barometer/tasks/<name>.json`.
 *
 * Barometer admits an embedded task only before its `not_after`, at most seven days after
 * acceptance, so the files carry placeholders that are filled at every build:
 * `__EXPIRES_AT__` with the build time plus six days (the task expiry and the target
 * registration expiry) and `__BUILD_STAMP__` with the build time in Unix seconds (part of
 * each task identifier, so a rebuilt task never conflicts with a retained replay record).
 */
abstract class BarometerExampleAssets : DefaultTask() {
    @get:InputDirectory
    abstract val source: DirectoryProperty

    @get:OutputDirectory
    abstract val output: DirectoryProperty

    init {
        outputs.upToDateWhen { false }
    }

    @TaskAction
    fun generate() {
        val now = Instant.now().truncatedTo(ChronoUnit.SECONDS)
        val expiresAt = now.plus(6, ChronoUnit.DAYS).toString()
        val root = source.get().asFile
        val target = output.get().asFile.resolve("barometer")
        target.deleteRecursively()
        root.walkTopDown().filter { it.isFile && it.extension == "json" }.forEach { file ->
            val text = file.readText()
                .replace("__EXPIRES_AT__", expiresAt)
                .replace("__BUILD_STAMP__", now.epochSecond.toString())
            target.resolve(file.relativeTo(root)).apply { parentFile.mkdirs() }.writeText(text)
        }
    }
}

val barometerExampleAssets = tasks.register<BarometerExampleAssets>("barometerExampleAssets") {
    source.set(rootProject.layout.projectDirectory.dir("../barometer"))
    output.set(layout.buildDirectory.dir("generated/barometer"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(barometerExampleAssets, BarometerExampleAssets::output)
    }
}
