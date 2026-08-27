buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        // Declared via the classic buildscript classpath rather than the
        // plugins{} DSL id() lookup — that lookup resolves through Gradle
        // Plugin Portal's marker-artifact redirect, which 404s on Maven
        // Central for this version even though the real artifact is right
        // there on Google's own Maven repo. Classpath resolution uses
        // normal dependency resolution instead, which works fine.
        classpath("com.google.gms:google-services:4.4.4")
    }
}

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
