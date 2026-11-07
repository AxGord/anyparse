package unit.check;

import anyparse.check.Check;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.check.oracle.CompilerOracle;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.query.cli.command.LintFixVerify;
import anyparse.runtime.Span;
import haxe.io.Path;
import unit.cli.CliFixture;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * End-to-end coverage of `FixVerifier`'s BATCH judgement: one risky check's candidates in several files are written
 * together and typechecked as one round, and a rejected set is judged in halves so the files that build still land.
 * `TestRiskyLiteralRewrite` rewrites each file's literal `1` and `AppendFake` appends a declaration; the fixture
 * decides which edits build.
 *
 * Every scenario but the unavailable one drives the real compiler, so each probes availability first and skips when
 * the host has no `haxe`; the unavailable one hands `judgeBatch` a configuration that cannot run.
 */
@:nullSafety(Strict)
@:access(anyparse.check.FixVerifier)
final class FixVerifierBatchE2ETest extends Test {

	#if (sys || nodejs)
	private static final HXML: String = '-cp .\n-main Main\n';
	private static final MAIN: String =
		'class Main {\n\n\tstatic function main() {\n\t\tA.f();\n\t\tB.f();\n\t\tC.f();\n\t\tD.f();\n\t}\n\n}\n';

	/** The fixture's four candidate modules, in the order the verifier is handed them. */
	private static final NAMES: Array<String> = ['A', 'B', 'C', 'D'];

	/** A literal any rewrite keeps building: `trace` takes anything. */
	private static final TRACED: Array<String> = NAMES.map(traced);
	#end

