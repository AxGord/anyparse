package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BracePlacement;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * ψ₆ — runtime-switchable `leftCurly` placement for block-opening
 * braces. `BracePlacement.Same` (default) keeps `{` on the same line
 * as the preceding token; `BracePlacement.Next` moves `{` to the next
 * line at the outer indent, producing Allman-style layout.
 *
 * The knob is wired via `@:leftCurly('leftCurly')` on every Star
 * struct field that emits a `{` through `blockBody` — in the Haxe
 * grammar those are `HxClassDecl.members`, `HxInterfaceDecl.members`,
 * `HxAbstractDecl.members`, and `HxFnDecl.body`. One emission site in
 * `WriterLowering.emitWriterStarField` covers all four shapes.
 *
 * Tests assert the substring pattern that distinguishes the two
 * placements, tolerant of unrelated layout (whitespace inside the
 * body, member ordering) so the assertions stay robust against
 * future layout tweaks.
 */
@:nullSafety(Strict)
class HxLeftCurlyOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testLeftCurlyDefaultIsSame():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BracePlacement.Same, defaults.leftCurly);
	}

	public function testLeftCurlySameKeepsClassBraceInline():Void {
		final out:String = writeWith('class F { function f():Void {} }', BracePlacement.Same);
		Assert.isTrue(out.indexOf('class F {') != -1, 'expected `class F {` inline in: <$out>');
		Assert.isTrue(out.indexOf('class F\n{') == -1, 'did not expect next-line brace in: <$out>');
	}

	public function testLeftCurlyNextMovesClassBrace():Void {
		final out:String = writeWith('class F { function f():Void {} }', BracePlacement.Next);
		Assert.isTrue(out.indexOf('class F\n{') != -1, 'expected `class F\\n{` in: <$out>');
		Assert.isTrue(out.indexOf('class F {') == -1, 'did not expect inline brace in: <$out>');
	}

	public function testLeftCurlyNextMovesFunctionBodyBrace():Void {
		final out:String = writeWith('class F { function f():Void {} }', BracePlacement.Next);
		Assert.isTrue(out.indexOf('function f():Void\n\t{') != -1, 'expected `function f():Void\\n\\t{` in: <$out>');
		Assert.isTrue(out.indexOf('function f():Void {') == -1, 'did not expect inline function brace in: <$out>');
	}

	public function testLeftCurlyNextMovesInterfaceBrace():Void {
		final out:String = writeWith('interface I { function f():Void {} }', BracePlacement.Next);
		Assert.isTrue(out.indexOf('interface I\n{') != -1, 'expected `interface I\\n{` in: <$out>');
	}

	public function testLeftCurlyNextMovesAbstractBrace():Void {
		final out:String = writeWith('abstract A(Int) { function f():Void {} }', BracePlacement.Next);
		Assert.isTrue(out.indexOf('abstract A(Int)\n{') != -1, 'expected `abstract A(Int)\\n{` in: <$out>');
	}

	public function testLeftCurlyNextBodyOnNewLineAtDeeperIndent():Void {
		final out:String = writeWith('class F { function f():Void {} }', BracePlacement.Next);
		// Function body's opening `{` must sit at one tab indent (inside the class),
		// with the class `{` at column zero. The sequence `class F\n{\n\tpublic`
		// would only appear with Next applied to both braces.
		Assert.isTrue(out.indexOf('class F\n{\n\tfunction f():Void\n\t{') != -1,
			'expected nested Allman layout in: <$out>');
	}

	private inline function writeWith(src:String, leftCurly:BracePlacement):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(leftCurly));
	}

	private inline function makeOpts(leftCurly:BracePlacement):HxModuleWriteOptions {
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		return {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: base.ifBody,
			elseBody: base.elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: leftCurly,
			objectFieldColon: base.objectFieldColon,
		};
	}
}
