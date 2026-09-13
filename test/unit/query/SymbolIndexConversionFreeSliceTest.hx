package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

/**
 * `SymbolIndex.resolvesToConversionFreeType` — the gate a signature rewrite consults before
 * moving a type out of a cast and into a declaration. It answers true for a single plain
 * nominal declaration and for a single `abstract` whose members declare no implicit
 * conversion; false for an abstract that declares one, for a typedef (which may alias either),
 * for an unresolved name, and for a name two files declare.
 */
@:nullSafety(Strict)
class SymbolIndexConversionFreeSliceTest extends Test {

	public function testAPlainClassIsConversionFree(): Void {
		Assert.isTrue(indexOf('class Foo {}\n').resolvesToConversionFreeType('Foo'));
	}

	public function testAnAbstractWithoutAConversionMemberIsConversionFree(): Void {
		// The header `from Int to Int` declares a relation the compiler implements itself — no member runs.
		Assert.isTrue(
			indexOf('abstract Wrapped(Int) from Int to Int {\n\tpublic function raw():Int {\n\t\treturn this;\n\t}\n}\n')
				.resolvesToConversionFreeType('Wrapped')
		);
	}

	public function testAnAbstractWithAFromMemberIsNot(): Void {
		Assert.isFalse(
			indexOf('abstract Wrapped(Int) {\n\t@:from static function ofInt(v:Int):Wrapped {\n\t\treturn cast v;\n\t}\n}\n')
				.resolvesToConversionFreeType('Wrapped')
		);
	}

	public function testAPlainEnumAbstractIsConversionFree(): Void {
		Assert.isTrue(
			indexOf('enum abstract Colour(Int) {\n\tfinal Red = 0;\n\tfinal Blue = 1;\n}\n').resolvesToConversionFreeType('Colour')
		);
	}

	public function testAnEnumAbstractWithAFromMemberIsNot(): Void {
		Assert.isFalse(
			indexOf(
				'enum abstract Colour(Int) {\n\tfinal Red = 0;\n\n\t@:from static function ofInt(v:Int):Colour {\n'
				+ '\t\treturn cast v;\n\t}\n}\n'
			).resolvesToConversionFreeType('Colour')
		);
	}

	public function testAnAbstractWithOnlyAToMemberIsConversionFree(): Void {
		// `@:to` runs where the abstract is the SOURCE of a conversion, which retyping a parameter
		// to it never makes a call site do — only the `@:from` direction is new code.
		Assert.isTrue(
			indexOf('abstract Wrapped(Int) {\n\t@:to function toInt():Int {\n\t\treturn this;\n\t}\n}\n')
				.resolvesToConversionFreeType('Wrapped')
		);
	}

	public function testAnAbstractCarryingABuildMacroIsNot(): Void {
		// A `@:build` macro can add the `@:from` no source scan sees.
		Assert.isFalse(
			indexOf('@:build(Macros.run())\nabstract Wrapped(Int) {\n\tpublic function raw():Int {\n\t\treturn this;\n\t}\n}\n')
				.resolvesToConversionFreeType('Wrapped')
		);
	}

	public function testATypedefIsNot(): Void {
		Assert.isFalse(indexOf('class Foo {}\ntypedef Alias = Foo;\n').resolvesToConversionFreeType('Alias'));
	}

	public function testAModuleQualifiedSubTypePathIsNot(): Void {
		// `Mod.Sub` is a module-relative path, not a declaration path — the index resolves a bare
		// name or a full path to a module's MAIN type, so this one is refused rather than guessed at.
		Assert.isFalse(
			SymbolIndex.build([{ file: 'pk/Mod.hx', source: 'package pk;\n\nclass Mod {}\n\nclass Sub {}\n' }], new HaxeQueryPlugin())
				.resolvesToConversionFreeType('Mod.Sub')
		);
	}

	public function testAnUnresolvedNameIsNot(): Void {
		Assert.isFalse(indexOf('class Foo {}\n').resolvesToConversionFreeType('Missing'));
	}

	public function testTwoDeclarationsOfOneNameAreNot(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final index: SymbolIndex = SymbolIndex.build([
			{ file: 'a/Foo.hx', source: 'package a;\nclass Foo {}\n' },
			{ file: 'b/Foo.hx', source: 'package b;\nclass Foo {}\n' }
		], plugin);
		Assert.isFalse(index.resolvesToConversionFreeType('Foo'));
	}

	private function indexOf(source: String): SymbolIndex {
		return SymbolIndex.build([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

}
