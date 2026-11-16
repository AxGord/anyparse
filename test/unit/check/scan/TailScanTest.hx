package unit.check.scan;

import anyparse.check.scan.TailScan;
import anyparse.query.CondDirectives.CondDirective;
import anyparse.query.QueryNode;

/**
 * `TailScan.hasConditionalCompilation` answers from the generated directive events, so a
 * directive-like spelling inside a string or a comment is not conditional compilation.
 */
class TailScanTest extends Test {

	private static final REAL: String = 'class C { function f() { helper(#if debug 1 #else 2 #end); } }';
	private static final IN_STRING: String = 'class C { function f() { helper("#if debug"); } }';
	private static final IN_COMMENT: String = 'class C { function f() { helper(); // #end\n } }';

	@:pin('control')
	@:killer('M-TAILSCAN-DIRECTIVES-IGNORED')
	public function testRealDirectiveRefuses(): Void {
		Assert.isTrue(held(REAL));
	}

	@:pin('control')
	@:killer('M-TAILSCAN-STRING-IS-DIRECTIVE')
	public function testDirectiveSpellingInStringOrCommentDoesNotRefuse(): Void {
		Assert.isFalse(held(IN_STRING));
		Assert.isFalse(held(IN_COMMENT));
	}

	/**
	 * The comments of a run's trivia gaps are the lexer's: each is read whole and trimmed, a string literal
	 * holding comment markers inside a statement is never one, and nothing past the last statement is a gap.
	 */
	@:pin('control')
	@:killer('M-TAILSCAN-GAP-UNCLIPPED')
	public function testRunCommentsAreTheGapsOfTheStatementRun(): Void {
		final source: String = '// first\nf("// not");\n/* second */\n// third\ng();\n// after';
		final f: Int = source.indexOf('f(');
		final g: Int = source.indexOf('g(');
		final stmts: Array<QueryNode> = [
			new QueryNode('ExprStmt', null, [], new Span(f, f + 'f("// not");'.length)),
			new QueryNode('ExprStmt', null, [], new Span(g, g + 'g();'.length))
		];
		final comments: Array<String> = TailScan.runComments(source, new HaxeQueryPlugin().lexicalRegions(source), stmts, 0);
		Assert.same(['// first', '/* second */', '// third'], comments);
	}

	private static function held(source: String): Bool {
		final directives: Array<CondDirective> = TailScan.directivesOf(source, new HaxeQueryPlugin());
		return TailScan.hasConditionalCompilation(directives, 0, source.length);
	}

}
