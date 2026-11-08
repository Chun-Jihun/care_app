import java.util.Properties
import org.gradle.api.artifacts.result.UnresolvedDependencyResult

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSecrets = Properties()
val signingFile = rootProject.file("key.properties")
if (signingFile.isFile) signingFile.inputStream().use { releaseSecrets.load(it) }
val releaseKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val hasReleaseSigning = releaseKeys.all { !releaseSecrets.getProperty(it).isNullOrBlank() }
val offlineTest = providers.gradleProperty("careDeviceTest").orNull == "offline"

// Resolve at task execution so ordinary debug/test configuration needs no secrets.
val verifyReleaseSigning by tasks.registering {
    doLast {
        check(hasReleaseSigning) { "Release signing is required. Configure android/key.properties; debug signing is never used for release." }
        check(rootProject.file(releaseSecrets.getProperty("storeFile")).isFile) { "Release keystore was not found." }
    }
}
tasks.configureEach {
    if (name == "packageRelease" || name == "packageReleaseBundle") {
        dependsOn(verifyReleaseSigning)
    }
}

tasks.register("prepareReleaseAudit") {
    // Read the exact manifest prepared for packaging, without creating an APK or AAB.
    val packagingManifest = tasks.named("processReleaseManifestForPackage")
    dependsOn(packagingManifest)
    val manifests = files(packagingManifest).asFileTree.matching {
        include("**/AndroidManifest.xml")
    }
    val runtime = configurations.named("releaseRuntimeClasspath")
    val reportDir = layout.buildDirectory.dir("reports/release-audit")
    doLast {
        val resolution = runtime.get().incoming.resolutionResult
        val unresolved = resolution.allDependencies.filterIsInstance<UnresolvedDependencyResult>()
        check(unresolved.isEmpty()) {
            "Unresolved release dependencies: ${unresolved.joinToString { it.attempted.displayName }}"
        }
        val report = reportDir.get().asFile
        manifests.singleFile.copyTo(report.resolve("AndroidManifest.xml"), overwrite = true)
        val dependencies = resolution.allComponents.map { it.id.displayName }.sorted()
        report.resolve("runtime-dependencies.txt").writeText(dependencies.joinToString("\n", postfix = "\n"))
    }
}

android {
    namespace = "org.carenotebook.care_notebook"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.carenotebook.care_notebook"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Match plugin libraries to Flutter's libapp.so. The SDK otherwise adds
        // every plugin ABI, even when --target-platform=android-arm64 is used.
        ndk {
            abiFilters += if (project.findProperty("target-platform") == "android-x64")
                "x86_64" else "arm64-v8a"
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseSecrets.getProperty("storeFile"))
                storePassword = releaseSecrets.getProperty("storePassword")
                keyAlias = releaseSecrets.getProperty("keyAlias")
                keyPassword = releaseSecrets.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        debug {
            if (offlineTest) applicationIdSuffix = ".devtest"
        }
        release {
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else null
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
