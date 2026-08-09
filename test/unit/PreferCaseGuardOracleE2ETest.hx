package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.PreferCaseGuard;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * End-to-end coverage of `prefer-case-guard` as a `RiskyFix` consumer, plus the
 * production canonical path its unit suite cannot reach.
 *
 * The rule's one unprovable gate is the dotted pattern head it cannot resolve: a
 * constant class is accepted (the shape the rule exists for), but an `enum` /
 * `enum abstract` declared OUTSIDE the report scope is accepted too, and guarding one
 * of its arms is an `Unmatched patterns` compile error. `RiskyFix` is the belt for
 * exactly that residual, and the revert fixture below is that residual made concrete:
 * the enum abstract is on the classpath but NOT in the linted file set, so the check
 * accepts it and the oracle is the only thing that catches the break.
 *
 * The compiler-spawning scenarios probe availability and skip gracefully when the host
 * has no `haxe` on PATH.
 */
@:nullSafety(Strict)
final class PreferCaseGuardOracleE2ETest extends Test {

	/** `maxLineLength` 140 and nothing else -- the config both fixtures below are canonical under. */
	private static final HXFORMAT: String = '{"wrapping": {"maxLineLength": 140}}\n';

	// A statement switch over a plain constant class: the guard conversion typechecks, so
	// the oracle applies it. Writer-canonical under HXFORMAT, which is what lets the
	// production fix path run with `reformat` OFF.
	private static final APPLIES: String = 'class Codes {\n\tpublic static inline final DOWN:Int = 1;\n'
		+ '\tpublic static inline final UP:Int = 2;\n'
		+ '\n\tprivate function new() {}\n}\n\nclass Good {\n\tpublic static var hit:Int = 0;\n\n\tpublic static function main():Void {\n'
		+ '\t\trun(Codes.DOWN);\n\t}\n\n\tprivate static function run(code:Int):Void {\n\t\tswitch code {\n\t\t\tcase Codes.DOWN:\n'
		+ '\t\t\t\tif (hit == 0) {\n\t\t\t\t\thit = 1;\n\t\t\t\t\ttrace(hit);\n\t\t\t\t}\n\t\t\tcase Codes.UP:\n\t\t\t\ttrace(hit);\n'
		+ '\t\t}\n\t}\n}\n';

	// The same shape over an `enum abstract` the report scope cannot see: the check accepts
	// the dotted head, the guard makes the arm list non-exhaustive, and the build breaks.
	private static final REVERTS: String = 'class Bad {\n\tpublic static var hit:Int = 0;\n\n\tpublic static function main():Void {\n'
		+ '\t\trun(Ek.A);\n\t}\n\n\tprivate static function run(code:Ek):Void {\n\t\tswitch code {\n\t\t\tcase Ek.A:\n'
		+ '\t\t\t\tif (hit == 0) {\n\t\t\t\t\thit = 1;\n\t\t\t\t\ttrace(hit);\n\t\t\t\t}\n\t\t\tcase Ek.B:\n\t\t\t\ttrace(hit);\n'
		+ '\t\t}\n\t}\n}\n';

	/** On the classpath for the compiler, deliberately NOT in the linted file set. */
	private static final ENUM_ABSTRACT: String = 'enum abstract Ek(Int) {\n\tfinal A = 1;\n\tfinal B = 2;\n}\n';

	private static final GOOD_HXML: String = '-cp .\n-main Good\n';
	private static final BAD_HXML: String = '-cp .\n-main Bad\n';

	/**
	 * The PRODUCTION canonical path, no compiler involved: the edits are re-emitted with
	 * `reformat` OFF, which requires the source to already satisfy `writeRoundTrip`. The
	 * unit suite's minimal fixtures all run with `reformat` on, so nothing else pins this.
	 */
	public function testCanonicalPathAppliesWithoutReformat(): Void {
		final check: PreferCaseGuard = new PreferCaseGuard();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			APPLIES, check.run([{ file: 'Good.hx', source: APPLIES }], plugin), plugin
		);
		Assert.equals(1, edits.length);
		switch RefactorSupport.canonicalize(APPLIES, edits, false, plugin, HXFORMAT) {
			case Ok(text):
				Assert.isTrue(text.indexOf('case Codes.DOWN if (hit == 0):') != -1);
				Assert.equals(-1, text.indexOf('if (hit == 0) {'));
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testGuardAppliedWhenValid(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable - skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('pcgok', [
			{ name: 'Good.hx', source: APPLIES },
			{ name: 'check.hxml', source: GOOD_HXML },
			{ name: 'hxformat.json', source: HXFORMAT }
		]);
		final path: String = '$dir/Good.hx';
		final result: FixVerifyResult = FixVerifier.verify(
			[{ file: path, source: APPLIES }],
			[new PreferCaseGuard()], new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
		);
		Assert.equals(1, result.applied.length, 'a guard the build accepts is applied');
		Assert.equals(0, result.reverted.length);
		Assert.isTrue(File.getContent(path).indexOf('case Codes.DOWN if (hit == 0):') != -1, 'disk carries the converted label');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testGuardRevertedWhenExhaustivenessBreaks(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable - skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('pcgbad', [
			{ name: 'Bad.hx', source: REVERTS },
			{ name: 'Ek.hx', source: ENUM_ABSTRACT },
			{ name: 'check.hxml', source: BAD_HXML },
			{ name: 'hxformat.json', source: HXFORMAT }
		]);
		final path: String = '$dir/Bad.hx';
		// Ek.hx is on the classpath but NOT in this list, so the check cannot resolve the head.
		final result: FixVerifyResult = FixVerifier.verify(
			[{ file: path, source: REVERTS }],
			[new PreferCaseGuard()], new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
		);
		Assert.equals(0, result.applied.length, 'a guard that breaks exhaustiveness is not applied');
		Assert.equals(1, result.reverted.length, 'it is reverted to a report-only fallback');
		Assert.isTrue(File.getContent(path).indexOf('case Ek.A:') != -1, 'disk is restored to the unguarded arm');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** With no oracle configured a plain `RiskyFix` stays report-only: nothing is written. */
	public function testReportOnlyWithoutOracleViaCli(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('pcgnooracle', [
			{ name: 'Good.hx', source: APPLIES },
			{ name: 'hxformat.json', source: HXFORMAT }
		]);
		Cli.run(['lint', '--fix', '--rule', 'prefer-case-guard', '$dir/Good.hx']);
		Assert.equals(APPLIES, File.getContent('$dir/Good.hx'), 'without an oracle the risky conversion is report-only');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir(
			'pcgprobe', [{ name: 'Good.hx', source: APPLIES }, { name: 'check.hxml', source: GOOD_HXML }]
		);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
