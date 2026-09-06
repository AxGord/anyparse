package unit.lowering;

import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * The block-ended Star's whitespace rewind is emitted at FOUR macro sites, not one.
 * `unit.lowering.StarBlockEndedWsRewindTest` pins the first —
 * `StarLoopLowering.buildBlockEndedByteCheck`, the close-peek STRUCT-field Star that
 * `HxFnBlock.stmts` compiles to. This class pins the other two that any input reaches:
 *
 * - `StarLoopLowering.buildTryparseSepLoop` — the `@:tryparse` Star with no close
 *   literal, which `HxConditionalStmt.body` / `elseBody`, `HxElseifStmt.body` and the
 *   two `HxCondSplice*Open.body` fields compile to. A `#if` region's statement list.
 * - `StarFieldLowering.lowerStarBlockEndedSepStarts` — the lead/trail ENUM-branch Star, which
 *   `HxStatement.BlockStmt`, `HxExpr.BlockExpr` and `HxDoWhileBody.BlockBody` compile
 *   to. A nested `{ … }` block.
 *
 * Instrumenting all four loops over `fmt --list --one-pass src test tools` (1 754 files)
 * splits the 58 fires S111 recorded as one site's: 39 close-peek, 6 tryparse, 13
 * enum-branch, 0 for the fourth. Over the whole suite the same probe reads 233 / 17 / 46 / 0.
 * The fourth site — `StarFieldLowering.lowerStarBlockEndedSepLast`, the enum-branch Star WITHOUT
 * `sepStartsElement` — is live but unreachable by the rewind: its byte check is evaluated
 * 11 times suite-wide and the rewind moves in none of them, because the only grammar that
 * routes to it (`unit.miniblock.MiniBlock`) has no element rule that can leave trailing
 * whitespace consumed. It stays unarmed, by measurement rather than by omission.
 *
 * The discriminating shape is the one S111 found: `return macro if (c) foo();` reifies the
 * whole if-STATEMENT, `;` included, so `ReturnStmt`'s own `@:trailOpt(';')` misses and
 * leaves the newline and indent consumed. `stmtNoSemi` answers `false` for `ReturnStmt`,
 * so the byte check is the only thing that can accept the gap — predicate and byte check
 * are complements. Each fixture below is paired with a plain twin whose terminator is its
 * own last byte; the twins stay green under either arm, and that split is the discrimination.
 *
 * Where the two sites differ from the close-peek one is the CONSEQUENCE. Cutting the rewind
 * at that site leaves `PARSE OK` and a different tree (`ExprBody(BlockExpr(…))`), which is why no
 * byte oracle could see it. Cutting it here makes both sources fail to parse outright — the
 * nested block refuses the following statement, and the `#if` body breaks at the missing sep so
 * the enclosing `@:trail('#end')` never matches.
 */
@:nullSafety(Strict)
final class StarBlockEndedWsRewindSitesTest extends Test {

	/** A nested block statement whose first element's terminator was swallowed by a reification. */
	private static final NESTED_BLOCK_SWALLOWED: String =
		'class C {\n\tfunction f() {\n\t\t{\n\t\t\treturn macro if (c) foo();\n\t\t\ttrace(1);\n\t\t}\n\t}\n}';

	/** The same nested block with an ordinary terminator — no rewind needed. */
	private static final NESTED_BLOCK_PLAIN: String = 'class C {\n\tfunction f() {\n\t\t{\n\t\t\tfoo();\n\t\t\ttrace(1);\n\t\t}\n\t}\n}';

	/** A `#if` region body whose first element's terminator was swallowed by a reification. */
	private static final CONDITIONAL_SWALLOWED: String =
		'class C {\n\tfunction f() {\n\t\t#if js\n\t\treturn macro if (c) foo();\n\t\ttrace(1);\n\t\t#end\n\t}\n}';

