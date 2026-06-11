package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 51 (ω-slice-X4) — `ExprStmt` trail-`;` peek-`case`/`default` disjunct.
 *
 * Slice 44 generalised the `;`-elision rule from the 6 INTRINSIC direct-
 * return arms on `stmtExprNoSemi` to the EXTRINSIC `}`-terminator: any
 * `ExprStmt` whose next non-trivia byte is `}` may elide its `;` because
 * the enclosing block's closing brace is itself the statement separator.
 *
 * This slice extends the gate further to the `case`/`default` keywords:
 * an `ExprStmt` whose next word-boundary-checked token is `case` or
 * `default` can ONLY be the last stmt of a switch arm (both keywords are
 * reserved in Haxe and legal exclusively as switch arm labels). The
 * incoming `case`/`default` label itself acts as the arm separator,
 * regardless of the just-parsed expr's kind.
 *
 * Newly accepted shapes (sole consumer remains `HxStatement.ExprStmt`):
 *  - `try EXPR catch (e:T) { … } case` — try-expr-catch inline form
 *    without braces around the try-body (the catch body's closing `}`
 *    is the parser's current position, but the NEXT byte is `case`, not
 *    `}`; the peek-`}` disjunct cannot reach this case).
 *  - bare `Call` / `IdentExpr` / non-assign binop / etc. as the last
 *    stmt of a switch arm, before the next `case`/`default` label.
 *
 * Driver: dogfooding — `src/anyparse/query/Cli.hx :: 391:5` had a
 * `try limit = parseLimit(args, ++i) catch (e:Exception) { … } case '-h':`
 * shape that blocked `hxq self-status` from parsing its own CLI module.
 *
 * Cascade-safe: `f() g()` inside a switch arm still throws — peek
 * succeeds ONLY when the next token is genuinely `case`/`default` (word-
 * boundary checked, so an ident like `caseInsensitive` does NOT match);
 * `f(); g();` boundary detection is unchanged.
 */
class HxStmtBeforeCaseNoSemiSliceTest extends HxTestHelpers {

	// -- Driver: try-expr-catch (no braces around try-body) followed by
	// the next switch arm. The catch body's `}` is the just-parsed expr's
	// tail, but the NEXT byte is `case`, not `}`. Pre-slice this required
	// a `;` between the catch's closing `}` and the next `case`.

	public function testTryExprCatchBeforeCase(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n' + '\tfunction f() {\n' + '\t\tswitch x {\n' + '\t\t\tcase "--limit":\n'
			+ '\t\t\t\ttry limit = parseLimit(args, ++i) catch (e:Exception) {\n' + '\t\t\t\t\tstderr("msg");\n' + '\t\t\t\t\treturn 1;\n'
			+ '\t\t\t\t}\n' + '\t\t\tcase "-h":\n' + '\t\t\t\treturn 0;\n' + '\t\t}\n' + '\t}\n' + '}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Bare Call as last stmt of a case arm, no `;`, followed by next case --

	public function testBareCallBeforeCase(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n' + '\tfunction f() {\n' + '\t\tswitch x {\n' + '\t\t\tcase "a":\n' + '\t\t\t\tfoo()\n' + '\t\t\tcase "b":\n'
			+ '\t\t\t\treturn 2;\n' + '\t\t}\n' + '\t}\n' + '}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Bare IdentExpr as last stmt of a case arm, no `;`, before next case --

	public function testBareIdentBeforeCase(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n' + '\tfunction f() {\n' + '\t\tswitch x {\n' + '\t\t\tcase "a":\n' + '\t\t\t\tident\n' + '\t\t\tcase "b":\n'
			+ '\t\t\t\treturn 2;\n' + '\t\t}\n' + '\t}\n' + '}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Non-assign binop as last stmt of a case arm, before next case --

	public function testBinopBeforeCase(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n' + '\tfunction f() {\n' + '\t\tswitch x {\n' + '\t\t\tcase "a":\n' + '\t\t\t\ta + b\n' + '\t\t\tcase "b":\n'
			+ '\t\t\t\treturn 2;\n' + '\t\t}\n' + '\t}\n' + '}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Bare Call before `default:` label (default uses the same gate) --

	public function testBareCallBeforeDefault(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n' + '\tfunction f() {\n' + '\t\tswitch x {\n' + '\t\t\tcase "a":\n' + '\t\t\t\tfoo()\n' + '\t\t\tdefault:\n'
			+ '\t\t\t\treturn 0;\n' + '\t\t}\n' + '\t}\n' + '}'
		);
		Assert.equals(1, cls.members.length);
	}

	// -- Regression: peek-`case` is WORD-BOUNDARY-checked. An ident
	// that merely STARTS with `case` (e.g. `caseInsensitive`) must not
	// trigger the peek and must still throw on the missing `;`.

	public function testBareCallFollowedByCasePrefixIdentRegression(): Void {
		Assert.raises(
			() -> HaxeParser.parse('class C {\n' + '\tfunction f() {\n' + '\t\tfoo()\n' + '\t\tcaseInsensitive\n' + '\t}\n' + '}')
		);
	}

	// -- Regression: at fn-body level (no enclosing switch), peek-`case`
	// cannot fire because `case` is not a legal stmt-position token in
	// Haxe — but the parser-side peek doesn't know that. The Star
	// terminator handling at the outer block does. We pin the closely-
	// related boundary: two `;`-less calls in sequence still throw.

	public function testBareCallFollowedByBareCallRegression(): Void {
		Assert.raises(() ->
			HaxeParser.parse(
				'class C {\n' + '\tfunction f() {\n' + '\t\tswitch x {\n' + '\t\t\tcase "a":\n' + '\t\t\t\tfoo()\n' + '\t\t\t\tbar()\n'
				+ '\t\t\tcase "b":\n' + '\t\t\t\treturn 2;\n' + '\t\t}\n' + '\t}\n' + '}'
			)
		);
	}

}
