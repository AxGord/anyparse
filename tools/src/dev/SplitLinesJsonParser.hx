package dev;

/** Marker class for the macro-generated parser of `SplitLinesJson`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.SplitLinesJson))
@:nullSafety(Strict)
class SplitLinesJsonParser {}
