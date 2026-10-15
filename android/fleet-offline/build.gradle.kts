plugins { id("com.android.library"); kotlin("plugin.serialization") }
android {
	namespace = "nyc.juliet.subwaysfornerds.fleet"
	compileSdk { version = release(37) { minorApiLevel = 0 } }
	defaultConfig { minSdk = 31; testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
	compileOptions {
		sourceCompatibility = JavaVersion.VERSION_17
		targetCompatibility = JavaVersion.VERSION_17
	}
	testOptions { unitTests.isIncludeAndroidResources = true }
}
dependencies {
	implementation(project(":transit-core"))
	implementation("androidx.sqlite:sqlite-bundled:2.6.2")
	implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
	implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
	implementation("com.squareup.okhttp3:okhttp:4.12.0")
	testImplementation("junit:junit:4.13.2")
	testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
	androidTestImplementation("androidx.test:runner:1.7.0")
	androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
