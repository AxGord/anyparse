package unit.macro;

#if nodejs
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
#end

/**
 * Asked of a second grammar by a child compiler, because the suite binary's own options are one class that can never
 * reach the struct ceiling: how many knobs a struct may carry, and a class's way past it.
 */
@:access(unit.macro.TriviaTypeSynthTest)
class OptionsRecordTest extends Test {

	#if nodejs
	/** The base `WriteOptions` knobs a class must carry to unify with it, and the one knob the fixture grammar reads. */
	private static final BASE_FIELDS: String = "
		public var gap: anyparse.format.WhitespacePolicy = Both;
		public var indentChar: anyparse.format.IndentChar = Tab;
		public var indentSize: Int = 1;
		public var tabWidth: Int = 4;
		public var lineWidth: Int = 80;
		public var lineEnd: String = '\\n';
		public var finalNewline: Bool = true;
		public var keyValueSpace: Bool = false;
		public var trailingWhitespace: Bool = false;
		public var commentStyle: anyparse.format.CommentStyle = Verbatim;
		public var addLineCommentSpace: Bool = true;
		public var normalizeLineCommentIndent: Bool = false;
		public var compressSuccessiveParenthesis: Bool = true;
		public var arrayMatrixWrap: anyparse.format.ArrayMatrixWrap = NoMatrixWrap;
		public var trailingComma: anyparse.format.TrailingCommaPolicy = Keep;
		public var conditionalPolicy: anyparse.format.ConditionalIndentationPolicy = Aligned;
		public var alignInlineSwitchCaseBody: Bool = false;
		public var comprehensionCuddledOpen: Bool = false;
		public var soleItemCuddledBrackets: Bool = false;
		public var methodChainCuddledLinks: Bool = false;
		public var ternaryCuddledBraces: Bool = false;
		public var maxConsecutiveBlanks: Int = -1;
		public var blockCommentAdapter: Null<(String, anyparse.format.WriteOptions) -> anyparse.core.Doc> = null;
		public var lineCommentAdapter: Null<(Array<String>, Int, anyparse.format.WriteOptions) -> String> = null;
		public var betweenImportsPathDiffers: Null<(String, String, Int) -> Bool> = null;
	";
	#end

