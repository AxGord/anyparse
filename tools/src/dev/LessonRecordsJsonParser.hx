package dev;

/** Marker class for the macro-generated parser of `LessonRecordsJson`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.LessonRecordsJson))
@:nullSafety(Strict)
class LessonRecordsJsonParser {}
