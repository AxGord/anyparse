package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxCondDeclPrefix;

/**
 * Tests for `#if` regions sitting in declaration-prefix position whose
 * branches contribute a bare declaration keyword rather than metadata —
 * `HxCondDeclPrefix` as the body element type of `HxConditionalMeta` /
 * `HxElseifMeta` — plus the integer `#if` condition atom.
 *
 * Both gaps come from openfl: 92 of its 114 unparseable modules are
 * `#if (haxe_ver >= 4.0) enum #else @:enum #end abstract Name(T)` (every
 * `openfl.display.*` enum-abstract), and `#if 0` guards commented-out
 * regions in `utils/_internal/Lib.hx`, `AssetsMacro.hx`, `ShaderMacro.hx`.
 *
 * The conditional rides `HxTopLevelDecl.meta` and the tail
 * `abstract Name(T)` reaches the plain `HxDecl.AbstractDecl` branch —
 * identical routing to the legacy `@:enum abstract Name(T)` form. The
 * regression cases below pin the other half of the contract: widening
 * the CONDITIONAL body must not let a bare `enum` shadow the
 * `EnumAbstractDecl` / `EnumDecl` dispatch in ordinary position.
 */
class HxCondDeclPrefixSliceTest extends HxTestHelpers {

	public function testEnumKeywordInConditionalPrefix(): Void {
		final src: String = '#if (haxe_ver >= 4.0) enum #else @:enum #end abstract E(Int) {}';
		final ast: HxModule = HaxeModuleParser.parse(src);
		Assert.equals(1, ast.decls.length);
		Assert.equals(1, ast.decls[0].meta.length);
		switch ast.decls[0].meta[0] {
			case Conditional(inner):
				Assert.equals(1, inner.body.length);
				switch inner.body[0] {
					case EnumKw:
						Assert.pass();
					case _:
						Assert.fail('expected EnumKw, got ${inner.body[0]}');
				}
				final elseBody: Null<Array<HxCondDeclPrefix>> = inner.elseBody;
				if (elseBody == null) {
					Assert.fail('expected an #else body');
					return;
				}
				switch elseBody[0] {
					case Meta(Meta(name)): Assert.equals('@:enum', (name: String));
					case _: Assert.fail('expected Meta(Meta), got ${elseBody[0]}');
				}
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].meta[0]}');
		}
		switch ast.decls[0].decl {
			case AbstractDecl(a):
				Assert.equals('E', (a.name: String));
			case _:
				Assert.fail('expected AbstractDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testConditionalPrefixAfterPlainMeta(): Void {
		// openfl's GraphicsDataType shape — a real meta tag precedes the region.
		final src: String = '@:dox(hide) #if (haxe_ver >= 4.0) enum #else @:enum #end abstract E(Int) {}';
		final ast: HxModule = HaxeModuleParser.parse(src);
		Assert.equals(2, ast.decls[0].meta.length);
		switch ast.decls[0].meta[1] {
			case Conditional(_):
				Assert.pass();
			case _:
				Assert.fail('expected Conditional second, got ${ast.decls[0].meta[1]}');
		}
	}

	public function testConditionalPrefixWritesVerbatim(): Void {
		final src: String = '#if (haxe_ver >= 4.0) enum #else @:enum #end abstract E(Int) {}';
		Assert.isTrue(
			HxModuleWriter.write(HaxeModuleParser.parse(src)).indexOf('#if (haxe_ver >= 4.0) enum #else @:enum #end abstract E(Int)') != -1
		);
		roundTrip(src, 'conditional decl prefix');
	}

	public function testPlainEnumAbstractStillDispatches(): Void {
		// The widened element type lives ONLY in conditional bodies — a bare
		// `enum` in ordinary prefix position must still reach EnumAbstractDecl.
		final ast: HxModule = HaxeModuleParser.parse('enum abstract E(Int) {}');
		Assert.equals(0, ast.decls[0].meta.length);
		switch ast.decls[0].decl {
			case EnumAbstractDecl(_):
				Assert.pass();
			case _:
				Assert.fail('expected EnumAbstractDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testPlainEnumStillDispatches(): Void {
		final ast: HxModule = HaxeModuleParser.parse('enum E { A; }');
		Assert.equals(0, ast.decls[0].meta.length);
		switch ast.decls[0].decl {
			case EnumDecl(_):
				Assert.pass();
			case _:
				Assert.fail('expected EnumDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testIntegerConditionAtom(): Void {
		final ast: HxModule = HaxeModuleParser.parse('#if 0\nclass A {}\n#end');
		Assert.equals(1, ast.decls.length);
		roundTrip('#if 0\nclass A {}\n#end', '#if 0');
	}

	public function testIntegerConditionAtomInMetaPrefix(): Void {
		final ast: HxModule = HaxeModuleParser.parse('#if 1 @:keep #end class A {}');
		switch ast.decls[0].meta[0] {
			case Conditional(inner):
				Assert.equals('1', (inner.cond: String));
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].meta[0]}');
		}
	}

}
