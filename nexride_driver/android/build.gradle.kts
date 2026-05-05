import com.android.build.gradle.LibraryExtension

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

/** AGP 8+ requires `namespace` on every Android library; legacy plugins (e.g. file_picker 4.x) omit it. */
gradle.beforeProject {
    val proj = this
    proj.plugins.withId("com.android.library") {
        proj.extensions.configure<LibraryExtension>("android") {
            val ns = namespace?.trim().orEmpty()
            if (ns.isBlank()) {
                val fromGroup = proj.group.toString().trim()
                if (fromGroup.isNotEmpty() && fromGroup != "unspecified") {
                    namespace = fromGroup
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
