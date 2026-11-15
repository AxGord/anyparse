package unit.grammar.haxe;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.format.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The plain writer keeps the `;` after a var initializer that is a `{ … }` value — an object literal, with or
 * without a `#if` region inside, or a block expression — as the trivia writer keeps the `;` the source wrote.
 */
final class HxPlainObjLitVarSemiTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-PLAIN-VAR-OBJLIT-SEMI')
	public function testObjectLiteralMemberInitKeepsItsSemicolon(): Void {
		final src: String = 'class C {\n\tvar x:Dynamic = {a: 1, b: 2};\n}';
		Assert.equals(src, agree(src));
	}

	@:pin('control')
	@:killer('M-PLAIN-VAR-OBJLIT-SEMI')
	public function testARegionObjectLiteralLocalInitKeepsItsSemicolon(): Void {
		final out: String = agree('class C {\n\tfunction f() {\n\t\tvar o = {#if js a: function() {b();}, c: 1 #end};\n\t}\n}');
		Assert.isTrue(out.endsWith('}, c: 1 #end\n\t\t};\n\t}\n}'), out);
	}

	@:pin('control')
	@:killer('M-PLAIN-VAR-BLOCK-SEMI')
	public function testBlockValueLocalInitKeepsItsSemicolon(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HxWriteFixture.plainWrite('class C {\n\tfunction f() {\n\t\tvar x = {g(); 1;};\n\t}\n}', opts);
		Assert.isTrue(out.endsWith('1;};\n\t}\n}'), out);
	}

	/**
	 * The head is `}`-ended too: after a head that is not, the plain writer writes the `;` whatever the var gate
	 * answers (`var c = 3, d = switch … }` keeps it), so only this shape shows the gate reading the tail.
	 */
	@:pin('control')
	@:killer('M-PLAIN-VAR-TAIL-OBJLIT-SEMI')
	public function testAnObjectLiteralTailBindingKeepsTheSemicolon(): Void {
		final out: String = agree('class C {\n\tfunction f() {\n\t\tvar c = {x: 1}, d = {y: 4};\n\t\ttrace(d);\n\t}\n}');
		Assert.isTrue(out.indexOf('var c = {x: 1}, d = {y: 4};\n') != -1, out);
	}

	private function agree(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final trivia: String = HxWriteFixture.triviaWrite(src, opts);
		final plain: String = HxWriteFixture.plainWrite(src, opts);
		Assert.equals(trivia, plain, 'trivia wrote:\n$trivia\nplain wrote:\n$plain');
		return plain;
	}

}
