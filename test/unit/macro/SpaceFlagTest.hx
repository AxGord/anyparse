package unit.macro;

using StringTools;

#if nodejs
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
#end

/**
 * `@:fmt(space('<knob>', '<side>'))` names the option that spaces a literal, asked of a second grammar by a child
 * compiler: the suite binary holds Haxe's grammar only, whose options the macro could be spelling.
 */
@:access(unit.macro.TriviaTypeSynthTest)
class SpaceFlagTest extends Test {

	/** The knob comes from the flag: an option only this grammar has reaches the generated switch, under each of its values. */
	@:pin('control')
	@:killer('M-SPACE-FLAG-KNOB-IGNORED')
	public function testASecondGrammarSpacesALeadByItsOwnOption(): Void {
		#if nodejs
		Assert.equals('a : b\n', written("space('gap', 'lead')", 'Both'));
		Assert.equals('a: b\n', written("space('gap', 'lead')", 'After'));
		Assert.equals('a:b\n', written("space('gap', 'lead')", 'None'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A misspelt knob is a missing option field, so it does not build instead of writing the literal tight. */
	public function testAKnobNoOptionDeclaresStopsTheBuild(): Void {
		#if nodejs
		final out: String = written("space('gapp', 'lead')", 'Both');
		Assert.isTrue(out.indexOf('gapp') != -1, out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A side nothing reads would leave the literal tight with no complaint, so the build refuses it, naming what it got. */
	public function testASideNothingReadsStopsTheBuild(): Void {
		#if nodejs
		final out: String = written("space('gap', 'laed')", 'Both');
		Assert.isTrue(out.indexOf('@:fmt(space)') != -1 && out.indexOf('laed') != -1, out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** So does the flag without its side, which reads as the same silence. */
	public function testAFlagWithoutASideStopsTheBuild(): Void {
		#if nodejs
		final out: String = written("space('gap')", 'Both');
		Assert.isTrue(out.indexOf('@:fmt(space)') != -1, out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/**
	 * The reader `spaceKnob` calls leaves out a non-string argument, which would read as no flag:
	 * the build refuses it, as it does the bare flag.
	 */
	public function testAFlagItCannotReadStopsTheBuild(): Void {
		#if nodejs
		final nonString: String = written("space(gap, 'lead')", 'Both');
		Assert.isTrue(nonString.indexOf('@:fmt(space)') != -1, nonString);
		final bare: String = written('space', 'Both');
		Assert.isTrue(bare.indexOf('@:fmt(space)') != -1, bare);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** The optional lead a format lists as tight reads the flag too, with no option name of its own to fall back on. */
	@:pin('control')
	@:killer('M-SPACE-FLAG-TIGHT-OPTIONAL-HARDWIRED')
	public function testATightOptionalLeadSpacesByItsOwnOption(): Void {
		#if nodejs
		final field: String = "@:optional @:lead(':') @:fmt(space('gap', 'lead')) var value: Null<Atom>;";
		Assert.equals('a : b\n', writtenField(field, 'Both', "'b'", true));
		Assert.equals('a:b\n', writtenField(field, 'None', "'b'", true));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/**
	 * Three positions read the flag. Anywhere else it is ignored without a complaint, even misspelt:
	 * this holds the limit `docs/strategies.md` states.
	 */
	public function testEverywhereElseTheFlagIsIgnored(): Void {
		#if nodejs
		final bad: String = "space('gapp', 'laed')";
		Assert.equals('a = b\n', writtenField('@:optional @:lead(\'=\') @:fmt($bad) var value: Null<Atom>;', 'Both'));
		Assert.equals(
			'a[b]\n', writtenField('@:lead(\'[\') @:trail(\']\') @:sep(\',\') @:fmt($bad) var value: Array<Atom>;', 'Both', "['b']")
		);
		Assert.equals('a b\n', writtenField('@:fmt($bad) var value: Atom;', 'Both'));
		final optional: String = "@:optional @:lead('=') @:fmt(space('gap', 'lead')) var value: Null<Atom>;";
		Assert.equals('a = b\n', writtenField(optional, 'None'));
		Assert.equals('a = b\n', writtenField(optional, 'Both'));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** The moved options are the grammar's to name: a lowering spelling one again is the regression. */
	public function testTheMacroNamesNoMovedOption(): Void {
		#if nodejs
		final macroDir: String = '${Sys.getCwd()}/src/anyparse/macro';
		final moved: EReg = ~/'(objectFieldColon|typeHintColon|typeCheckColon|typedefAssign|typedefIntersection|functionTypeHaxe4|arrowFunctions|catchParensInsideOpen|switchCondParensInsideOpen|whileCondParensInsideOpen)'/;
		for (name in FileSystem.readDirectory(macroDir))
			Assert.isFalse(name.endsWith('.hx') && moved.match(File.getContent('$macroDir/$name')), name);
		#else
		Assert.pass('node only: reads the tree');
		#end
	}

	#if nodejs
	/** What a grammar whose `:` lead carries `flag` writes for `a:b` with its `gap` option at `policy`, or the compiler's complaint. */
	private static function written(flag: String, policy: String): String {
		return writtenField('@:lead(\':\') @:fmt($flag) var value: Atom;', policy);
	}
	/**
	 * The same with `field` for the second field, holding `value`; `tightColon` makes the format list `:` as a tight lead.
	 */
	private static function writtenField(field: String, policy: String, value: String = "'b'", tightColon: Bool = false): String {
		final dir: String = CliFixture.writeDir('space-flag', [
			{
				name: 'Main.hx',
				source: 'class Main { static function main() { final d: g.Pair = { key: \'a\', value: $value'
				+ ' }; Sys.print(g.W.write(d)); } }\n'
			}
		]);
		FileSystem.createDirectory('$dir/g');
		for (file in grammarFiles(field, policy, tightColon)) File.saveContent('$dir/g/${file.name}', file.source);
		final run: js.node.ChildProcess.ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', [
			'-cp',
			'${Sys.getCwd()}/src',
			'-cp',
			dir,
			'--main',
			'Main',
			'--interp'
		], cast { encoding: 'utf8' });
		CliFixture.removeDir(dir);
		return run.status == 0 ? '${run.stdout}' : '${run.stderr}';
	}

	private static function grammarFiles(field: String, policy: String, tightColon: Bool): Array<{ name: String, source: String }> {
		final pkg: String = 'package g;\n';
		final defaults: String = 'defaultWriteOptions(default, null): anyparse.format.WriteOptions = {';
		final knobbed: String = 'defaultWriteOptions(default, null): g.Opts = { gap: anyparse.format.WhitespacePolicy.$policy,';
		final ctor: String = 'private function new() {}';
		final format: String = TriviaTypeSynthTest.FORMAT.replace(defaults, knobbed);
		return [
			{ name: 'Atom.hx', source: '$pkg@:re(\'[a-z]+\') @:rawString abstract Atom(String) from String to String {}\n' },
			{
				name: 'Pair.hx',
				source: '$pkg@:peg @:schema(g.Format) @:ws typedef Pair = { var key: Atom; $field }\n'
			},
			{ name: 'Opts.hx', source: '${pkg}typedef Opts = anyparse.format.WriteOptions & { gap: anyparse.format.WhitespacePolicy };\n' },
			{ name: 'W.hx', source: '$pkg@:build(anyparse.macro.Build.buildWriter(g.Pair, g.Opts)) class W {}\n' },
			{
				name: 'Format.hx',
				source: pkg
					+ (tightColon ? format.replace(ctor, 'public var tightLeads(default, null): Array<String> = [\':\'];\n$ctor') : format)
			}
		];
	}
	#end

}
