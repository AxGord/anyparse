package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CallGraph;

/**
 * Shared fixture builders for the query-layer test suites.
 */
@:nullSafety(Strict)
final class QueryTestHelpers {

	/**
	 * Build a CallGraph over inline sources, one synthetic file per entry.
	 */
	public static function graphOf(sources: Array<String>): CallGraph {
		final files: Array<{ file: String, source: String }> = [
			for (i in 0...sources.length) { file: 'F$i.hx', source: sources[i] }
		];
		return CallGraph.build(files, new HaxeQueryPlugin());
	}

}
