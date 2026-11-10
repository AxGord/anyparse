package anyparse.grammar.haxe;

/** A quoted condition operand or a quoted piece of a group: one line, `\` escaping the next character. */
@:re('"(?:[^"\\\\\\r\\n]|\\\\[^\\r\\n])*"|\'(?:[^\'\\\\\\r\\n]|\\\\[^\\r\\n])*\'')
abstract HxPpCondQuoted(String) from String to String {}
