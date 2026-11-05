package dev;

/** Marker class for the macro-generated parser of `HookPayload`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.HookPayload))
@:nullSafety(Strict)
class HookPayloadParser {}
