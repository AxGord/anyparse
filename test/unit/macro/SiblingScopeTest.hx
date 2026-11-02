package unit.macro;

using StringTools;

#if nodejs
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
#end

/**
 * A sibling slot outside every list sharing its knob stops the build, asked of a second grammar by a child compiler:
 * the suite binary holds Haxe's grammar only, and that one has to build. So does a grammar whose slot sits in a region
 * nested inside a shared list, which is what `HxConditionalCase` is.
 */
@:access(unit.macro.TriviaTypeSynthTest)
class SiblingScopeTest extends Test {

	/** The grammar's `Item`, its list reached through a struct field. */
	private static final ITEM_SOURCE: String = "package g; enum Item { @:trail(';') Word(s: Atom); Open(open: g.Open); }\n";

	/** Every slot is under a list declaring its knob, one of them through a nested region. */
	public function testASharedSlotBuilds(): Void {
		#if nodejs
		Assert.equals('', compilerError("siblingShare('k')"));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** Dropping the flag from the list is the hole this closes: the error names the way down to the slot. */
	@:pin('control')
	@:killer('M-SIBLING-SCOPE-NEVER-REFUSES')
	public function testASlotNoListSharesStopsTheBuild(): Void {
		#if nodejs
		final error: String = compilerError('nestBody');
		Assert.isTrue(
			error.indexOf('sibling slot of knob "k" at Doc.items.Item.Open.open.Open.cases.Case.Branch.branch.Branch.body') != -1, error
		);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A list sharing another knob resolves nothing of this one. */
	public function testAListSharingAnotherKnobDoesNotCount(): Void {
		#if nodejs
		final error: String = compilerError("siblingShare('other')");
		Assert.isTrue(error.indexOf('sibling slot of knob "k"') != -1, error);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/**
	 * The flags on an enum ctor land on the branch, not on its Star, and that Star takes another emit path that never
	 * wraps the list in a decision. So the same list spelled as a ctor must not count as sharing, or its slots ship unresolved.
	 */
	public function testAListOnAnEnumCtorDoesNotCount(): Void {
		#if nodejs
		final item: String = "package g; enum Item { @:trail(';') Word(s: Atom); "
			+ "@:lead('{') @:trail('}') @:trivia @:fmt(siblingShare('k')) Open(cases: Array<Case>); }\n";
		final error: String = compilerError('nestBody', item);
		Assert.isTrue(error.indexOf('sibling slot of knob "k"') != -1, error);
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	#if nodejs
	/** The compiler's complaint about a grammar whose case list carries `listFlag`, empty when it builds. */
	private static function compilerError(listFlag: String, ?itemSource: String): String {
		final dir: String = CliFixture.writeDir(
			'sibling-scope', [{ name: 'Main.hx', source: 'class Main { static function main() { g.W; } }\n' }]
		);
		FileSystem.createDirectory('$dir/g');
		for (file in grammarFiles(listFlag, itemSource ?? ITEM_SOURCE)) File.saveContent('$dir/g/${file.name}', file.source);
		final build: js.node.ChildProcess.ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', [
			'-cp',
			'${Sys.getCwd()}/src',
			'-cp',
			dir,
			'--main',
			'Main',
			'--no-output'
		], cast { encoding: 'utf8' });
		CliFixture.removeDir(dir);
		return build.status == 0 ? '' : '${build.stderr}';
	}

	/** The second grammar's format, its writer defaults carrying the two knobs of `Opts`. */
	private static function formatWithKnobs(): String {
		final defaults: String = 'defaultWriteOptions(default, null): anyparse.format.WriteOptions = {';
		final knobs: String = 'defaultWriteOptions(default, null): g.Opts = {'
			+ ' k: anyparse.format.SiblingPolicy.Off, other: anyparse.format.SiblingPolicy.Off,';
		return TriviaTypeSynthTest.FORMAT.replace(defaults, knobs);
	}

	/** Words, and a `{ … }` list of labelled branches whose bodies are slots, with an `if … ;` region among the branches. */
	private static function grammarFiles(listFlag: String, itemSource: String): Array<{ name: String, source: String }> {
		final head: String = 'package g;\n';
		return [
			{ name: 'Atom.hx', source: '$head@:re(\'[a-z]+\') @:rawString abstract Atom(String) from String to String {}\n' },
			{ name: 'Item.hx', source: itemSource },
			{
				name: 'Open.hx',
				source: '$head@:peg typedef Open = { @:lead(\'{\') @:trail(\'}\') @:trivia @:fmt($listFlag) var cases: Array<Case>; }\n'
			},
			{ name: 'Case.hx', source: '${head}enum Case { Branch(branch: g.Branch); Region(region: g.Region); }\n' },
			{
				name: 'Region.hx',
				source: '$head@:peg typedef Region = { @:kw(\'if\') @:trivia @:tryparse var cases: Array<Case>; @:lead(\';\') '
					+ 'var end: Atom; }\n'
			},
			{
				name: 'Branch.hx',
				source: '$head@:peg typedef Branch = { @:lead(\'-\') '
					+ 'var label: Atom; @:trivia @:tryparse @:fmt(nestBody, siblingSlot(\'k\')) var body: Array<Item>; }\n'
			},
			{ name: 'Doc.hx', source: '$head@:peg @:schema(g.Format) @:ws typedef Doc = { @:trivia var items: Array<Item>; }\n' },
			{
				name: 'Opts.hx',
				source: '${head}typedef Opts = anyparse.format.WriteOptions & {'
					+ ' k: anyparse.format.SiblingPolicy, other: anyparse.format.SiblingPolicy };\n'
			},
			{ name: 'W.hx', source: '$head@:build(anyparse.macro.Build.buildWriter(g.Doc, g.Opts, { trivia: true })) class W {}\n' },
			{ name: 'Format.hx', source: head + formatWithKnobs() }
		];
	}
	#end

}
