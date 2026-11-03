package dev;

/** Marker class for the macro-generated parser of `Baseline`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.Baseline))
@:nullSafety(Strict)
class BaselineParser {}
