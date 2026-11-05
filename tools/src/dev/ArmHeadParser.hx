package dev;

/** Marker class for the macro-generated parser of `ArmHead`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.ArmHead))
@:nullSafety(Strict)
class ArmHeadParser {}
