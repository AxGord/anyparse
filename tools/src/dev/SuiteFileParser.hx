package dev;

/** Marker class for the macro-generated parser of `SuiteFile`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.SuiteFile))
@:nullSafety(Strict)
class SuiteFileParser {}
