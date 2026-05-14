package anyparse.query;

/**
 * Plugin contract for a grammar that the query engine can operate on.
 *
 * The engine sees the AST exclusively through this interface: parse a
 * source string, get a `QueryNode` tree, walk it. The engine never
 * references grammar-specific types — adding a new language is a
 * matter of writing a `GrammarPlugin` implementation in that grammar's
 * package, never touching engine code.
 */
@:nullSafety(Strict)
interface GrammarPlugin {

	/** Short name used by `--lang`. */
	public function langName():String;

	/**
	 * Parse `source` and return a generic node tree. The plugin is
	 * responsible for choosing kind names and name slots — see
	 * `QueryNode` for the contract.
	 *
	 * Plugins may throw on parse failure; callers handle the
	 * exception. The engine itself never catches.
	 */
	public function parseFile(source:String):QueryNode;
}
