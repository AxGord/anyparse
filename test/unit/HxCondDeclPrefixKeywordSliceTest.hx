package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxCondDeclPrefix;

/**
 * Tests for the `AbstractKw` / `FinalKw` arms of `HxCondDeclPrefix` —
 * the `abstract` / `final` sibling of the `enum` widening covered by
 * `HxCondDeclPrefixSliceTest`.
 *
 * Motivating shapes, both from Pony (`src/pony`):
 *
 * ```haxe
 * #if x abstract #end
 * class C {}
 *
 * #if (haxe_ver >= 4.2) final #else @:final #end
 * class C {}
 * ```
 *
 * `#if x extern #end class C {}` and `#if x private #end class C {}`
 * already parsed before this slice — `extern` / `private` are plain
 * `HxModifier` entries, never decl-starting keywords, so the parser
 * never commits to a whole type decl inside the region for them.
 * `abstract` and `final` are different: each can itself START a
 * top-level declaration (`abstract A(Int) {}`, `final class C {}`),
 * so without a `HxCondDeclPrefix` arm the parser commits to parsing a
 * full `HxDecl` from the bare keyword and then has nothing left to
 * consume `#end` with. The regression cases below pin the other half
 * of the contract: widening the CONDITIONAL body must not let a bare
 * `abstract` / `final` shadow the ordinary `AbstractDecl` / `FinalDecl`
 * dispatch outside a `#if`.
 */
class HxCondDeclPrefixKeywordSliceTest extends HxTestHelpers {

	public function testAbstractKeywordInConditionalPrefix(): Void {
		final src: String = '#if x abstract #end\nclass C {}';
		final ast: HxModule = HaxeModuleParser.parse(src);
		Assert.equals(1, ast.decls.length);
		Assert.equals(1, ast.decls[0].meta.length);
		switch ast.decls[0].meta[0] {
			case Conditional(inner):
				Assert.equals(1, inner.body.length);
				switch inner.body[0] {
					case AbstractKw:
						Assert.pass();
					case _:
						Assert.fail('expected AbstractKw, got ${inner.body[0]}');
				}
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].meta[0]}');
		}
		// The declaration after `#end` is parsed independently by the
		// ordinary dispatch — a bare `class`, not `abstract Name(T)`,
		// still lands as ClassDecl. The captured keyword has no bearing
		// on what follows.
		switch ast.decls[0].decl {
			case ClassDecl(c):
				Assert.equals('C', (c.name: String));
			case _:
				Assert.fail('expected ClassDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testFinalKeywordInConditionalPrefixWithElse(): Void {
		final src: String = '#if (haxe_ver >= 4.2) final #else @:final #end\nclass C {}';
		final ast: HxModule = HaxeModuleParser.parse(src);
		switch ast.decls[0].meta[0] {
			case Conditional(inner):
				switch inner.body[0] {
					case FinalKw:
						Assert.pass();
					case _:
						Assert.fail('expected FinalKw, got ${inner.body[0]}');
				}
				final elseBody: Null<Array<HxCondDeclPrefix>> = inner.elseBody;
				if (elseBody == null) {
					Assert.fail('expected an #else body');
					return;
				}
				switch elseBody[0] {
					case Meta(Meta(name)): Assert.equals('@:final', (name: String));
					case _: Assert.fail('expected Meta(Meta), got ${elseBody[0]}');
				}
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].meta[0]}');
		}
	}

	public function testKeywordConditionalPrefixWritesVerbatim(): Void {
		final src: String = '#if x abstract #end\nclass C {}';
		roundTrip(src, 'abstract cond-decl-prefix');
		final src2: String = '#if (haxe_ver >= 4.2) final #else @:final #end\nclass C {}';
		roundTrip(src2, 'final cond-decl-prefix with else');
	}

	public function testPlainAbstractStillDispatches(): Void {
		final ast: HxModule = HaxeModuleParser.parse('abstract A(Int) {}');
		Assert.equals(0, ast.decls[0].meta.length);
		switch ast.decls[0].decl {
			case AbstractDecl(a):
				Assert.equals('A', (a.name: String));
			case _:
				Assert.fail('expected AbstractDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testPlainFinalClassStillDispatches(): Void {
		final ast: HxModule = HaxeModuleParser.parse('final class C {}');
		Assert.equals(0, ast.decls[0].meta.length);
		switch ast.decls[0].decl {
			case FinalDecl(_):
				Assert.pass();
			case _:
				Assert.fail('expected FinalDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testExternModifierConditionalStillDispatches(): Void {
		// Not a decl-starting keyword — this rides HxModifier (module-scope
		// twin of HxCondDeclPrefix), not the type this test targets. Pinned
		// here to document that it was never broken.
		final ast: HxModule = HaxeModuleParser.parse('#if x extern #end class C {}');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case ClassDecl(_):
				Assert.pass();
			case _:
				Assert.fail('expected ClassDecl, got ${ast.decls[0].decl}');
		}
	}

}
