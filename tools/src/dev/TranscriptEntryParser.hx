package dev;

/** Marker class for the macro-generated parser of `TranscriptEntry`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.TranscriptEntry))
@:nullSafety(Strict)
class TranscriptEntryParser {}
