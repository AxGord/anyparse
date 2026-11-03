package dev;

/** Marker class for the macro-generated parser of `AgentMeta`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.AgentMeta))
@:nullSafety(Strict)
class AgentMetaParser {}
