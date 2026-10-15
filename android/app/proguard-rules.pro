# Release shrinking is disabled until verified against the complete native client.

# Room 2.6.1 keeps generated database class names, then constructs them reflectively.
# Keep the public no-argument constructor that WorkManager needs during app startup.
-keepclassmembers class * extends androidx.room.RoomDatabase {
	public <init>();
}

# Glance stores this callback's class name and invokes its ActionCallback contract after reflection.
-keep class nyc.juliet.subwaysfornerds.widgets.ui.RefreshWidgetAction {
	public <init>();
	public java.lang.Object onAction(android.content.Context, androidx.glance.GlanceId, androidx.glance.action.ActionParameters, kotlin.coroutines.Continuation);
}