	/**
	 * Four files whose rewrites all build are applied by ONE typecheck of the whole set — the round count a
	 * file-by-file pass spent once per file.
	 */
	@:pin('control')
	@:killer('M-FIXVERIFY-BATCH-NONE')
	public function testOneRoundJudgesEveryFileOfACheck(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = fixture(TRACED);
		final result: FixVerifyResult = verify(dir, TRACED, new TestRiskyLiteralRewrite('2'));
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else the count is vacuous');
		Assert.equals(4, result.applied.length);
		Assert.equals(4, result.appliedEdits);
		Assert.equals('[4]', Std.string(result.rounds), 'one round judged all four candidates');
		for (name in NAMES) Assert.notEquals(-1, File.getContent('$dir/$name.hx').indexOf('trace(2)'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * One file whose rewrite breaks the build: the set is rejected, the files the compiler's errors do not blame are kept
	 * in one round, and only the blamed file is judged alone.
	 */
	@:pin('control')
	@:killer('M-FIXVERIFY-BATCH-NO-BLAME')
	public function testARejectedSetKeepsTheFilesThatBuild(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final sources: Array<String> = [
			traced('A'),
			traced('B'),
			'class C {\n\n\tpublic static var v:Int = 1;\n\n\tpublic static function f() {}\n\n}\n',
			traced('D')
		];
		final dir: String = fixture(sources);
		final result: FixVerifyResult = verify(dir, sources, new TestRiskyLiteralRewrite('"x"'));
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		Assert.equals(3, result.applied.length);
		Assert.equals(1, result.reverted.length);
		Assert.equals('$dir/C.hx', result.reverted[0].file);
		Assert.equals(sources[2], File.getContent('$dir/C.hx'), 'the failing file is byte-identical to its input');
		for (name in ['A', 'B', 'D']) Assert.notEquals(-1, File.getContent('$dir/$name.hx').indexOf('trace("x")'));
		Assert.equals(
			'[4,3,1]', Std.string(result.rounds), 'the whole set, the three files the errors do not blame, then the blamed file alone'
		);
		Assert.equals(
			', 3 oracle round(s) (candidate files per round: 4, 3, 1)', LintFixVerify.roundsTail(result.rounds),
			'the summary clause the run prints for these rounds'
		);
		Assert.equals('', LintFixVerify.roundsTail([]), 'a run that spent no round prints nothing');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two failing files in different halves: both are blamed by the errors and judged alone, the two files that build are
	 * kept in one round — the files that build land and each failer reverts.
	 */
	@:pin('control')
	@:killer('M-FIXVERIFY-BATCH-NO-BLAME')
	public function testEveryBlamedFileIsJudgedAloneAndTheRestTogether(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final sources: Array<String> = [intField('A'), traced('B'), traced('C'), intField('D')];
		final dir: String = fixture(sources);
		final result: FixVerifyResult = verify(dir, sources, new TestRiskyLiteralRewrite('"x"'));
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		Assert.equals('[$dir/B.hx,$dir/C.hx]', Std.string(result.applied));
		Assert.equals('[$dir/A.hx,$dir/D.hx]', Std.string(result.reverted.map(r -> r.file)));
		Assert.equals(sources[0], File.getContent('$dir/A.hx'), 'a failing file is byte-identical to its input');
		Assert.equals(sources[3], File.getContent('$dir/D.hx'), 'a failing file is byte-identical to its input');
		Assert.equals(
			'[4,2,1,1]', Std.string(result.rounds), 'the whole set, the two unblamed files as one batch, then each blamed file alone'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A and D's edits build alone but not together — each declares the same module-level type — and B's never builds.
	 * Every rejected batch is put back at its own texts before any file is judged again, so A lands and D, judged on
	 * top of it, reverts.
	 */
	@:pin('control')
	@:killer('M-FIXVERIFY-BATCH-NO-RESTORE')
	public function testAnUnkeptCandidateIsBackAtItsTextBeforeAFileIsJudgedAlone(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final sources: Array<String> = NAMES.map(plain);
		final dir: String = fixture(sources);
		final tails: Map<String, String> = [
			'A.hx' => '\ntypedef Clash = Int;\n',
			'B.hx' => '\ntypedef Bad = NoSuchType;\n',
			'C.hx' => '\ntypedef Alias = Int;\n',
			'D.hx' => '\ntypedef Clash = Int;\n'
		];
		final result: FixVerifyResult = verify(dir, sources, new AppendFake(tails));
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		Assert.equals('[$dir/A.hx,$dir/C.hx]', Std.string(result.applied));
		Assert.equals('[$dir/B.hx,$dir/D.hx]', Std.string(result.reverted.map(r -> r.file)));
		Assert.equals(sources[3], File.getContent('$dir/D.hx'), 'the second of the clashing pair is byte-identical to its input');
		Assert.equals(
			'[4,3,1,2,1,1,1]', Std.string(result.rounds),
			'the whole set, the three it does not blame (their clash is blamed on Main, so halves), then B alone'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * An oracle that cannot run on the batch round says nothing about any file, so the set is not split: every file is
	 * put back at its own text and judged alone, each reverting with the oracle's own reason.
	 */
	@:pin('control')
	@:killer('M-FIXVERIFY-BATCH-UNAVAILABLE-SPLITS')
	public function testAnUnavailableBatchJudgesEveryFileAlone(): Void {
		#if (sys || nodejs)
		final disk: Map<String, String> = [];
		final unavailable: OracleConfig = {
			hxml: 'none.hxml',
			dir: null,
			defines: [],
			unavailable: 'no compiler in this test'
		};
		final rounds: Array<Int> = [];
		final verdicts: Array<String> = FixVerifier.judgeBatch([
			for (name in NAMES) {
				entry: { file: '$name.hx', source: plain(name) },
				edits: [{ span: new Span(0, 0), text: '// x\n', group: null }],
				opts: null,
				fullText: '// x\n${plain(name)}',
				verifying: [unavailable]
			}
		], new HaxeQueryPlugin(), (file, text) -> disk[file] = text, rounds)
			.map(Std.string);
		Assert.equals('[4,1,1,1,1]', Std.string(rounds), 'the batch round, then each file alone — no halves');
		for (verdict in verdicts) Assert.equals('Reverted(OracleUnavailable(no compiler in this test))', verdict);
		for (name in NAMES) Assert.equals(plain(name), disk['$name.hx'], 'every file is back at its input text');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A failing rewrite whose error is reported in a module no candidate edits (`Main` reads the field the rewrite
	 * retypes): the errors blame no candidate, so the rejected set is judged in halves — the half without the failer is
	 * kept in one round and the half holding it is split down to files judged alone.
	 */
	@:pin('control')
	@:killer('M-FIXVERIFY-BATCH-NO-SPLIT')
	public function testErrorsBlamingNoCandidateJudgeTheSetInHalves(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final sources: Array<String> = [
			traced('A'),
			traced('B'),
			'class C {\n\n\tpublic static var v = 1;\n\n\tpublic static function f() {}\n\n}\n',
			traced('D')
		];
		final main: String = 'class Main {\n\n\tstatic function main() {\n\t\tA.f();\n\t\tB.f();\n\t\tC.f();\n\t\tD.f();\n'
			+ '\t\tfinal x:Int = C.v;\n\t}\n\n}\n';
		final dir: String = fixture(sources, main);
		final result: FixVerifyResult = verify(dir, sources, new TestRiskyLiteralRewrite('"x"'));
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		Assert.equals('[$dir/A.hx,$dir/B.hx,$dir/D.hx]', Std.string(result.applied));
		Assert.equals('[$dir/C.hx]', Std.string([for (r in result.reverted) r.file]));
		Assert.equals(sources[2], File.getContent('$dir/C.hx'), 'the failing file is byte-identical to its input');
		Assert.equals('[4,2,2,1,1]', Std.string(result.rounds), 'the whole set, its two halves, then the files of the rejected half alone');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Every candidate's rewrite breaks the build: the errors blame them all, the rest is empty (no round spent on it),
	 * and each file is judged alone — cheaper than a descent through halves for failers that do not depend on each other.
	 */
	@:pin('control')
	@:killer('M-FIXVERIFY-BATCH-NO-BLAME')
	public function testASetWhoseEveryFileIsBlamedJudgesEachAlone(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final sources: Array<String> = [intField('A'), intField('B'), intField('C')];
		final main: String = 'class Main {\n\n\tstatic function main() {\n\t\tA.f();\n\t\tB.f();\n\t\tC.f();\n\t}\n\n}\n';
		final dir: String = fixture(sources, main);
		final result: FixVerifyResult = verify(dir, sources, new TestRiskyLiteralRewrite('"x"'));
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		Assert.equals(0, result.applied.length);
		Assert.equals(3, result.reverted.length);
		Assert.equals('[3,1,1,1]', Std.string(result.rounds), 'the whole set, then each blamed file alone — no round on the empty rest');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function traced(name: String): String {
		return 'class $name {\n\n\tpublic static function f() {\n\t\ttrace(1);\n\t}\n\n}\n';
	}

	/** A module whose literal `1` initialises an `Int` field, so a string rewrite of it does not build. */
	private static function intField(name: String): String {
		return 'class $name {\n\n\tpublic static var v:Int = 1;\n\n\tpublic static function f() {}\n\n}\n';
	}

	/** A module holding nothing but the function `MAIN` calls. */
	private static function plain(name: String): String {
		return 'class $name {\n\n\tpublic static function f() {}\n\n}\n';
	}

	private static function fixture(sources: Array<String>, ?main: String): String {
		return CliFixture.writeDir('fixverifbatch', [
			for (i => source in sources) { name: '${NAMES[i]}.hx', source: source }
		].concat([{ name: 'Main.hx', source: main ?? MAIN }, { name: 'check.hxml', source: HXML }]));
	}

	private static function verify(dir: String, sources: Array<String>, check: Check): FixVerifyResult {
		final files: Array<FileText> = [
			for (i => source in sources) { file: '$dir/${NAMES[i]}.hx', source: source }
		];
		return FixVerifier.verify(files, [check], new HaxeQueryPlugin(), [{ hxml: 'check.hxml', dir: dir, defines: [] }], File.saveContent);
	}

	private static function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('fixverifbatch', [
			{ name: 'Main.hx', source: 'class Main {\n\n\tstatic function main() {}\n\n}\n' },
			{ name: 'check.hxml', source: HXML }
		]);
		final ok: Bool = CompilerOracle.typecheck('check.hxml', dir).match(Confirmed);
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}

/**
 * A `Check` + `RiskyFix` stand-in that appends a fixed text to each file named in its table, so a scenario can make
 * two files' edits build alone and clash together.
 */
@:nullSafety(Strict)
private class AppendFake implements Check implements RiskyFix {

	private final _tails: Map<String, String>;

	public function new(tails: Map<String, String>) {
		_tails = tails;
	}

	public function id(): String {
		return 'append-fake';
	}

	public function description(): String {
		return 'test double: appends a fixed text to each file its table names';
	}

	public function category(): RuleCategory {
		return RuleCategory.Design;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) if (_tails.exists(Path.withoutDirectory(entry.file))) {
				file: entry.file,
				span: null,
				rule: id(),
				severity: Severity.Warning,
				message: 'test double finding'
			}
		];
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final tail: Null<String> = violations.length == 0 ? null : _tails[Path.withoutDirectory(violations[0].file)];
		if (tail == null) return [];
		final text: String = tail;
		return [{ span: new Span(source.length, source.length), text: text }];
	}

}
