package anyparse.grammar.haxe;

/**
 * A quoted condition operand or a quoted piece of a group: one line, `\` escaping the next character. Captured verbatim,
 * quotes included — the value reader of a condition decides what an escape inside means.
 */
@:re('"(?:[^"\\\\\\r\\n]|\\\\[^\\r\\n])*"|\'(?:[^\'\\\\\\r\\n]|\\\\[^\\r\\n])*\'')
@:rawString
abstract HxPpCondQuoted(String) from String to String {}
