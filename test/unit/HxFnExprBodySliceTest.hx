package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for slice ω-fn-expr-body — adds `HxFnBody.ExprBody(expr:HxExpr)`
 * with `@:trail(';')` so single-expression function bodies parse:
 *
 *     class Main {
 *         static function main() trace("foo");
 *     }
 *
 * The new branch is the third HxFnBody alternative, declared after
 * `BlockBody({…})` and `NoBody(;)`. Source-order dispatch ensures the
 * literal-led siblings win on shared input — only when neither `{` nor
 * `;` matches does the catch-all run the full HxExpr parser. The writer
 * emits a leading ` ` separator ahead of the expression via the parent
 * field's runtime `Type.enumConstructor` switch (extended in
 * `WriterLowering` from a single-`leftCurly`-target gate to a
 * per-ctor lookup). NoBody's `;`-led branch still falls through to
 * `_de()` so `function f():Void;` round-trips with no inserted space.
 *
 * Top-level `function f() expr;` is also exercised — `HxDecl.FnDecl`
 * shares the `HxFnBody` enum verbatim from class-member position.
 *
 * `return`-as-body (`function id(x) return x;`) is intentionally NOT
 * covered: `return` is only an `HxStatement` ctor in the current
 * grammar. Lifting it to `HxExpr` is a separate slice.
 */
class HxFnExprBodySliceTest extends HxTestHelpers {

	// ======== Class-member position ========

	public function testClassMemberExprBodyTrace():Void {
		final ast:HxModule = HaxeModuleParser.parse('class Main {\n\tstatic function main() trace("foo");\n}');
		final fn:HxFnDecl = parseSingleFnFromOnlyClass(ast);
		Assert.equals('main', (fn.name : String));
		assertExprBody(fn.body);
	}

	public function testClassMemberExprBodyCall():Void {
		final ast:HxModule = HaxeModuleParser.parse('class C {\n\tfunction f() doStuff(1, 2);\n}');
		assertExprBody(parseSingleFnFromOnlyClass(ast).body);
	}

	public function testClassMemberExprBodyAssign():Void {
		final ast:HxModule = HaxeModuleParser.parse('class C {\n\tfunction set() x = 1;\n}');
		assertExprBody(parseSingleFnFromOnlyClass(ast).body);
	}

	// ======== Top-level position ========

	public function testToplevelFnExprBody():Void {
		final ast:HxModule = HaxeModuleParser.parse('function main() trace("hi");');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case FnDecl(decl): assertExprBody(decl.body);
			case _: Assert.fail('expected FnDecl, got ${ast.decls[0].decl}');
		}
	}

	// ======== Source-order regressions ========

	public function testBlockBodyStillWins():Void {
		// `{`-led input must still route to BlockBody — ExprBody must NOT
		// be tried first. (BlockExpr could otherwise shadow it.)
		final ast:HxModule = HaxeModuleParser.parse('class C {\n\tfunction f() { trace("x"); }\n}');
		final fn:HxFnDecl = parseSingleFnFromOnlyClass(ast);
		switch fn.body {
			case BlockBody(_): Assert.pass();
			case _: Assert.fail('expected BlockBody, got ${fn.body}');
		}
	}

	public function testNoBodyStillWins():Void {
		// `;`-led input must still route to NoBody — ExprBody would
		// otherwise try to parse an empty expression, which fails.
		final ast:HxModule = HaxeModuleParser.parse('interface I {\n\tfunction f():Void;\n}');
		switch ast.decls[0].decl {
			case InterfaceDecl(iface):
				switch iface.members[0].member {
					case FnMember(fn): Assert.isTrue(fn.body.match(NoBody));
					case _: Assert.fail('expected FnMember');
				}
			case _: Assert.fail('expected InterfaceDecl');
		}
	}

	// ======== Round-trip ========

	public function testRoundTripExprBodyClass():Void {
		roundTrip('class Main {\n\tstatic function main() trace("foo");\n}');
	}

	public function testRoundTripExprBodyToplevel():Void {
		roundTrip('function f() trace("hi");');
	}

	public function testRoundTripBlockBodyUnaffected():Void {
		// Sanity: BlockBody round-trip is preserved by the writer's gate
		// extension — `lcSep` still emitted for the brace-bearing ctor.
		roundTrip('class C {\n\tfunction f() {\n\t\ttrace("x");\n\t}\n}');
	}

	public function testRoundTripNoBodyUnaffected():Void {
		// NoBody must still emit `;` directly with no preceding ` `.
		final src:String = 'interface I {\n\tfunction f():Void;\n}';
		roundTrip(src);
		// Negative byte-shape: ensure no `function f():Void ;` (extra space)
		// — the gate's `_de()` default branch must beat `ExprBody`'s `_dt(' ')`
		// for `;`-led NoBody.
		final once:String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(once.indexOf(':Void ;') < 0, 'NoBody must not gain a space before `;` (got: $once)');
	}

	// ======== Helpers ========

	private function parseSingleFnFromOnlyClass(ast:HxModule):HxFnDecl {
		Assert.equals(1, ast.decls.length);
		final cls:HxClassDecl = expectClassDecl(ast.decls[0]);
		Assert.equals(1, cls.members.length);
		return expectFnMember(cls.members[0].member);
	}

	private function assertExprBody(body:HxFnBody):Void {
		switch body {
			case ExprBody(_): Assert.pass();
			case _: Assert.fail('expected ExprBody, got $body');
		}
	}
}
