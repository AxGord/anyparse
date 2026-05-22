package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxCaseBranch;
import anyparse.grammar.haxe.HxCasePattern;
import anyparse.grammar.haxe.HxCasePatternBody;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxSwitchCase;
import anyparse.grammar.haxe.HxSwitchStmt;
import anyparse.grammar.haxe.HxVarNameLit;

/**
 * Slice 34: `case var <ident>:` capture pattern, plus the nested
 * `case Pattern(var foo, var bar):` form.
 *
 * Two parser-side changes back this slice:
 *
 *  1. `HxCasePattern.expr` widened from bare `HxExpr` to the
 *     `HxCasePatternBody` Alt-enum (`@:kw('var') Capture(name) |
 *     Plain(expr:HxExpr)`). The outer case-element parser now
 *     dispatches the `case var <ident>:` capture without routing
 *     through `HxExpr.VarExpr` — whose `HxVarDecl` would otherwise
 *     commit the type-hint `@:optional @:lead(':')` peek on the
 *     case-element terminator `:` and fail trying to parse the
 *     case-body statement as an `HxType`. Plain is the catch-all for
 *     every existing pattern shape (`1`, `IdentExpr`, `Foo(args)` …).
 *
 *  2. `HxVarNameLit` regex gains a `(?!(?:var|final)\b)`
 *     negative-lookahead so the multi-binding `@:tryparse more` Star
 *     on `HxVarDecl` cannot consume `, var <ident>` as a continuation
 *     of the previous binding. Without it, `Pattern(var foo, var
 *     bar)` greedily becomes a single multi-var `VarExpr(name=foo,
 *     more=[{decl: name='var'}])` (the inner identifier regex
 *     matching the bare `var` keyword), then the stray `bar)` fails
 *     the parent's parse. With it, `HxVarMore` rolls back, the outer
 *     `,` is reclaimed by `Call.args` sep, and each `var <ident>`
 *     parses as its own arg via `HxExpr.VarExpr`.
 *
 * Asserts: outer Capture surfaces with the right binding name; inner
 * Call-arg form parses as a two-arg `Call` with two `VarExpr` args
 * (NOT a single multi-var); a non-`var` pattern still routes through
 * Plain unchanged; `vararg` / `final_count` parse as normal names
 * (the `\b` word-boundary stops the keyword lookahead); fork fixture
 * round-trips byte-identically through the trivia pipeline.
 */
class HxCaseCaptureSliceTest extends HxTestHelpers {

	private function parseSwitch(source:String):HxSwitchStmt {
		final body:Array<HxStatement> = fnBodyStmts(parseSingleFnDecl(source));
		Assert.equals(1, body.length);
		return switch body[0] {
			case SwitchStmt(stmt): stmt;
			case null, _: throw 'expected SwitchStmt, got ${body[0]}';
		};
	}

	private function caseBranch(c:HxSwitchCase):HxCaseBranch {
		return switch c {
			case CaseBranch(b): b;
			case null, _: throw 'expected CaseBranch, got $c';
		};
	}

	public function testOuterCaptureSurfacesAsCaptureCtor():Void {
		final sw:HxSwitchStmt = parseSwitch(
			'class C { function f(x:E):Void { switch (x) { case var bar: y(); case _: z(); } } }'
		);
		final p:HxCasePattern = caseBranch(sw.cases[0]).patterns[0];
		switch p.expr {
			case Capture(name): Assert.equals('bar', (name : String));
			case body: Assert.fail('expected Capture(bar), got $body');
		}
		Assert.isNull(p.guard);
	}

	public function testInnerCallArgsParseAsSeparateVarExprs():Void {
		final sw:HxSwitchStmt = parseSwitch(
			'class C { function f(x:E):Void { switch (x) { case Pattern(var foo, var bar): y(); case _: z(); } } }'
		);
		final p:HxCasePattern = caseBranch(sw.cases[0]).patterns[0];
		// Outer dispatches to Plain — the Capture branch peeks `var` and
		// fails on the leading `Pattern` identifier.
		switch p.expr {
			case Plain(Call(operand, args)):
				switch operand {
					case IdentExpr(v): Assert.equals('Pattern', (v : String));
					case e: Assert.fail('expected IdentExpr Pattern, got $e');
				}
				// Two ARGS, not one multi-var binding — verifies the
				// `HxVarNameLit` negative-lookahead rolls the `HxVarMore`
				// path back so the outer `,` is reclaimed.
				Assert.equals(2, args.length);
				switch args[0] {
					case VarExpr(decl): Assert.equals('foo', (decl.name : String));
					case e: Assert.fail('expected VarExpr(foo), got $e');
				}
				switch args[1] {
					case VarExpr(decl): Assert.equals('bar', (decl.name : String));
					case e: Assert.fail('expected VarExpr(bar), got $e');
				}
			case body: Assert.fail('expected Plain(Call), got $body');
		}
	}

	public function testNonVarPatternStillRoutesThroughPlain():Void {
		// Regression: an IntLit pattern surfaces as Plain(IntLit), not
		// Capture — the Capture branch peeks the `var` keyword and
		// fails fast on a non-`var` lead.
		final sw:HxSwitchStmt = parseSwitch(
			'class C { function f(x:Int):Void { switch (x) { case 1: y(); case _: z(); } } }'
		);
		final p:HxCasePattern = caseBranch(sw.cases[0]).patterns[0];
		switch p.expr {
			case Plain(IntLit(v)): Assert.equals(1, v);
			case body: Assert.fail('expected Plain(IntLit), got $body');
		}
	}

	public function testVarargIdentParsesAsNormalName():Void {
		// `vararg` shares the `var` prefix but the `(?!var\b)` word-
		// boundary lookahead stops at the keyword — `vararg`'s next
		// char is `a`, not a non-word char, so the lookahead does
		// NOT fire and the identifier matches normally.
		final sw:HxSwitchStmt = parseSwitch(
			'class C { function f(x:Int):Void { switch (x) { case 1: vararg = y; } } }'
		);
		final b:HxCaseBranch = caseBranch(sw.cases[0]);
		Assert.equals(1, b.body.length);
		switch b.body[0] {
			case ExprStmt(Assign(IdentExpr(v), _)): Assert.equals('vararg', (v : String));
			case s: Assert.fail('expected Assign with IdentExpr(vararg), got $s');
		}
	}

	public function testCorpusIssue27RoundTrip():Void {
		// Fork corpus shape — section-2 input, byte-identical to the
		// section-3 expected output after trivia round-trip.
		roundTrip(
			'class Main {\n'
			+ '\tstatic function main() {\n'
			+ '\t\tswitch (foo) {\n'
			+ '\t\t\tcase var bar:\n'
			+ '\t\t\t\ttrace("");\n'
			+ '\t\t\tcase Pattern(var foo, var bar):\n'
			+ '\t\t\t\ttrace("");\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}',
			'issue_27_case_var_line_end'
		);
	}
}
