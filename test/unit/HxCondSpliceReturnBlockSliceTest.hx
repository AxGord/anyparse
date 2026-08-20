package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import anyparse.grammar.haxe.HxStatement;

/**
 * A SELF-TERMINATING `#if … ; #end` region that is the value of a `return`, spelled over SEVERAL
 * LINES — the half of `HxExpr.CondSpliceReturnExpr` that a raw capture alone cannot serve.
 *
 * The writer GLUES the `#if` onto the `return`, which shifts every following line of the region
 * one level left. A verbatim raw re-emission leaves the body indented as if the `#if` were still
 * on its own line, so admitting the shape without the re-indent turned the fork's
 * `sameline/issue_54_return_sharp_multiple_passes` fixture from SKIP_PARSE into a round-trip FAIL.
 * `@:writeNormalize('reindentBlock')` re-emits each line at the writer's own indent plus the
 * line's indentation RELATIVE to the region, which is the fork's layout exactly.
 *
 * The swallow guard is pinned here too: before the ctor existed the region reached
 * `HxExpr.CondSpliceExpr`, whose MANDATORY `tail` parsed the next member's leading `public` as an
 * identifier INSIDE the function above it — a silent visibility change once a reorder moved the
 * two apart (see `MemberOrderModifierSpanSliceTest` for the one-line case).
 */
class HxCondSpliceReturnBlockSliceTest extends HxTestHelpers {

	/** The fork fixture's input: `return` alone on its line, the region one level deeper. */
	private static final BROKEN_SOURCE: String = 'class Main {\n\tstatic inline function get_onMobile():Bool\n\t{\n\t\treturn\n'
		+ '\t\t\t#if js\n\t\t\t\thtml5.onMobile;\n\t\t\t#elseif mobile\n\t\t\t\ttrue;\n\t\t\t#else\n\t\t\t\tfalse;\n\t\t\t#end\n\t}\n}';

	/** The same region already in the writer's own layout — the fixture's expected output. */
	private static final CANONICAL: String = 'class Main {\n\tstatic inline function get_onMobile():Bool {\n\t\treturn #if js\n'
		+ '\t\t\thtml5.onMobile;\n\t\t#elseif mobile\n\t\t\ttrue;\n\t\t#else\n\t\t\tfalse;\n\t\t#end\n\t}\n}';

	/** Gluing the `#if` onto the `return` takes the whole region one level left with it. */
	public function testBrokenSourceReindentsToTheWriterIndent(): Void {
		Assert.equals(CANONICAL, HxWriteFixture.triviaWrite(BROKEN_SOURCE, '{}'));
	}

	/** And the canonical form is a fixed point — the re-indent is idempotent, not a per-pass shift. */
	public function testCanonicalFormRoundTripsByteExact(): Void {
		Assert.equals(CANONICAL, HxWriteFixture.triviaWrite(CANONICAL, '{}'));
	}

	/** A deeper region keeps its own relative structure: the base is a common PREFIX, not a width. */
	public function testRelativeIndentationInsideTheRegionSurvives(): Void {
		final src: String =
			'class M {\n\tstatic function f():Int {\n\t\treturn #if a\n\t\t\tg({\n\t\t\t\tx: 1\n\t\t\t});\n\t\t#else\n\t\t\t0;\n\t\t#end\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

	/**
	 * A following STATEMENT is a sibling, not the region's tail. This is the arm that actually runs
	 * in a block body: `HxStatement.ReturnStmt` sends the region down the atom dispatch, where
	 * `CondSpliceExpr`'s mandatory `tail` was happy to be the next statement — measured, `trace(3);`
	 * parsed as that tail. `CondSpliceReturnStmt` ends the region at its own `#end`.
	 *
	 * `parseBody` is the PLAIN parser on purpose: the first cut of this ctor parsed under trivia and
	 * failed here, because the block Star asks `stmtNoSemi` whether the previous statement needs a
	 * `;` before the next one and a ctor missing from that set stops the walk — a whole-file
	 * skip-parse in plain mode while the trivia pipeline said yes.
	 */
	public function testFollowingStatementIsNotSwallowed(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f() { return #if js 1; #else 2; #end\ntrace(3); } }');
		Assert.equals(2, body.length);
		switch body[0] {
			case CondSpliceReturnStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected CondSpliceReturnStmt, got ${body[0]}');
		}
	}

	/** And the pair round-trips: no `;` invented after the `#end`, no statement moved. */
	public function testRegionAndFollowingStatementRoundTripByteExact(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\treturn #if js 1; #else 2; #end\n\t\ttrace(3);\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

	/** A `;` the source DID write after the `#end` survives as its own empty statement. */
	public function testWrittenSemicolonAfterTheRegionSurvives(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\treturn #if js 1; #else 2; #end;\n\t\ttrace(3);\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

	/** The member after the region is the container's own child, not a node inside the function above it. */
	public function testNextMemberIsNotSwallowed(): Void {
		final src: String = 'class C {\n\n\tprivate static inline function get_touchScreen(): Bool return #if ios\n\t\ttrue;\n\t#else\n\t\tfalse;\n\t#end\n\n'
			+ '\tpublic static final NAME: String = \'x\';\n\n}';
		final root: QueryNode = new HaxeQueryPlugin().parseFile(src);
		final container: QueryNode = root.children.length > 0 ? root.children[0] : root;
		final at: Int = src.indexOf('public static final');
		final owners: Array<String> = [
			for (child in container.children) if (covers(child, at)) child.kind
		];
		Assert.equals('Public', owners.join(','), 'the modifier is its own sibling slot: $owners');
	}

	/** The statements of the single function in `source`, parsed by the PLAIN pipeline. */
	private function parseBody(source: String): Array<HxStatement> {
		return fnBodyStmts(parseSingleFnDecl(source));
	}

	/** Whether `node`'s own span contains the offset `at`. */
	private function covers(node: QueryNode, at: Int): Bool {
		final span: Null<Span> = node.span;
		return span != null && span.from <= at && at < span.to;
	}

}
