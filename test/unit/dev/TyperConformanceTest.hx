package unit.dev;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
#end
import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.query.ConfigFinder;
import anyparse.query.LexicalRegions;
import anyparse.runtime.Span;
import dev.TyperConformance;
import haxe.Exception;

/**
 * `dev typer-conformance probes` as a gate: a probe project's run counts only when it read something — every configuration
 * compiled, some project file compiled, some case scored — so a project that does not compile, or a compiler that does not
 * start, fails the gate instead of passing it with no DIFFERENT to show.
 */
@:nullSafety(Strict)
final class TyperConformanceTest extends Test {

	#if (sys || nodejs)
	private static final PROBE: String = 'class Probe {\n\tstatic function main() {\n\t\tfinal n: Int = 1;\n\t\ttrace(n + 1);\n\t}\n}\n';
	private static final BROKEN: String = 'class Probe {\n\tstatic function main() {\n\t\tfinal n: Int = "one";\n\t\ttrace(n);\n\t}\n}\n';
	private static final HXML: String = '-cp src\n-main Probe\n--interp\n--no-output\n';
	private static final CONFIG: String =
		'{\n\t"compilerOracle": "typer.hxml",\n\t"compilerOracleServer": false,\n\t"resolutionRoots": ["src"]\n}\n';
	#end

	public function testARunThatReadNothingIsRefused(): Void {
		Assert.isNull(TyperConformance.probeRefusal(run([], 1, 1, 3)), 'a run that compiled and scored');
		Assert.notNull(TyperConformance.probeRefusal(run(['p.hxml: the compile failed'], 1, 1, 3)), 'a dropped configuration');
		Assert.notNull(TyperConformance.probeRefusal(run([], 0, 0, 0)), 'no configuration compiled');
		Assert.notNull(TyperConformance.probeRefusal(run([], 1, 0, 0)), 'no project file compiled');
		Assert.notNull(TyperConformance.probeRefusal(run([], 1, 1, 0)), 'no case scored');
	}

	/** A probe project with a type error fails the gate, where the same project compiling passes it. */
	public function testAProbeProjectThatDoesNotCompileFailsTheGate(): Void {
		#if (sys || nodejs)
		final good: String = corpus(PROBE);
		final broken: String = corpus(BROKEN);
		CliFixture.always(() -> {
			CliFixture.removeDir(good);
			CliFixture.removeDir(broken);
		}, () -> {
			Assert.equals(0, TyperConformance.main(['probes', good]), 'the project compiling');
			Assert.equals(1, TyperConformance.main(['probes', broken]), 'the project with a type error');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A probe project named by the legacy config file name is a probe project too. */
	public function testALegacyNamedProbeProjectIsRun(): Void {
		#if (sys || nodejs)
		final dir: String = corpus(PROBE);
		FileSystem.rename('$dir/probe/apq.json', '$dir/probe/${ConfigFinder.LEGACY_PROJECT_CONFIG}');
		CliFixture.always(
			CliFixture.removeDir.bind(dir), () -> Assert.equals(0, TyperConformance.main(['probes', dir]), 'the legacy name')
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A compiler that does not start (no `haxe` on the `PATH`) fails the gate rather than reading zero cases as a pass. */
	public function testACompilerThatDoesNotStartFailsTheGate(): Void {
		#if (sys || nodejs)
		final dir: String = corpus(PROBE);
		final empty: String = CliFixture.writeDir('nohaxe', []);
		final path: Null<String> = Sys.getEnv('PATH');
		Sys.putEnv('PATH', empty);
		CliFixture.always(() -> {
			Sys.putEnv('PATH', path ?? '');
			CliFixture.removeDir(dir);
			CliFixture.removeDir(empty);
		}, () -> Assert.equals(1, TyperConformance.main(['probes', dir]), 'no haxe to launch'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A display test's statements end at a `;` that is code: one in a string or a comment ends nothing. */
	@:pin('control')
	@:killer('M-TYPER-STATEMENTS-NONCODE')
	public function testAStatementEndsAtACodeSemicolon(): Void {
		Assert.same(['a("x;y")', 'b(1) /* ; */', '// ; c()'], TyperConformance.statementsOf('a("x;y"); b(1) /* ; */;\n // ;\n c();'));
	}

	/** The brace closing a test body is the first code `}` past the opening one, from where the body starts. */
	@:pin('control')
	@:killer('M-TYPER-CLOSING-BRACE-FROM')
	public function testTheClosingBraceIsACodeBraceFromWhereTheBodyStarts(): Void {
		final text: String = '{ a; "}" /* } */ // }\n b; } z }';
		final code: Array<Span> = LexicalRegions.codeSpans(text.length, new HaxeQueryPlugin().lexicalRegions(text));
		Assert.equals(text.indexOf('} z'), TyperConformance.closingBrace(text, code, 1));
	}

	/** A throwing typer answer reads as UNKNOWN and is counted, by currency and kind, with the first sites only. */
	@:pin('control')
	@:killer('M-TYPER-SWALLOWED-COUNT')
	public function testAThrowingAnswerIsCountedWhereItIsSwallowed(): Void {
		final swallowed: SwallowedExceptions = new SwallowedExceptions();
		Assert.equals('Int', swallowed.guarded('source', () -> 'never', () -> 'Int'), 'an answer is passed through');
		Assert.equals(0, swallowed.count(), 'an answer is no fault');
		for (n in 0...5) Assert.isNull(swallowed.guarded('nominal', () -> 'F.hx:$n:1', () -> throw new Exception('boom $n')), 'UNKNOWN');
		Assert.isNull(swallowed.guarded('source', () -> 'G.hx:1:1', () -> throw new Exception('late')));
		Assert.equals(6, swallowed.count());
		final fields: Array<String> = swallowed.line().split('\t');
		Assert.equals('CENSUS-SWALLOWED', fields[0]);
		Assert.equals('6', fields[1]);
		Assert.equals('nominal/haxe.Exception=5, source/haxe.Exception=1', fields[2]);
		Assert.equals('F.hx:0:1 boom 0 | F.hx:1:1 boom 1 | F.hx:2:1 boom 2', fields[3]);
	}

	private static function run(dropped: Array<String>, configurations: Int, compiled: Int, cases: Int): FactsRun {
		return {
			configurations: configurations,
			dropped: dropped,
			files: 1,
			compiled: compiled,
			cases: cases
		};
	}

	#if (sys || nodejs)
	/** A probe corpus of one project, `probe/`, whose one module is `source`. */
	private static function corpus(source: String): String {
		final root: String = CliFixture.writeDir('typerprobes', []);
		FileSystem.createDirectory('$root/probe/src');
		File.saveContent('$root/probe/src/Probe.hx', source);
		File.saveContent('$root/probe/typer.hxml', HXML);
		File.saveContent('$root/probe/apq.json', CONFIG);
		return root;
	}
	#end

}
