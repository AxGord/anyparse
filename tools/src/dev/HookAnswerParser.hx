package dev;

/** Marker class for the macro-generated parser of `HookAnswer`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.HookAnswer))
@:nullSafety(Strict)
class HookAnswerParser {}
