package unit.macro.strategy;

import unit.cli.CliFixture;

/**
 * `@:kw` refusals, asked of the compiler: one grammar node leads with one keyword, so a second `@:kw` on it — which
 * used to overwrite the first and drop a keyword from the grammar without a word — does not build.
 */
class KwTest extends Test {

	/** Two `@:kw` on one ctor are refused at the second. */
	@:pin('control') @:killer('M-KW-SECOND-OVERWRITES')
	public function testASecondKwOnOneNodeIsRefused(): Void {
		#if nodejs
		final error: String = compileError("@:kw('for')\n\t@:kw('each')\n\tLoop(w: W);");
		Assert.stringContains('@:kw appears twice on one node', error);
		Assert.stringContains('K.hx:4:', error, 'the error points at the second @:kw');
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** One `@:kw` on a ctor compiles: the refusal is about the second keyword, not the fixture. */
	public function testOneKwCompiles(): Void {
		#if nodejs
		Assert.equals('', compileError("@:kw('for')\n\tLoop(w: W);"));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	#if nodejs
	/** What compiling the parser of a grammar whose first ctor is `ctor` against this tree's `src` prints on failure; '' on success. */
	private static function compileError(ctor: String): String {
		final dir: String = CliFixture.writeDir('kw', [
			{ name: 'K.hx', source: '@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws\nenum K {\n\t$ctor\n\tWord(w: W);\n}\n' },
			{ name: 'W.hx', source: '@:re(\'[a-z]+\') @:rawString abstract W(String) from String to String {}\n' },
			{
				name: 'Main.hx',
				source: '@:build(anyparse.macro.Build.buildParser(K)) class KParser {}\n'
				+ 'class Main { static function main() KParser.parse("x"); }\n'
			}
		]);
		final run: js.node.ChildProcess.ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', [
			'-cp',
			'${Sys.getCwd()}/src',
			'-cp',
			dir,
			'--main',
			'Main',
			'--js',
			'$dir/out.js',
			'--no-output'
		], cast { encoding: 'utf8' });
		CliFixture.removeDir(dir);
		return run.status == 0 ? '' : '${run.stderr}';
	}
	#end

}
