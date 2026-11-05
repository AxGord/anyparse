package dev;

/** Marker class for the macro-generated parser of `ArmTable`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.ArmTable))
@:nullSafety(Strict)
class ArmTableParser {}
