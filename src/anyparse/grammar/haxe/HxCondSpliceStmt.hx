package anyparse.grammar.haxe;

/**
 * Statement-position token-splice conditional: `#if <cond> <fragment>
 * #end <tail-statement>` where the fragment is an unbalanced
 * statement head — canonically an if-head whose else branch lives
 * OUTSIDE the region so the tail statement is shared by both
 * compilation variants:
 *
 *   #if share
 *   if (file != null) upload(file); else
 *   #end
 *   sendForm();
 *
 * `raw` swallows the condition and the
 * fragment through `#end`; `tail` parses the shared statement.
 *
 * Dispatch order: AFTER `HxStatement.Conditional` — the structured
 * production fail-rewinds on the dangling-else shape (its body parse
 * stops before the orphan `else`), so every balanced `#if` statement
 * region keeps its structured representation.
 */
@:peg
typedef HxCondSpliceStmt = {
	var raw: HxCondSpliceRaw;
	var tail: HxStatement;
}
