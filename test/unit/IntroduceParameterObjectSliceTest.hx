package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.IntroduceParameterObject;
import anyparse.query.RefactorSupport.EditResult;

/**
 * `IntroduceParameterObject.introduce` — fold a contiguous run of a
 * function's parameters into one object parameter of a generated typedef,
 * rewriting the signature, the body references, and the in-file call
 * sites. Each test drives the PURE op on an in-memory source; the cursor
 * is placed on the function name via `posOf`.
 */
class IntroduceParameterObjectSliceTest extends Test {

	/** The signature, body, call sites, and generated typedef are all rewritten. */
	public function testBasicFold(): Void {
		final src: String = 'package pkg;\n\nclass Mover {\n\tpublic function new() {}\n\tpublic function move(x:Int, y:Int, dur:Float):Int return x + y + Std.int(dur);\n\tpublic function run():Int return move(1, 2, 0.5);\n}';
		final text: String = okFold(src, 'move', ['x', 'y'], 'Point', null);
		Assert.isTrue(StringTools.contains(text, 'move(point:Point, dur:Float)'), 'signature folded');
		Assert.isTrue(StringTools.contains(text, 'point.x + point.y'), 'body references rewritten');
		Assert.isTrue(StringTools.contains(text, 'move({ x: 1, y: 2 }, 0.5)'), 'call site folded to an object literal');
		Assert.isTrue(StringTools.contains(text, 'typedef Point = { x:Int, y:Int }'), 'typedef generated');
	}

	/** `--name` overrides the object parameter name. */
	public function testCustomName(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(a:Int, b:Int):Int return a + b;\n\tpublic function g():Int return f(1, 2);\n}';
		final text: String = okFold(src, 'f', ['a', 'b'], 'Pair', 'p');
		Assert.isTrue(StringTools.contains(text, 'f(p:Pair)'), 'custom object name used');
		Assert.isTrue(StringTools.contains(text, 'p.a + p.b'), 'body uses the custom name');
	}

	/** Non-contiguous parameters are refused. */
	public function testNonContiguousRefused(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(x:Int, y:Int, z:Int):Int return x + y + z;\n}';
		assertErr(introduce(src, 'f', ['x', 'z'], 'T', null));
	}

	/** A parameter without an explicit type is refused. */
	public function testUntypedParamRefused(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(a, b:Int):Int return b;\n}';
		assertErr(introduce(src, 'f', ['a', 'b'], 'T', null));
	}

	/** A parameter used through a short string interpolation is refused. */
	public function testShortInterpRefused(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(a:Int, b:Int):String return a + \'$$b\';\n}';
		assertErr(introduce(src, 'f', ['a', 'b'], 'T', null));
	}

	/** A braced interpolation is folded, not refused. */
	public function testBracedInterpFolded(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(a:Int, b:Int):String return \'$${a}-$${b}\';\n\tpublic function g():String return f(1, 2);\n}';
		final text: String = okFold(src, 'f', ['a', 'b'], 'T', 't');
		Assert.isTrue(StringTools.contains(text, '$${t.a}-$${t.b}'), 'braced interpolation rewritten through the object');
	}

	/** An unknown parameter is refused. */
	public function testNoSuchParamRefused(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(a:Int):Int return a;\n}';
		assertErr(introduce(src, 'f', ['nope'], 'T', null));
	}

	private function okFold(src: String, fnName: String, params: Array<String>, typeName: String, objName: Null<String>): String {
		switch introduce(src, fnName, params, typeName, objName) {
			case Ok(text):
				var parsed: Bool = true;
				try
					plugin().parseFile(text)
				catch (_: haxe.Exception)
					parsed = false;
				Assert.isTrue(parsed, 'result should re-parse');
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	private function introduce(src: String, fnName: String, params: Array<String>, typeName: String, objName: Null<String>): EditResult {
		final marker: String = 'function $fnName(';
		final nameIdx: Int = src.indexOf(marker) + 'function '.length;
		final p: { line: Int, col: Int } = lineColOf(src, nameIdx);
		return IntroduceParameterObject.introduce(src, p.line, p.col, params, typeName, objName, plugin(), refShape());
	}

	private function assertErr(result: EditResult): Void {
		switch result {
			case Ok(_):
				Assert.fail('expected Err, got Ok');
			case Err(_):
				Assert.pass();
		}
	}

	/** 1-based line / col of source offset `idx`. */
	private static function lineColOf(src: String, idx: Int): { line: Int, col: Int } {
		var line: Int = 1;
		var col: Int = 1;
		for (i in 0...idx) {
			if (StringTools.fastCodeAt(src, i) == '\n'.code) {
				line++;
				col = 1;
			} else {
				col++;
			}
		}
		return { line: line, col: col };
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function refShape(): RefShape {
		return new HaxeQueryPlugin().refShape();
	}

}
