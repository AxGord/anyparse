package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.IntroduceParameterObject;
import anyparse.query.RefactorSupport.EditResult;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

using StringTools;

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
		final src: String = 'package pkg;\n\nclass Mover {\n\tpublic function new() {}\n\tpublic function move(x:Int, y:Int, '
			+ 'dur:Float):Int return x + y + Std.int(dur);\n\tpublic function run():Int return move(1, 2, 0.5);\n}';
		final text: String = okFold(src, 'move', ['x', 'y'], 'Point', null);
		Assert.isTrue(text.contains('move(point:Point, dur:Float)'), 'signature folded');
		Assert.isTrue(text.contains('point.x + point.y'), 'body references rewritten');
		Assert.isTrue(text.contains('move({ x: 1, y: 2 }, 0.5)'), 'call site folded to an object literal');
		Assert.isTrue(text.contains('typedef Point = { x:Int, y:Int }'), 'typedef generated');
	}

	/** `--name` overrides the object parameter name. */
	public function testCustomName(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(a:Int, b:Int):Int return a + b;\n'
			+ '\tpublic function g():Int return f(1, 2);\n}';
		final text: String = okFold(src, 'f', ['a', 'b'], 'Pair', 'p');
		Assert.isTrue(text.contains('f(p:Pair)'), 'custom object name used');
		Assert.isTrue(text.contains('p.a + p.b'), 'body uses the custom name');
	}

	/** Non-contiguous parameters are refused. */
	public function testNonContiguousRefused(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(x:Int, y:Int, z:Int):Int return x + y + z;\n}';
		assertErr(introduce(src, 'f', ['x', 'z'], 'T', null));
	}

	/** A parameter without an explicit type is refused. */
	public function testUntypedParamRefused(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(a, b:Int):Int return b;\n}';
		assertErr(introduce(src, 'f', ['a', 'b'], 'T', null));
	}

	/** A parameter used through a short string interpolation is refused. */
	public function testShortInterpRefused(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(a:Int, b:Int):String return a + \'$$b\';\n}';
		assertErr(introduce(src, 'f', ['a', 'b'], 'T', null));
	}

	/** A braced interpolation is folded, not refused. */
	public function testBracedInterpFolded(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n'
			+ '\tpublic function f(a:Int, b:Int):String return \'$${a}-$${b}\';\n\tpublic function g():String return f(1, 2);\n}';
		final text: String = okFold(src, 'f', ['a', 'b'], 'T', 't');
		Assert.isTrue(text.contains('$${t.a}-$${t.b}'), 'braced interpolation rewritten through the object');
	}

	/** An unknown parameter is refused. */
	public function testNoSuchParamRefused(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\tpublic function f(a:Int):Int return a;\n}';
		assertErr(introduce(src, 'f', ['nope'], 'T', null));
	}

	/**
	 * Every `$a` occurrence the predecessor's raw-text scan matched but that is NOT a read
	 * of the parameter: one in a comment, one in a non-interpolating double-quoted literal,
	 * and one after an escaped `$$`. The index sees none of them as a read, so the fold
	 * proceeds — and each stays verbatim while the braced `${a}` becomes `${t.a}`.
	 */
	public function testNonReadDollarMentionsDoNotRefuse(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n\t// mentions $$a in a comment\n'
			+ '\tpublic function f(a:Int, b:Int):String {\n\t\ttrace("plain $$a text");\n\t\treturn \'$$$$a and $${a} and $$b\';\n'
			+ '\t}\n\tpublic function g():String return f(1, 2);\n}';
		final text: String = okFold(src, 'f', ['a'], 'T', 't');
		Assert.isTrue(text.contains('// mentions $$a in a comment'), 'comment mention untouched:\n$text');
		Assert.isTrue(text.contains('trace("plain $$a text")'), 'double-quoted mention untouched:\n$text');
		Assert.isTrue(text.contains('\'$$$$a and $${t.a} and $$b\''), 'escaped dollar kept, braced read folded:\n$text');
	}

	/**
	 * PIN. The op used to finish with `collapseBlankRuns` — a byte-identical private
	 * copy of the whole-file text scan deleted from the two extract ops in `8576f7c2`
	 * — so folding two parameters of ONE method also shortened every blank run
	 * anywhere else in the file, including inside a string literal.
	 *
	 * RED at `a727f9d1`: base answers a body holding `"one\n\nfour"` for an untouched
	 * sibling method, at `Ok`. The fold's own three assertions are in the same test
	 * so the pin cannot pass on a build where the op refuses or does nothing.
	 *
	 * SCOPE, stated plainly because the mutation sweep proved it: this fixture is NOT
	 * canonical under compiled defaults and the test passes no `optsJson`, so
	 * `editKeepingCanonical` takes its plain-splice FALLBACK and the writer never
	 * runs. So this pins "the op no longer runs a blind whole-file text scan" and
	 * NOT "the op goes through the writer" — reinstating `collapseBlankRuns` kills
	 * it, swapping `editKeepingCanonical` for a bare `applyEdits` does not. The
	 * three assertions below are exactly the op's own raw-splice spelling
	 * (`args:Args`, `{ a: 1, b: 2 }`) for that reason. `Renderer`'s side of the same
	 * defect is pinned by `HxMaxAnywhereInFileSliceTest`, and the writer route by
	 * `testTheRewrittenSourceComesBackCanonical` below.
	 */
	public function testAnUntouchedMultilineLiteralKeepsItsBlankRun(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function new() {}\n'
			+ '\tpublic function untouched():Int {\n\t\tfinal s = "one\n\n\nfour";\n\t\treturn s.length;\n\t}\n'
			+ '\tpublic function f(a:Int, b:Int):Int return a + b;\n\tpublic function g():Int return f(1, 2);\n}';
		final text: String = okFold(src, 'f', ['a', 'b'], 'Args', null);
		Assert.isTrue(text.contains('"one\n\n\nfour"'), 'the untouched literal keeps every newline:\n$text');
		Assert.isTrue(text.contains('f(args:Args)'), 'signature folded');
		Assert.isTrue(text.contains('f({ a: 1, b: 2 })'), 'call site folded');
	}

	/**
	 * PIN. Canonical in, canonical out — the contract every writer-emit op states and
	 * this one did not, because it spliced raw text and then hand-collapsed newlines.
	 * The generated typedef and the folded call now come back in the writer's own
	 * spelling for the config that governs the file.
	 *
	 * RED at `a727f9d1`: base leaves the file drifted, so `writeRoundTrip(text)`
	 * differs from `text`. The `contains` guard is in the same assertion chain so a
	 * build that refuses the fold cannot satisfy it.
	 */
	public function testTheRewrittenSourceComesBackCanonical(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\n\tpublic function new() {}\n\n\tpublic function f(a: Int, b: Int): Int {\n'
			+ '\t\treturn a + b;\n\t}\n\n\tpublic function g(): Int {\n\t\treturn f(1, 2);\n\t}\n\n}\n';
		final opts: String = '{"whitespace": {"typeHintColonPolicy": "after"}}';
		final canonicalSrc: String = plugin().writeRoundTrip(src, opts);
		final text: String = switch IntroduceParameterObject.introduce(
			canonicalSrc, posOf(canonicalSrc, 'f'), colOf(canonicalSrc, 'f'), ['a', 'b'], 'Args', null, plugin(), refShape(), opts
		) {
			case Ok(t): t;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
		Assert.isTrue(text.contains('f(args: Args)'), 'the folded signature carries the config\'s colon spacing:\n$text');
		Assert.equals(text, plugin().writeRoundTrip(text, opts), 'the rewritten source is the writer\'s fixed point');
	}

	/**
	 * PIN, CLI seam. The op is only canonical-out if it is TOLD which
	 * `hxformat.json` governs the file: the fixture's own directory declares
	 * `typeHintColonPolicy: "after"`, so the canonical spelling there is
	 * `args: Args`. Drop `discoverFormatConfig(filePath)` at the call site and the
	 * source reads as drifted under compiled defaults, `editKeepingCanonical` falls
	 * back to the plain splice, and the file comes back `args:Args` — the
	 * canonical-out half switched off with no diagnostic anywhere.
	 *
	 * RED at `a727f9d1`: the op has no such parameter there, and the raw splice
	 * writes `args:Args` whatever the file's config says.
	 */
	public function testTheCliHandsTheOpTheFilesOwnFormatConfig(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('ipo_cfg', [
			{ name: 'hxformat.json', source: '{"whitespace": {"typeHintColonPolicy": "after"}}' },
			{
				name: 'C.hx',
				source: 'class C {\n\tpublic function new() {}\n\n\tpublic function f(a: Int, b: Int): Int {\n\t\treturn a + b;\n\t}\n\n'
				+ '\tpublic function g(): Int {\n\t\treturn f(1, 2);\n\t}\n}\n'
			}
		]);
		final rc: Int = Cli.run([
			'introduce-parameter-object',
			'$dir/C.hx',
			'--select',
			'FnMember:f',
			'--params',
			'a,b',
			'--as',
			'Args',
			'--write'
		]);
		Assert.equals(0, rc);
		final out: String = File.getContent('$dir/C.hx');
		Assert.isTrue(
			out.contains('f(args: Args)') && out.contains('typedef Args = {a: Int, b: Int}'),
			'the file\'s own colon policy reached the op:\n$out'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
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
			if (src.fastCodeAt(i) == '\n'.code) {
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

	/** 1-based line of the name token of `function <fnName>(` in `src`. */
	private static function posOf(src: String, fnName: String): Int {
		return lineColOf(src, src.indexOf('function $fnName(') + 'function '.length).line;
	}

	/** 1-based column of the name token of `function <fnName>(` in `src`. */
	private static function colOf(src: String, fnName: String): Int {
		return lineColOf(src, src.indexOf('function $fnName(') + 'function '.length).col;
	}

}
