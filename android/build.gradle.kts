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
    // Pin every plugin's Kotlin to the same JVM target its Java already uses.
    //
    // another_telephony compiles Java at 11 and Kotlin at 1.8, which Gradle
    // rejects outright. That is the plugin's bug, but waiting for an upstream
    // fix is not a plan with a deadline attached, and pinning here also stops
    // the next plugin doing the same thing on demo day.
    //
    // BOTH sides have to be pinned. Plugins disagree in both directions —
    // another_telephony is Java 11 / Kotlin 1.8, battery_plus is Java 8 — so
    // forcing only Kotlin just moves the failure to a different plugin.
    //
    // configureEach is lazy on purpose: an afterEvaluate block cannot be added
    // here because evaluationDependsOn below has already evaluated the project.
    // Java has to be set on the ANDROID EXTENSION, not on the JavaCompile
    // task: AGP writes the task's targets from compileOptions afterwards, so
    // configuring the task directly is silently overwritten.
    //
    // plugins.withId fires when the plugin is applied, which is early enough,
    // unlike afterEvaluate — evaluationDependsOn below has already run.
    plugins.withId("com.android.library") {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
            ?.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
    }
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>()
        .configureEach {
            compilerOptions.jvmTarget.set(
                org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17,
            )
        }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
