// Umbrella mode (see the README): `barometerUmbrellaRepository` names a local Maven
// repository that serves the artifact named by `barometerUmbrellaArtifact`.
val barometerUmbrellaRepository =
    (findProperty("barometerUmbrellaRepository") as String?)?.trim()?.takeIf { it.isNotEmpty() }

allprojects {
    repositories {
        google()
        mavenCentral()
        if (barometerUmbrellaRepository != null) {
            maven { url = uri(barometerUmbrellaRepository) }
        }
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
