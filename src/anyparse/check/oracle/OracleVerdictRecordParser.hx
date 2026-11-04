package anyparse.check.oracle;

/** The generated parser of `OracleVerdictRecord` — one persisted oracle verdict. Throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(anyparse.check.oracle.OracleVerdictRecord))
@:nullSafety(Strict)
class OracleVerdictRecordParser {}
