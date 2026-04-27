package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;

/**
 * Tests for slice ω-toplevel-var-fn — adds `HxDecl.VarDecl` and
 * `HxDecl.FnDecl` so module-level `var` and `function` declarations
 * parse without an enclosing `class { ... }` wrapper.
 *
 * Real Haxe's surface syntax requires every binding to live inside a
 * type declaration (class / typedef / enum / abstract / interface).
 * The AxGord/haxe-formatter corpus contains plain-snippet fixtures
 * that drop the wrapper to focus on the formatter's behavior — the
 * formatter accepts module-level `var`/`function` in those snippets,
 * and so do we to unblock the corpus harness. Three indentation
 * fixtures parse-unblock with this slice (`call_wrapping_indent`,
 * `issue_605_operator_is`, plus one more visible only after the
 * skip-parse → fail / pass transition).
 *
 * Sub-rules `HxVarDecl` / `HxFnDecl` are reused verbatim from the
 * class-member grammar — they intentionally omit the `var` /
 * `function` introducer keyword, leaving it to the calling context
 * (`HxClassMember`, `HxStatement`, now `HxDecl`). The new ctors carry
 * `@:kw('var')` / `@:kw('function')` exactly the way the existing
 * member-level / statement-level ctors do, and `VarDecl` carries
 * `@:trailOpt(';')` mirroring `HxStatement.VarStmt`'s relaxation so a
 * `}`-terminated rhs at module level (rare) parses without trailing
 * `;`.
 */
class HxToplevelVarFnSliceTest extends HxTestHelpers {

	// ======== Top-level `var` ========

	public function testToplevelVarSimple():Void {
		final ast:HxModule = HaxeModuleParser.parse('var x:Int = 42;');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case VarDecl(decl):
				Assert.equals('x', (decl.name : String));
				Assert.notNull(decl.init);
			case _: Assert.fail('expected VarDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testToplevelVarArrayInit():Void {
		final ast:HxModule = HaxeModuleParser.parse('var x = [];');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case VarDecl(decl): Assert.equals('x', (decl.name : String));
			case _: Assert.fail('expected VarDecl');
		}
	}

	public function testToplevelVarNoSemi():Void {
		// `:trailOpt` lets `}`-terminated rhs drop the `;` at module level too.
		final ast:HxModule = HaxeModuleParser.parse('var foo = { 1; }');
		switch ast.decls[0].decl {
			case VarDecl(decl): Assert.equals('foo', (decl.name : String));
			case _: Assert.fail('expected VarDecl');
		}
	}

	public function testTwoToplevelVars():Void {
		final ast:HxModule = HaxeModuleParser.parse('var a = 1;\nvar b = 2;');
		Assert.equals(2, ast.decls.length);
	}

	// ======== Top-level `function` ========

	public function testToplevelFnSimple():Void {
		final ast:HxModule = HaxeModuleParser.parse('function main() {}');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case FnDecl(decl): Assert.equals('main', (decl.name : String));
			case _: Assert.fail('expected FnDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testToplevelFnWithBody():Void {
		final ast:HxModule = HaxeModuleParser.parse('function test() { trace("x"); }');
		switch ast.decls[0].decl {
			case FnDecl(decl): Assert.equals('test', (decl.name : String));
			case _: Assert.fail('expected FnDecl');
		}
	}

	public function testToplevelFnWithReturnType():Void {
		final ast:HxModule = HaxeModuleParser.parse('function compute():Int { return 42; }');
		switch ast.decls[0].decl {
			case FnDecl(decl): Assert.equals('compute', (decl.name : String));
			case _: Assert.fail('expected FnDecl');
		}
	}

	// ======== Mixed top-level forms ========

	public function testMixedClassVarFn():Void {
		final ast:HxModule = HaxeModuleParser.parse('class A {}\nvar x = 1;\nfunction f() {}');
		Assert.equals(3, ast.decls.length);
	}

	// ======== Round-trip ========

	public function testRoundTripVar():Void {
		roundTrip('var x:Int = 42;');
	}

	public function testRoundTripFn():Void {
		roundTrip('function main() {}');
	}

	// ======== Negative — class-member position still works ========

	public function testClassVarMemberStillWorks():Void {
		// Adding top-level VarDecl must NOT cannibalize class-member
		// `var` parsing. A class with a `var` member parses unchanged.
		final ast:HxModule = HaxeModuleParser.parse('class C { var x:Int; }');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case ClassDecl(decl): Assert.equals(1, decl.members.length);
			case _: Assert.fail('expected ClassDecl');
		}
	}
}
