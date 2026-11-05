package dev;

/** Marker class for the macro-generated parser of `Profile`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.Profile))
@:nullSafety(Strict)
class ProfileParser {}
