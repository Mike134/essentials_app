allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Essentials v2 Phase 5 build order step 2 -- flutter_js's own
// android/build.gradle hardcodes `kotlinOptions.jvmTarget = "1.8"` but
// never sets `compileOptions.sourceCompatibility`/`targetCompatibility`
// at all, so it silently inherits whatever AGP 9.0.1 defaults to for a
// plain android-library module with no explicit setting (11, per the
// real build error this fixed: "Inconsistent JVM-target compatibility...
// compileDebugJavaWithJavac (11) and compileDebugKotlin (1.8)") --
// AGP's newer Kotlin/Java consistency check then fails the build outright.
// Same category of fix as windows/CMakeLists.txt's
// _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS override for
// permission_handler_windows -- a project-level compensation for an
// upstream plugin's own build config gap, scoped narrowly to the one
// affected subproject rather than touching :app's own Java 17 target.
project(":flutter_js") {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension> {
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_1_8
                targetCompatibility = JavaVersion.VERSION_1_8
            }
        }
    }
}
