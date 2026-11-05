package dev;

/** Marker class for the macro-generated parser of `GateRecord`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.GateRecord))
@:nullSafety(Strict)
class GateRecordParser {}
