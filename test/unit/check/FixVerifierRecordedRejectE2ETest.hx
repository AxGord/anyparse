package unit.check;

import anyparse.check.Check;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.check.haxe.oracle.CompilerOracle;
import anyparse.check.haxe.oracle.OracleCache;
import anyparse.check.haxe.oracle.RejectedFixes;
import anyparse.query.Cli;
import anyparse.query.GrammarPlugin;
import anyparse.query.OracleProvider.OracleOutcome;
import anyparse.query.OracleProviders;
import anyparse.query.SymbolIndex;
import anyparse.query.cli.command.LintFixVerify;
import anyparse.runtime.Span;
import unit.cli.CliFixture;

using StringTools;

#if (sys || nodejs)
import sys.io.File;
#end

/** A `Check` + `RiskyFix` stand-in that rewrites every `= 1` of a file to `= "x"`: two edits, two UNITS, each breaking an `Int` field. */
@:nullSafety(Strict)
private final class EveryLiteralRewrite implements Check implements RiskyFix {

	public function new() {}

	public function id(): String {
		return 'every-literal-rewrite';
	}

	public function description(): String {
		return 'test double: rewrites every `= 1` of a file';
	}

	public function category(): RuleCategory {
		return RuleCategory.Literals;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [ for (entry in files) if (entry.source.indexOf('= 1') >= 0) {
			file: entry.file,
			span: null,
			rule: id(),
			severity: Severity.Warning,
			message: 'test double finding'
		} ];
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final edits: Array<FixEdit> = [];
		var at: Int = source.indexOf('= 1');
		while (at >= 0) {
			edits.push({ span: new Span(at + 2, at + 3), text: '"x"' });
			at = source.indexOf('= 1', at + 1);
		}
		return edits;
	}

}

/**
 * End-to-end coverage of the ledger of rejected fix candidates: a risky edit the compiler refused is not compiled again
 * by a later `FixVerifier.verify` on the same bytes, and anything that changes what the compiler would answer — the
 * edit's result, an hxml, an explicit forget, `apq oracle` — makes it ask again. Every scenario drives the real compiler,
 * so each probes availability first and skips when the host has no `haxe`; `rounds` is the verifier's own count of the
 * typechecks it spent, so an empty one is a run that compiled nothing.
 */
@:nullSafety(Strict)
final class FixVerifierRecordedRejectE2ETest extends Test {

	#if (sys || nodejs)
	private static final HXML: String = '-cp .\n-main Main\n';
	private static final NAMES: Array<String> = ['A', 'B', 'C'];

	/** A module whose literal `1` initialises an `Int` field, so a string rewrite of it does not build. */
	private static final BAD: String = 'class A {\n\n\tpublic static var v:Int = 1;\n\n\tpublic static function f() {}\n\n}\n';
	#end

