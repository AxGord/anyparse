package unit.macro;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.oracle.CompilerDisplayOracle;
import anyparse.check.oracle.OracleRunMemo;
import anyparse.proc.HaxeRun;
import anyparse.proc.HaxeSpawn;
import unit.cli.CliFixture;

using StringTools;

/**
 * A macro reads a format class's vocabulary from a compile and from a display query alike: display mode leaves the
 * initializers it does not need untyped, so a format class the query itself has to type — every one on a cold query, one
 * whose module a warm server dropped — would fail the macro and leave the query no answer. A display query reading a
 * different vocabulary than the compile would answer about a parser the compile does not generate.
 */
final class FormatReaderDisplayTest extends Test {

	#if (sys || nodejs)
	/** Far above any reply here; the display run only prints the macro's lines and one position list. */
	private static inline final OUTPUT: Int = 16 * 1024 * 1024;

	/** The line a fixture macro prints its readings on, told apart from whatever else the compiler says. */
	private static inline final READING: String = 'READING ';
	private static final MAIN: String = '@:build(Dump.build())\nclass Main {\n\tstatic function main() {}\n}\n';
	private static final WORD: String = 'enum abstract Word(String) {\n\tvar Plain = \'p\';\n\tvar Named;\n}\n';

	/** A format class of the fixture's own, so a test may rewrite it. */
	private static final FORMAT: String = 'class Fmt {\n\tpublic var whitespace:String = \' \';\n\tpublic var mappingOpen:String = \'{\';\n'
		+ '\tpublic var mappingClose:String = \'}\';\n\tpublic var keyValueSep:String = \':\';\n\tpublic var entrySep:String = \',\';\n'
		+ '\tpublic var fieldLookup:anyparse.format.text.FieldLookup = anyparse.format.text.FieldLookup.ByName;\n'
		+ '\tpublic var onUnknown:anyparse.format.text.UnknownPolicy = anyparse.format.text.UnknownPolicy.Error;\n'
		+ '\tpublic var onMissing:anyparse.format.text.MissingPolicy = anyparse.format.text.MissingPolicy.Error;\n\tpublic var '
		+ 'keySyntax:anyparse.format.text.KeySyntax = anyparse.format.text.KeySyntax.Unquoted;\n\tpublic function new() {}\n}\n';

	/** A consumer whose build macro reads `Fmt` and whose body names it. */
	private static final CONSUMER: String =
		'@:build(Dump.build())\nclass Main {\n\tstatic function main() {\n\t\ttrace(new Fmt());\n\t}\n}\n';
	#end

