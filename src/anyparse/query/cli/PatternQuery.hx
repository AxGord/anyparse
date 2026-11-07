package anyparse.query.cli;

import anyparse.query.GrammarPlugin;

/**
 * A command whose query is source text in the grammar it searches (`search`'s pattern): over a scope that holds the
 * files of several grammars, `LanguageChoice` runs it only for the grammars its query parses in. The one answer to
 * "does this call's query read in grammar X".
 */
@:nullSafety(Strict)
interface PatternQuery {

	/** Whether `plugin` parses the query `args` carries; a call that carries none answers true. */
	function queryParsesIn(args: Array<String>, plugin: GrammarPlugin): Bool;

}