	/** The first run learns the rejection from the compiler; the second, on the same bytes, spends no typecheck on it. */
	@:pin('control')
	@:killer('M-FIXREJECT-ALONE-IGNORES-LEDGER')
	@:killer('M-FIXREJECT-REJECTION-NOT-RECORDED')
	public function testARejectionIsNotCompiledAgainOnIdenticalBytes(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = fixture([BAD]);
		final first: FixVerifyResult = verify(dir, ['A'], new TestRiskyLiteralRewrite('"x"'));
		Assert.isTrue(first.baseline.match(Confirmed), 'the oracle baseline must confirm — else the rejection is vacuous');
		Assert.equals('[1]', Std.string(first.rounds));
		Assert.isTrue(first.reverted[0].cause.match(OracleRejected));
		final second: FixVerifyResult = verify(dir, ['A'], new TestRiskyLiteralRewrite('"x"'));
		Assert.equals('[]', Std.string(second.rounds), 'no typecheck was spent on the recorded rejection');
		Assert.equals(1, second.reverted.length);
		Assert.isTrue(second.reverted[0].cause.match(OracleRecordedReject));
		Assert.equals('the compiler rejected it (recorded verdict)', LintFixVerify.revertCauseText(second.reverted[0].cause));
		Assert.equals(BAD, File.getContent('$dir/A.hx'), 'the file is byte-identical to its input');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A rejection is a fact about one result: another rewrite of the same bytes goes to the compiler. */
	@:pin('control')
	@:killer('M-FIXREJECT-KEY-IGNORES-RESULT')
	public function testAnotherRewriteOfTheSameBytesIsCompiled(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = fixture([BAD]);
		Assert.equals('[1]', Std.string(verify(dir, ['A'], new TestRiskyLiteralRewrite('"x"')).rounds), 'the first rewrite is compiled');
		final other: FixVerifyResult = verify(dir, ['A'], new TestRiskyLiteralRewrite('"y"'));
		Assert.equals('[1]', Std.string(other.rounds));
		Assert.isTrue(other.reverted[0].cause.match(OracleRejected));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The compile input changed (an hxml define), so the remembered rejection no longer speaks for it. */
	@:pin('control')
	@:killer('M-FIXREJECT-KEY-IGNORES-INPUTS')
	public function testAChangedHxmlInvalidatesTheRecordedRejection(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = fixture([BAD]);
		Assert.equals('[1]', Std.string(verify(dir, ['A'], new TestRiskyLiteralRewrite('"x"')).rounds), 'the first run compiles it');
		File.saveContent('$dir/check.hxml', '$HXML-D recorded_reject_probe\n');
		final changed: FixVerifyResult = verify(dir, ['A'], new TestRiskyLiteralRewrite('"x"'));
		Assert.isTrue(changed.baseline.match(Confirmed));
		Assert.equals('[1]', Std.string(changed.rounds));
		Assert.isTrue(changed.reverted[0].cause.match(OracleRejected));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * One failing file among four: the first run spends the whole set, the files the errors do not blame and the blamed
	 * file alone; the second sets the recorded file aside, so only the three that build are typechecked, in one round.
	 */
	@:pin('control')
	@:killer('M-FIXREJECT-BATCH-KEEPS-RECORDED')
	public function testARecordedRejectIsSetAsideBeforeTheBatch(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final sources: Array<String> = [
			traced('A'),
			traced('B'),
			'class C {\n\n\tpublic static var v:Int = 1;\n\n\tpublic static function f() {}\n\n}\n'
		];
		final dir: String = fixture(sources);
		final first: FixVerifyResult = verify(dir, ['A', 'B', 'C'], new TestRiskyLiteralRewrite('"x"'));
		Assert.isTrue(first.baseline.match(Confirmed));
		Assert.equals('[3,2,1]', Std.string(first.rounds));
		for (i => name in ['A', 'B', 'C']) File.saveContent('$dir/$name.hx', sources[i]);
		final second: FixVerifyResult = verify(dir, ['A', 'B', 'C'], new TestRiskyLiteralRewrite('"x"'));
		Assert.equals('[2]', Std.string(second.rounds), 'the two files that build, in one round; the recorded one costs none');
		Assert.equals(2, second.applied.length);
		Assert.equals(1, second.reverted.length);
		Assert.equals('$dir/C.hx', second.reverted[0].file);
		Assert.isTrue(second.reverted[0].cause.match(OracleRecordedReject));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `forgetRejects` drops the ledger: the same bytes go to the compiler again. */
	@:pin('control')
	@:killer('M-FIXREJECT-FORGET-NOOP')
	public function testForgettingMakesTheCompilerAskedAgain(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = fixture([BAD]);
		Assert.equals('[1]', Std.string(verify(dir, ['A'], new TestRiskyLiteralRewrite('"x"')).rounds), 'the first run compiles it');
		OracleProviders.of(new HaxeQueryPlugin()).forgetRejects([{ hxml: 'check.hxml', dir: dir, defines: [] }]);
		final again: FixVerifyResult = verify(dir, ['A'], new TestRiskyLiteralRewrite('"x"'));
		Assert.equals('[1]', Std.string(again.rounds));
		Assert.isTrue(again.reverted[0].cause.match(OracleRejected));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `apq oracle` observes the build cold, so what a fix run remembered the compiler rejecting is dropped. */
	@:pin('control')
	@:killer('M-FIXREJECT-ORACLE-COMMAND-KEEPS')
	public function testTheOracleCommandForgetsRecordedRejections(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = fixture([BAD]);
		File.saveContent('$dir/apq.json', '{"compilerOracle":"check.hxml"}');
		Assert.equals('[1]', Std.string(verify(dir, ['A'], new TestRiskyLiteralRewrite('"x"')).rounds), 'the first run compiles it');
		final config: OracleConfig = { hxml: 'check.hxml', dir: dir, defines: [] };
		final edited: String = BAD.replace('= 1', '= "x"');
		Assert.isTrue(RejectedFixes.recorded([config], '$dir/A.hx', BAD, edited), 'the first run recorded this very edit');
		CliFixture.captureStderr(() -> Cli.run(['oracle', '$dir/Main.hx']));
		Assert.isFalse(RejectedFixes.recorded([config], '$dir/A.hx', BAD, edited), 'the cold typecheck dropped it');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A file whose two edits both break the build: the first run spends the whole set and the bisect's probes; the second
	 * answers every one of them from the ledger, so it spent nothing and its revert does not claim the compiler judged it.
	 */
	@:pin('control')
	@:killer('M-FIXREJECT-PARTIAL-CLAIMS-COMPILER')
	public function testABisectAnsweredEntirelyFromTheLedgerSaysSo(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final two: String =
			'class A {\n\n\tpublic static var v:Int = 1;\n\n\tpublic static var w:Int = 1;\n\n\tpublic static function f() {}\n\n}\n';
		final dir: String = fixture([two]);
		final first: FixVerifyResult = verify(dir, ['A'], new EveryLiteralRewrite());
		Assert.isTrue(first.baseline.match(Confirmed));
		Assert.isTrue(first.rounds.length > 1, 'the first run bisected: ${first.rounds}');
		Assert.isTrue(first.reverted[0].cause.match(OracleRejected));
		final second: FixVerifyResult = verify(dir, ['A'], new EveryLiteralRewrite());
		Assert.equals('[]', Std.string(second.rounds), 'no typecheck was spent');
		Assert.equals(1, second.reverted.length);
		Assert.isTrue(second.reverted[0].cause.match(OracleRecordedReject));
		Assert.equals(two, File.getContent('$dir/A.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A rejection belongs to the project of the build that judged it, not to the directory the process runs in: two fixture
	 * projects keep two ledgers, and `apq oracle` on one drops only its own.
	 */
	@:pin('control')
	@:killer('M-FIXREJECT-LEDGER-BY-PROCESS-CWD')
	public function testTheLedgerIsTheProjectOfTheBuildNotTheProcessDirectory(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final mine: String = fixture([BAD]);
		final other: String = fixture([BAD]);
		final edited: String = BAD.replace('= 1', '= "x"');
		for (dir in [mine, other])
			Assert.equals('[1]', Std.string(verify(dir, ['A'], new TestRiskyLiteralRewrite('"x"')).rounds), 'the first run compiles it');
		final mineConfig: OracleConfig = { hxml: 'check.hxml', dir: mine, defines: [] };
		final otherConfig: OracleConfig = { hxml: 'check.hxml', dir: other, defines: [] };
		Assert.notEquals(OracleCache.rejectsFile(mineConfig), OracleCache.rejectsFile(otherConfig), 'one ledger per project');
		File.saveContent('$mine/apq.json', '{"compilerOracle":"check.hxml"}');
		CliFixture.captureStderr(() -> Cli.run(['oracle', '$mine/Main.hx']));
		Assert.isFalse(RejectedFixes.recorded([mineConfig], '$mine/A.hx', BAD, edited), 'the project it ran for is forgotten');
		Assert.isTrue(RejectedFixes.recorded([otherConfig], '$other/A.hx', BAD, edited), 'another project keeps its rejection');
		CliFixture.removeDir(mine);
		CliFixture.removeDir(other);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function traced(name: String): String {
		return 'class $name {\n\n\tpublic static function f() {\n\t\ttrace(1);\n\t}\n\n}\n';
	}

	/** A `Main` calling the first `count` modules, so the baseline compiles every one of them. */
	private static function mainSource(count: Int): String {
		return 'class Main {\n\n\tstatic function main() {\n'
			+ NAMES.slice(0, count).map(name -> '\t\t$name.f();\n').join('')
			+ '\t}\n\n}\n';
	}

	private static function fixture(modules: Array<String>): String {
		return CliFixture.writeDir('fixverifrecorded', [ for (i => source in modules) { name: '${NAMES[i]}.hx', source: source } ].concat([
			{ name: 'Main.hx', source: mainSource(modules.length) },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apq.json', source: '{}' }
		]));
	}

	/** One verification of the named modules as they stand on disk, with the real compiler and the project's ledger. */
	private static function verify(dir: String, names: Array<String>, check: Check): FixVerifyResult {
		final files: Array<FileText> = names.map(name -> { file: '$dir/$name.hx', source: File.getContent('$dir/$name.hx') });
		return FixVerifier.verify(files, [check], new HaxeQueryPlugin(), [{ hxml: 'check.hxml', dir: dir, defines: [] }], File.saveContent);
	}

	private static function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('fixverifrecorded', [
			{ name: 'Main.hx', source: 'class Main {\n\n\tstatic function main() {}\n\n}\n' },
			{ name: 'check.hxml', source: HXML }
		]);
		final ok: Bool = CompilerOracle.typecheck('check.hxml', dir).match(Confirmed);
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
