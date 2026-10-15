plugins {
	id("com.android.application")
	id("org.jetbrains.kotlin.plugin.compose")
	kotlin("plugin.serialization")
}
android {
	namespace = "nyc.juliet.subwaysfornerds"
	compileSdk { version = release(37) { minorApiLevel = 0 } }
	defaultConfig {
		applicationId = "nyc.juliet.subwaysfornerds"
		minSdk = 31
		targetSdk = 37
		versionCode = 1
		versionName = "0.1.0"
		testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
	}
	buildTypes {
		debug { applicationIdSuffix = ".debug" }
		release {
			isMinifyEnabled = false
			proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
		}
		create("optimized") {
			initWith(getByName("release"))
			applicationIdSuffix = ".debug"
			isDebuggable = false
			isMinifyEnabled = true
			isShrinkResources = true
			// An in-place performance build for the installed debug app; production signing stays separate.
			signingConfig = signingConfigs.getByName("debug")
			matchingFallbacks += listOf("release")
		}
	}
	buildFeatures { compose = true; buildConfig = true }
	compileOptions {
		sourceCompatibility = JavaVersion.VERSION_17
		targetCompatibility = JavaVersion.VERSION_17
	}
	testOptions { unitTests.isIncludeAndroidResources = true }
	packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}
dependencies {
	implementation(project(":transit-core"))
	implementation(project(":fleet-offline"))
	implementation(platform("androidx.compose:compose-bom:2026.09.00"))
	implementation("androidx.core:core-ktx:1.17.0")
	implementation("androidx.activity:activity-compose:1.11.0")
	implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
	implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
	implementation("androidx.navigation:navigation-compose:2.9.5")
	implementation("androidx.compose.material3:material3")
	implementation("androidx.compose.material:material-icons-extended")
	implementation("androidx.compose.ui:ui")
	implementation("androidx.compose.ui:ui-tooling-preview")
	implementation("androidx.browser:browser:1.9.0")
	implementation("androidx.datastore:datastore-preferences:1.1.7")
	implementation("androidx.work:work-runtime-ktx:2.10.5")
	implementation("androidx.glance:glance-appwidget:1.2.0")
	implementation("androidx.glance:glance-material3:1.2.0")
	implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
	implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
	implementation("com.squareup.okhttp3:okhttp:4.12.0")
	testImplementation("junit:junit:4.13.2")
	testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
	testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
	androidTestImplementation(platform("androidx.compose:compose-bom:2026.09.00"))
	androidTestImplementation("androidx.test:runner:1.7.0")
	androidTestImplementation("androidx.test.ext:junit:1.3.0")
	androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
	androidTestImplementation("androidx.compose.ui:ui-test-junit4")
	debugImplementation("androidx.compose.ui:ui-test-manifest")
	debugImplementation("androidx.compose.ui:ui-tooling")
}