	/** The same `#if` region with an ordinary terminator — no rewind needed. */
	private static final CONDITIONAL_PLAIN: String = 'class C {\n\tfunction f() {\n\t\t#if js\n\t\tfoo();\n\t\ttrace(1);\n\t\t#end\n\t}\n}';

	/** Without the rewind the enum-branch Star refuses the second statement and the whole source stops parsing. */
	@:pin('control')
	@:killer('M-PEB-WS-REWIND-SEPSTARTS-OFF')
	public function testANestedBlockKeepsTheStatementAfterASwallowedTerminator(): Void {
		final inner: Array<HxStatement> = nestedBlockStmts(NESTED_BLOCK_SWALLOWED);
		Assert.equals(2, inner.length, 'expected two statements in the nested block, got ${inner.length}');
		Assert.isTrue(
			inner.length == 2 && inner[0].match(ReturnStmt(_)) && inner[1].match(ExprStmt(_)),
			'expected ReturnStmt then ExprStmt, got $inner'
		);
	}

	/** The enum-branch twin the rewind is not needed for: the `;` IS the element's last byte. */
	@:pin('guard')
	public function testANestedBlockWithAnOrdinaryTerminatorNeedsNoRewind(): Void {
		final inner: Array<HxStatement> = nestedBlockStmts(NESTED_BLOCK_PLAIN);
		Assert.equals(2, inner.length, 'expected two statements in the nested block, got ${inner.length}');
	}

	/**
	 * Without the rewind the tryparse Star breaks at the missing sep, the enclosing
	 * `@:trail('#end')` no longer matches and the whole source stops parsing.
	 */
	@:pin('control')
	@:killer('M-PEB-WS-REWIND-TRYPARSE-OFF')
	public function testAConditionalBodyKeepsTheStatementAfterASwallowedTerminator(): Void {
		final body: Array<HxStatement> = conditionalBodyStmts(CONDITIONAL_SWALLOWED);
		Assert.equals(2, body.length, 'expected two statements in the #if body, got ${body.length}');
		Assert.isTrue(
			body.length == 2 && body[0].match(ReturnStmt(_)) && body[1].match(ExprStmt(_)), 'expected ReturnStmt then ExprStmt, got $body'
		);
	}

	/** The tryparse twin the rewind is not needed for: the `;` IS the element's last byte. */
	@:pin('guard')
	public function testAConditionalBodyWithAnOrdinaryTerminatorNeedsNoRewind(): Void {
		final body: Array<HxStatement> = conditionalBodyStmts(CONDITIONAL_PLAIN);
		Assert.equals(2, body.length, 'expected two statements in the #if body, got ${body.length}');
	}

	/**
	 * The statements of the first top-level statement of `f`, when that statement is a
	 * nested block. Any other shape — including a parse that throws once the rewind is
	 * cut — answers with an empty array, so the arm reads as a FAILURE row rather than
	 * an ERROR one and cannot be confused with the oracle-driven flake family.
	 */
	private function nestedBlockStmts(source: String): Array<HxStatement> {
		return switch topStatement(source) {
			case BlockStmt(stmts): stmts;
			case _: [];
		}
	}

	/** The statements of the `#if` body of the first top-level statement of `f`. */
	private function conditionalBodyStmts(source: String): Array<HxStatement> {
		return switch topStatement(source) {
			case Conditional(inner): inner.body;
			case _: [];
		}
	}

	private function topStatement(source: String): Null<HxStatement> {
		final cls: Null<HxClassDecl> = try HaxeParser.parse(source) catch (exception: Exception) null;
		if (cls == null) return null;
		final fn: Null<HxFnDecl> = switch cls.members[0].member {
			case FnMember(decl): decl;
			case _: null;
		}
		if (fn == null) return null;
		final body: HxFnBody = fn.body;
		final stmts: Array<HxStatement> = switch body {
			case BlockBody(block): block.stmts;
			case _: [];
		}
		return stmts.length > 0 ? stmts[0] : null;
	}

}
