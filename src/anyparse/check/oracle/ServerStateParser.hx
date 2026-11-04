package anyparse.check.oracle;

/** The generated parser of `ServerState` — the record of a shared compilation server. Throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(anyparse.check.oracle.ServerState))
@:nullSafety(Strict)
class ServerStateParser {}
