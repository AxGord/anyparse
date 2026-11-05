package dev;

/** Marker class for the macro-generated parser of `EdgeReadingJson`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.EdgeReadingJson))
@:nullSafety(Strict)
class EdgeReadingJsonParser {}
