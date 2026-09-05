package unit.lowering;

import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;
import utest.Assert;
import utest.Test;

/**
 * The block-ended Star's WHITESPACE REWIND — `StarLoopLowering.buildBlockEndedByteCheck`
 * walks back from `_prevEndPos` over trailing whitespace before it reads the byte that
 * decides whether the just-parsed element was block-ended.
 *
 * The rewind reads as dead: `_prevEndPos` is `ctx.pos` taken immediately after the element
 * and BEFORE the loop's own `skipWs`, so a whitespace byte at `_prevEndPos - 1` requires
 * the ELEMENT's own rule to have consumed trailing whitespace. Two rules do — an
 * `@:trailOpt(';')` that MISSES leaves its pre-match `skipWs` standing, and
 * `OperatorLoopLowering`'s no-operator-match path deliberately declines to rewind when the
 * consumed run held a newline and no comment (`omega-untyped-keep`) — so the rewind fires
 * 58 times over this project's own 1 754 sources.
 *
 * Fifty-two of those fires cannot change the answer: the byte the rewind lands on is `}`
 * or a comment's last character, which is not `;` either way. The remaining six land ON a
 * `;`, and there the rewind is the whole difference between `_isBE` and a thrown
 * expected-separator — which is why the shape below is the fixture and not a `}`-ended one.
 *
 * `return macro if (c) foo();` is that shape: the `;` is swallowed by the reification, so
 * the statement's own `@:trailOpt(';')` misses and leaves `ctx.pos` past the newline and
 * indent. The byte check is then the ONLY thing that can accept the gap, because
 * `stmtNoSemi` answers `false` for `ReturnStmt` by construction — it is absent from
 * `NO_SEMI_STMT_CTORS`, whose own doc says the byte check covers "stmts whose own
 * `@:trailOpt(';')` consumed the terminator". Predicate and byte check are therefore
 * complements here, not a subsumption: without the rewind the BlockBody Star refuses the
 * second statement and the function body falls back to `ExprBody(BlockExpr(…))`.
 */
@:nullSafety(Strict)
final class StarBlockEndedWsRewindTest extends Test {

	/**
	 * `return macro if (c) foo();` — the reification swallows the `;`, the statement's own
	 * optional terminator misses, and the miss leaves the newline and indent consumed.
	 */
	private static final MACRO_SWALLOWED_TERMINATOR: String =
		'class C {\n\tfunction f() {\n\t\treturn macro if (c) foo();\n\t\ttrace(1);\n\t}\n}';

	/**
	 * The same swallowed terminator under a `final` declaration. `stmtNoSemi` DOES answer
	 * for this one (a `var`-init statement whose init is itself a no-semi shape), so the
	 * gap survives with the rewind removed — the two fixtures together say the rewind is
	 * load-bearing for exactly the statements the predicate does not cover.
	 */
	private static final PREDICATE_ANSWERS_INSTEAD: String =
		'class C {\n\tfunction f() {\n\t\tfinal r = macro if (c) foo();\n\t\ttrace(1);\n\t}\n}';

	/** A plain two-statement body, where the terminator is its own last byte and no rewind is needed. */
	private static final PLAIN_TERMINATOR: String = 'class C {\n\tfunction f() {\n\t\tfoo();\n\t\ttrace(1);\n\t}\n}';

	/** Without the rewind the second statement is refused and the whole body re-parses as an expression. */
	@:pin('control')
	@:killer('M-PEB-WS-REWIND-OFF')
	public function testASwallowedTerminatorBehindTrailingWhitespaceStillEndsTheStatement(): Void {
		final body: HxFnBody = fnBody(MACRO_SWALLOWED_TERMINATOR);
		Assert.isTrue(body.match(BlockBody(_)), 'expected BlockBody, got $body');
		final stmts: Array<HxStatement> = blockStmts(body);
		Assert.equals(2, stmts.length);
		Assert.isTrue(stmts.length > 0 && stmts[0].match(ReturnStmt(_)), 'expected ReturnStmt first, got $stmts');
	}

	/** The predicate's own half of the pair: unchanged by the rewind, so the fixture above is not measuring it. */
	@:pin('guard')
	public function testTheShapeThePredicateAnswersForNeedsNoRewind(): Void {
		final body: HxFnBody = fnBody(PREDICATE_ANSWERS_INSTEAD);
		Assert.isTrue(body.match(BlockBody(_)), 'expected BlockBody, got $body');
		Assert.equals(2, blockStmts(body).length);
	}

	/** The ordinary case the byte check was written for: the `;` IS the element's last byte. */
	@:pin('guard')
	public function testAnOrdinaryTerminatorNeedsNoRewind(): Void {
		final body: HxFnBody = fnBody(PLAIN_TERMINATOR);
		Assert.isTrue(body.match(BlockBody(_)), 'expected BlockBody, got $body');
		Assert.equals(2, blockStmts(body).length);
	}

	private function fnBody(source: String): HxFnBody {
		final cls: HxClassDecl = HaxeParser.parse(source);
		final fn: HxFnDecl = switch cls.members[0].member {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember, got ${cls.members[0].member}';
		};
		return fn.body;
	}

	private function blockStmts(body: HxFnBody): Array<HxStatement> {
		return switch body {
			case BlockBody(block): block.stmts;
			case _: [];
		};
	}

}