	/** The project's own test build, asked where a name in this very file is declared. */
	@:pin('control')
	@:killer('M-FORMAT-READ-COMPILE-ONLY')
	public function testAQueryOnTheTestBuildAnswersAPosition(): Void {
		#if (sys || nodejs)
		final file: String = 'test/unit/macro/FormatReaderDisplayTest.hx';
		final at: Int = sys.io.File.getContent(file).lastIndexOf('parsePositionResponse');
		final run: HaxeRun = HaxeSpawn.run(['test-js.hxml', '--no-output', '--display', '$file@$at@position'], null, OUTPUT);
		final position: Null<TypeReplyPosition> = CompilerDisplayOracle.parsePositionResponse('${run.out}${run.err}');
		Assert.isTrue(position?.file.endsWith('CompilerDisplayOracle.hx'), '${run.out}${run.err}');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A run rewrote the format class, so the warm server drops its module and the query in a consumer types it afresh. */
	@:pin('control')
	@:killer('M-FORMAT-READ-COMPILE-ONLY')
	public function testAWarmServerAnswersAfterAFormatClassMoved(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_format_warm', [
			{ name: 'Main.hx', source: CONSUMER },
			{ name: 'Fmt.hx', source: FORMAT },
			{ name: 'Dump.hx', source: dumpOf('anyparse.macro.FormatReader.resolve("Fmt");') },
			{ name: 'build.hxml', source: buildOf() }
		]);
		final memo: OracleRunMemo = new OracleRunMemo(false, () -> ['$root/Fmt.hx', '$root/Main.hx']);
		final config: OracleConfig = OracleRunMemo.attach([{ hxml: 'build.hxml', dir: root, defines: [] }], memo)[0];
		memo.servers.start([config]);
		sys.io.File.saveContent('$root/Fmt.hx', '// moved\n$FORMAT');
		final position: Null<TypeReplyPosition> = memo.servers.positionIn(config, '$root/Main.hx', CONSUMER, CONSUMER.indexOf('Fmt'));
		memo.servers.stop();
		CliFixture.removeDir(root);
		Assert.isTrue(position?.file.endsWith('Fmt.hx'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Every format class of the tree: its literals, its null fields, its enum abstract values and the binary one. */
	@:pin('control')
	@:killer('M-FORMAT-ENUM-VALUE-BY-SPELLING')
	public function testEveryFormatReadsTheSameUnderDisplay(): Void {
		#if (sys || nodejs)
		final formats: Array<String> = [
			for (path in [
				'anyparse.grammar.haxe.HaxeFormat',
				'anyparse.grammar.json.JsonFormat',
				'anyparse.grammar.mermaid.MermaidFormat',
				'anyparse.format.text.SExprFormat',
				'anyparse.format.comment.CFamilyCommentFormat',
				'anyparse.format.binary.ArFormat'
			]) 'Sys.println("$READING" + haxe.Json.stringify(anyparse.macro.FormatReader.resolve("$path")));'
		];
		assertSameReadings(formats.join('\n'), formats.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The values of an `enum abstract(String)`, which decide whether a grammar terminal is a keyword set or a regex. */
	@:pin('control')
	@:killer('M-SHAPE-STRING-ENUM-COMPILE-ONLY')
	public function testAStringEnumReadsTheSameUnderDisplay(): Void {
		#if (sys || nodejs)
		assertSameReadings(
			'switch haxe.macro.Context.getType("Word") {\ncase TAbstract(a, _): Sys.println("$READING'
			+ '" + haxe.Json.stringify(@:privateAccess anyparse.macro.ShapeBuilder.extractStringEnumValues(a.get())));\ncase _:\n}',
			1
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The lines the build macro with body `body` prints from a compile equal those from a display query, `count` of them. */
	private function assertSameReadings(body: String, count: Int): Void {
		final root: String = CliFixture.writeTree('apq_format_display', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'Word.hx', source: WORD },
			{ name: 'Dump.hx', source: dumpOf(body) },
			{ name: 'build.hxml', source: buildOf() }
		]);
		final compiled: Array<String> = readings(['build.hxml'], root);
		final displayed: Array<String> = readings(['build.hxml', '--display', 'Main.hx@0@position'], root);
		CliFixture.removeDir(root);
		Assert.equals(count, compiled.length, compiled.join('\n'));
		Assert.same(compiled, displayed);
	}

	/** A module whose `Dump.build` macro runs `body` and adds nothing. */
	private static function dumpOf(body: String): String {
		return 'class Dump {\n\tpublic static macro function build():Array<haxe.macro.Expr.Field> {\n$body\nreturn null;\n\t}\n}\n';
	}

	/** A build of the fixture's `Main` with this project's macros on the class path. */
	private static function buildOf(): String {
		return '-cp .\n-cp ${sys.FileSystem.absolutePath('src')}\n-main Main\n--no-output\n';
	}

	/** What the run of `args` in `cwd` printed on its reading lines. */
	private static function readings(args: Array<String>, cwd: String): Array<String> {
		final run: HaxeRun = HaxeSpawn.run(args, cwd, OUTPUT);
		return [
			for (line in '${run.out}\n${run.err}'.split('\n')) if (line.startsWith(READING)) line
		];
	}
	#end

}