	/** The refusal names the count, and the count is calibrated off the refusal, so the base shape may grow under this test. */
	@:pin('control')
	@:killer('M-OPTIONS-SLOT-GUARD-OFF')
	public function testAStructIsRefusedAtTheFirstSlotPastTheLimit(): Void {
		#if nodejs
		final atLimit: Int = knobsAtTheLimit();
		final past: BuildRun = compile(structOptions(atLimit + 1, 'Int'), '');
		Assert.notEquals(0, past.code);
		Assert.isTrue(past.out.indexOf('takes 255 JVM argument slots') != -1, past.out);
		final fits: BuildRun = compile(structOptions(atLimit, 'Int'), '');
		Assert.equals(0, fits.code, fits.out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/**
	 * A `double` argument takes two slots and a boxed one takes one: the
	 * first struct fits by fields and not by slots, the second the reverse.
	 */
	@:pin('control')
	@:killer('M-OPTIONS-SLOTS-ARE-FIELDS')
	public function testAFloatTakesTwoSlotsAndABoxedFloatOne(): Void {
		#if nodejs
		final atLimit: Int = knobsAtTheLimit();
		final floats: Int = Std.int(atLimit / 2) + 1;
		final doubled: BuildRun = compile(structOptions(floats, 'Float'), '');
		Assert.isTrue(doubled.out.indexOf('JVM argument slots') != -1, doubled.out);
		final boxed: BuildRun = compile(structOptions(atLimit, 'Null<Float>'), '');
		Assert.equals(0, boxed.code, boxed.out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	@:pin('control')
	@:killer('M-OPTIONS-LONG-IS-ONE-SLOT')
	public function testAnInt64TakesTwoSlots(): Void {
		#if nodejs
		final longs: Int = Std.int(knobsAtTheLimit() / 2) + 1;
		final refused: BuildRun = compile(structOptions(longs, 'haxe.Int64'), '');
		Assert.isTrue(refused.out.indexOf('JVM argument slots') != -1, refused.out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A class holds as many knobs as it likes, and its writer reads one by field. */
	public function testAClassPastTheLimitBuildsAndWrites(): Void {
		#if nodejs
		final built: BuildRun = compile(
			classOptions(300, ''), 'js.Syntax.code("process.stdout.write({0})", g.W.write(g.P.parse("a:b"), new g.Opts()));'
		);
		Assert.equals(0, built.code, built.out);
		Assert.equals('a : b\n', built.out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A clone runs no default: an initializer left on a field would allocate its nested records per clone, which no output shows. */
	@:pin('control')
	@:killer('M-OPTIONS-CLASS-KEEPS-INITIALIZERS')
	public function testACloneRunsNoDefault(): Void {
		#if nodejs
		final run: BuildRun = compile(
			classOptions(0, 'public var counted: Int = Main.tick();'),
			'new g.Opts(new g.Opts()); js.Syntax.code("process.stdout.write(String({0}))", ticks);'
		);
		Assert.equals(0, run.code, run.out);
		Assert.equals('1', run.out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A field with no initializer is a knob with no default, which the build names instead of leaving it null at the first read. */
	public function testAKnobWithoutADefaultStopsTheBuild(): Void {
		#if nodejs
		final out: String = compile(classOptions(0, 'public var bare: Int;'), '').out;
		Assert.isTrue(out.indexOf('Opts.bare declares no default') != -1, out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A record holds knobs only: the constructor is generated, so a member of another kind has no contract with the clone. */
	public function testAMemberThatIsNoKnobStopsTheBuild(): Void {
		#if nodejs
		final out: String = compile(classOptions(0, 'public function f(): Void {}'), '').out;
		Assert.isTrue(out.indexOf('Opts.f is not a plain field') != -1, out);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	#if nodejs
	/** How many knobs of one slot this tree's base shape leaves room for, read off the refusal of an over-full struct. */
	private static function knobsAtTheLimit(): Int {
		final out: String = compile(structOptions(300, 'Int'), '').out;
		final taken: EReg = ~/takes ([0-9]+) JVM argument slots/;
		Assert.isTrue(taken.match(out), out);
		final slots: Int = Std.parseInt(taken.matched(1)) ?? 0;
		return 254 - (slots - 300);
	}

	private static function structOptions(knobs: Int, type: String): String {
		final fields: String = [for (i in 0...knobs) 'k$i: $type'].join(', ');
		return 'typedef Opts = anyparse.format.WriteOptions & { gap: anyparse.format.WhitespacePolicy, $fields };\n';
	}

	private static function classOptions(knobs: Int, extra: String): String {
		final lines: Array<String> = [for (i in 0...knobs) 'public var k$i: Int = 0;'];
		final fields: String = BASE_FIELDS + lines.join('\n') + extra;
		return '@:build(anyparse.macro.Build.buildOptionsRecord()) final class Opts {\n$fields\n}\n';
	}

	private static function compile(options: String, body: String): BuildRun {
		final main: String = 'class Main { static var ticks: Int = 0; public static function tick(): Int { return ++ticks; } '
			+ 'static function main() { final write = g.W.write; $body } }\n';
		final dir: String = CliFixture.writeDir('options-record', [{ name: 'Main.hx', source: main }]);
		FileSystem.createDirectory('$dir/g');
		for (file in grammarFiles(options)) File.saveContent('$dir/g/${file.name}', file.source);
		final build: js.node.ChildProcess.ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', [
			'-cp',
			'${Sys.getCwd()}/src',
			'-cp',
			dir,
			'--main',
			'Main',
			'--js',
			'$dir/out.js'
		], cast { encoding: 'utf8' });
		final out: String = build.status == 0
			? '${js.node.ChildProcess.spawnSync('node', ['$dir/out.js'], cast { encoding: 'utf8' }).stdout}'
			: '${build.stderr}';
		CliFixture.removeDir(dir);
		return { code: build.status, out: out };
	}

	private static function grammarFiles(options: String): Array<{ name: String, source: String }> {
		final pkg: String = 'package g;\n';
		final source: String = TriviaTypeSynthTest.FORMAT;
		final from: Int = source.indexOf('public var defaultWriteOptions');
		final to: Int = source.indexOf('private function new');
		final format: String =
			'${source.substring(0, from)}public var defaultWriteOptions(default, null): Any = null;\n${source.substring(to)}';
		return [
			{ name: 'Atom.hx', source: '$pkg@:re(\'[a-z]+\') @:rawString abstract Atom(String) from String to String {}\n' },
			{
				name: 'Pair.hx',
				source: '$pkg@:peg @:schema(g.Format) @:ws typedef Pair = { var key: Atom; @:lead(\':\') @:fmt(space(\'gap\', \'lead\')) '
					+ 'var value: Atom; }\n'
			},
			{ name: 'Opts.hx', source: pkg + options },
			{ name: 'P.hx', source: '$pkg@:build(anyparse.macro.Build.buildParser(g.Pair)) class P {}\n' },
			{ name: 'W.hx', source: '$pkg@:build(anyparse.macro.Build.buildWriter(g.Pair, g.Opts)) class W {}\n' },
			{ name: 'Format.hx', source: pkg + format }
		];
	}
	#end

}

#if nodejs
private typedef BuildRun = { code: Int, out: String };
#end
