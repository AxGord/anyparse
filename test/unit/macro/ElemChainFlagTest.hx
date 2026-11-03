package unit.macro;

using StringTools;

#if nodejs
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
#end

/**
 * `@:fmt(elemChainOp('<op>'))` holds on the plain sep-list path only. Anywhere else it would drop a delimiter or do nothing,
 * so it stops the build, asked of a second grammar by a child compiler: the suite binary holds Haxe's grammar only.
 * Each refusal has its own arm, and each fixture breaks exactly one condition, so dropping a condition fails its pin.
 */
@:access(unit.macro.TriviaTypeSynthTest)
class ElemChainFlagTest extends Test {

	private static final REFUSAL: String = "@:fmt(elemChainOp('<op>')) needs";
	private static final LIST: String = "@:trail(':') @:sep(',')";
	private static final FLAGS: String = "wrapRules('w'), elemChainOp('|')";

	/** A closed list with its rules builds, and an element that is no chain writes through the list layout. */
	public function testAClosedListWithItsRulesBuildsAndWrites(): Void {
		#if nodejs
		Assert.stringContains('a, b:', written('$LIST @:fmt($FLAGS)'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** The refusal under `@:trivia` is about the path, not the mode: the inline-element path builds. */
	public function testATriviaStarOnThePlainPathBuilds(): Void {
		#if nodejs
		Assert.equals('', triviaError('@:trivia $LIST @:fmt($FLAGS, inlineElemTrivia)'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-FLAG-ALLOWS-TRIVIA')
	public function testATriviaStarOffThePlainPathStopsTheBuild(): Void {
		#if nodejs
		Assert.stringContains(REFUSAL, triviaError('@:trivia $LIST @:fmt($FLAGS)'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-FLAG-ALLOWS-LEAD')
	public function testAnOpenDelimiterStopsTheBuild(): Void {
		#if nodejs
		Assert.stringContains(REFUSAL, written('@:lead(\'[\') @:trail(\']\') @:sep(\',\') @:fmt($FLAGS)'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-FLAG-ALLOWS-NO-TRAIL')
	public function testAListWithNoCloserStopsTheBuild(): Void {
		#if nodejs
		Assert.stringContains(REFUSAL, written('@:sep(\',\') @:fmt($FLAGS)'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-FLAG-ALLOWS-NO-SEP')
	public function testAListWithNoSeparatorStopsTheBuild(): Void {
		#if nodejs
		Assert.stringContains(REFUSAL, written('@:trail(\':\') @:fmt($FLAGS)'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-FLAG-ALLOWS-BARE')
	public function testAFlagNamingNoOperatorStopsTheBuild(): Void {
		#if nodejs
		Assert.stringContains(REFUSAL, written('$LIST @:fmt(wrapRules(\'w\'), elemChainOp)'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-FLAG-ALLOWS-NO-RULES')
	public function testAListWithNoRulesStopsTheBuild(): Void {
		#if nodejs
		Assert.stringContains(REFUSAL, written('$LIST @:fmt(elemChainOp(\'|\'))'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-FLAG-ALLOWS-TRAILING-COMMA')
	public function testATrailingCommaStopsTheBuild(): Void {
		#if nodejs
		Assert.stringContains(REFUSAL, written('$LIST @:fmt($FLAGS, trailingComma(\'tc\'))'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-FLAG-ALLOWS-TYPE-PARAM-CLOSE')
	public function testTypeParamCloseSpacingStopsTheBuild(): Void {
		#if nodejs
		Assert.stringContains(REFUSAL, written('$LIST @:fmt($FLAGS, typeParamClose)'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-FLAG-ALLOWS-BRACES-CLOSE')
	public function testObjectLiteralCloseSpacingStopsTheBuild(): Void {
		#if nodejs
		Assert.stringContains(REFUSAL, written('$LIST @:fmt($FLAGS, objectLiteralBracesClose)'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	#if nodejs
	/** What a grammar whose list field carries `metas` writes for `a`, `b`, or the compiler's complaint. */
	private static function written(metas: String): String {
		final main: String = "class Main { static function main() { final d: g.L = { items: ['a', 'b'] }; Sys.print(g.W.write(d)); } }\n";
		final run: js.node.ChildProcess.ChildProcessSpawnSyncResult = compile(main, metas, '', '--interp');
		return run.status == 0 ? '${run.stdout}' : '${run.stderr}';
	}

	/** The compiler's complaint about a trivia writer of a grammar whose list field carries `metas`, empty when it builds. */
	private static function triviaError(metas: String): String {
		final run: js.node.ChildProcess.ChildProcessSpawnSyncResult = compile(
			'class Main { static function main() { g.W; } }\n', metas, ', { trivia: true }', '--no-output'
		);
		return run.status == 0 ? '' : '${run.stderr}';
	}

	private static function compile(
		main: String, metas: String, writerOptions: String, mode: String
	): js.node.ChildProcess.ChildProcessSpawnSyncResult {
		final dir: String = CliFixture.writeDir('elem-chain-flag', [{ name: 'Main.hx', source: main }]);
		FileSystem.createDirectory('$dir/g');
		for (file in grammarFiles(metas, writerOptions)) File.saveContent('$dir/g/${file.name}', file.source);
		final run: js.node.ChildProcess.ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', [
			'-cp',
			'${Sys.getCwd()}/src',
			'-cp',
			dir,
			'--main',
			'Main',
			mode
		], cast { encoding: 'utf8' });
		CliFixture.removeDir(dir);
		return run;
	}

	private static function grammarFiles(metas: String, writerOptions: String): Array<{ name: String, source: String }> {
		final pkg: String = 'package g;\n';
		final defaults: String = 'defaultWriteOptions(default, null): anyparse.format.WriteOptions = {';
		final knobbed: String =
			'defaultWriteOptions(default, null): g.Opts = { w: { rules: [], defaultMode: anyparse.format.wrap.WrapMode.FillLine },';
		return [
			{ name: 'Atom.hx', source: '$pkg@:re(\'[a-z]+\') @:rawString abstract Atom(String) from String to String {}\n' },
			{ name: 'L.hx', source: '$pkg@:peg @:schema(g.Format) @:ws typedef L = { $metas var items: Array<Atom>; }\n' },
			{ name: 'Opts.hx', source: '${pkg}typedef Opts = anyparse.format.WriteOptions & { w: anyparse.format.wrap.WrapRules };\n' },
			{ name: 'W.hx', source: '$pkg@:build(anyparse.macro.Build.buildWriter(g.L, g.Opts$writerOptions)) class W {}\n' },
			{ name: 'Format.hx', source: pkg + TriviaTypeSynthTest.FORMAT.replace(defaults, knobbed) }
		];
	}
	#end

}
