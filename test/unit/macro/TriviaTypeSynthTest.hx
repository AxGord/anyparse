package unit.macro;

#if nodejs
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
#end

/**
 * Two trivia grammars in ONE compilation: each synth module gets its own `Converters` and `TailComments`, and each
 * grammar's writer keeps its comments. The suite binary builds Haxe's trivia grammar only, so the pair is built here
 * by a child compiler against this tree's `src` and the program it emits is run.
 */
class TriviaTypeSynthTest extends Test {

	/** A source the fixture grammar writes back byte for byte: a line comment at its head and one after a list element. */
	private static final SOURCE: String = '# head\nfoo;\n[\n\ta;,\n\tb; # after b\n]\n';

	/** The fixture grammars' format: the fields `FormatReader` reads, a `#` line comment, and writer defaults. */
	private static final FORMAT: String = "final class Format {
		public static final instance: Format = new Format();
		public var name(default, null): String = 'T';
		public var version(default, null): String = '1';
		public var encoding(default, null): anyparse.format.Encoding = anyparse.format.Encoding.UTF8;
		public var whitespace(default, null): String = ' \\t\\n\\r';
		public var lineComment(default, null): Null<String> = '#';
		public var mappingOpen(default, null): String = '(';
		public var mappingClose(default, null): String = ')';
		public var sequenceOpen(default, null): Null<String> = '[';
		public var sequenceClose(default, null): Null<String> = ']';
		public var keyValueSep(default, null): String = ':';
		public var entrySep(default, null): String = ',';
		public var keySyntax(default, null): anyparse.format.text.KeySyntax = Unquoted;
		public var fieldLookup(default, null): anyparse.format.text.FieldLookup = ByName;
		public var onMissing(default, null): anyparse.format.text.MissingPolicy = Error;
		public var onUnknown(default, null): anyparse.format.text.UnknownPolicy = Skip;
		public var defaultWriteOptions(default, null): anyparse.format.WriteOptions = {
			indentChar: Tab, indentSize: 1, tabWidth: 4, lineWidth: 80, lineEnd: '\\n', finalNewline: true,
			trailingWhitespace: false, maxConsecutiveBlanks: -1, commentStyle: Verbatim, arrayMatrixWrap: NoMatrixWrap,
			trailingComma: Keep, conditionalPolicy: Aligned, alignInlineSwitchCaseBody: false, comprehensionCuddledOpen: false,
			soleItemCuddledBrackets: false, methodChainCuddledLinks: false, ternaryCuddledBraces: false,
			addLineCommentSpace: true, normalizeLineCommentIndent: false, compressSuccessiveParenthesis: true
		};
		private function new() {}
		public inline function escapeChar(c: Int): String return String.fromCharCode(c);
	}
	";

	/** Both grammars compile beside each other and each round-trips its comments. */
	@:pin('control') @:killer('M-TRIVIA-SYNTH-ONCE-PER-COMPILATION')
	public function testTwoTriviaGrammarsBuildAndRoundTripInOneCompilation(): Void {
		#if nodejs
		Assert.equals('$SOURCE|$SOURCE', roundTrips(['ga', 'gb']));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	#if nodejs
	/**
	 * The output of a program built from one trivia grammar per package in `packs`, or the compiler error.
	 */
	private static function roundTrips(packs: Array<String>): String {
		final calls: Array<String> = [for (pack in packs) '$pack.W.write($pack.P.parse(src))'];
		final main: String = 'class Main { static function main() { final src = ${haxe.Json.stringify(SOURCE)}; '
			+ 'js.Syntax.code("process.stdout.write({0})", [${calls.join(', ')}].join("|")); } }\n';
		final dir: String = CliFixture.writeDir('trivia2', [{ name: 'Main.hx', source: main }]);
		for (pack in packs) {
			FileSystem.createDirectory('$dir/$pack');
			for (file in grammarFiles(pack)) File.saveContent('$dir/$pack/${file.name}', file.source);
		}
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
		return out;
	}

	/** One trivia grammar in package `pack`: `;`-terminated words and bracketed comma lists of them, `#` comments. */
	private static function grammarFiles(pack: String): Array<{ name: String, source: String }> {
		final head: String = 'package $pack;\n';
		return [
			{ name: 'Atom.hx', source: '$head@:re(\'[a-z]+\') @:rawString abstract Atom(String) from String to String {}\n' },
			{
				name: 'Item.hx',
				source: head
					+ "enum Item { @:trail(';') Word(s: Atom); @:trivia @:lead('[') @:trail(']') @:sep(',') List(items: Array<Item>); }\n"
			},
			{ name: 'Doc.hx', source: '$head@:peg @:schema($pack.Format) @:ws typedef Doc = { @:trivia var items: Array<Item>; }\n' },
			{ name: 'Opts.hx', source: '${head}typedef Opts = anyparse.format.WriteOptions & {};\n' },
			{ name: 'P.hx', source: '$head@:build(anyparse.macro.Build.buildParser($pack.Doc, { trivia: true })) class P {}\n' },
			{
				name: 'W.hx',
				source: '$head@:build(anyparse.macro.Build.buildWriter($pack.Doc, $pack.Opts, { trivia: true })) class W {}\n'
			},
			{ name: 'Format.hx', source: head + FORMAT }
		];
	}
	#end

}
