package unit;

import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.PreferInline;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * End-to-end coverage of `FixVerifier.verify`'s CANDIDATE SCOPE: a risky check's
 * `run` must see the WHOLE lint file set, exactly as the report run does. The
 * regression fixture mirrors a real incident: `prefer-inline`'s subtype-override
 * gate is whole-project (`SymbolIndex.hasSubtype`), so computing candidates from
 * one file at a time re-exposed a method whose override lives in a sibling file —
 * and the compiler oracle could not catch it, because its hxml (an app target)
 * never compiles the overriding subtype (a test tree, in the incident). The safe
 * loop routes such rules through `fullScopeIds` (`Cli.applyLintFixes`); this suite
 * pins the risky path to the same horizon.
 *
 * Spawns the real compiler, so each scenario probes availability and skips
 * gracefully when the host has no `haxe` on PATH.
 */
@:nullSafety(Strict)
final class FixVerifierScopeE2ETest extends Test {

	#if (sys || nodejs)
	/** A thin single-expression body — a `prefer-inline` benefit-class candidate on its own. */
	private static final BASE: String = 'class Base {\n\n\tpublic function new() {}\n\n\tpublic function hook():Int\n\t\treturn 1;\n\n}\n';

	/** The override that must veto the candidate — declared in a SIBLING file of the lint set. */
	private static final SUB: String = 'class Sub extends Base {\n\n\toverride public function hook():Int\n\t\treturn 2;\n\n}\n';

	/**
	 * The oracle's entry point references `Base` but never `Sub`, so the compiled set is
	 * BLIND to the override — only the check's own subtype gate can refuse the inline.
	 */
	private static final MAIN: String = 'class Main {\n\n\tstatic function main() {\n\t\tfinal b:Base = new Base();\n\t\ttrace(b.hook());\n'
		+ '\t\ttrace(b.hook());\n\t}\n\n}\n';

	/** A candidate-free entry point for the grouping fixture. */
	private static final GROUP_MAIN: String =
		'class Main {\n\n\tstatic function main() {\n\t\ttrace(Lib.one());\n\t\ttrace(Lib.one());\n\t}\n\n}\n';

	/** A clean candidate in the SECOND file of the set — inlining it must still land. */
	private static final LIB: String = 'class Lib {\n\n\tpublic static function one():Int\n\t\treturn 1;\n\n}\n';

	private static final HXML: String = '-cp .\n-main Main\n';
	#end

	public function testSubtypeOverrideInASiblingFileVetoesTheRiskyInline(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixverifscope', [
			{ name: 'Base.hx', source: BASE },
			{ name: 'Sub.hx', source: SUB },
			{ name: 'Main.hx', source: MAIN },
			{ name: 'check.hxml', source: HXML }
		]);
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/Base.hx', source: BASE },
			{ file: '$dir/Sub.hx', source: SUB },
			{ file: '$dir/Main.hx', source: MAIN }
		];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new PreferInline()],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — otherwise these negatives are vacuous');
		Assert.equals(0, result.applied.length, 'an override in a sibling file vetoes the candidate — the oracle cannot see it');
		Assert.equals(0, result.reverted.length, 'vetoed at candidate time, not applied-then-reverted');
		// The counters above are also 0 for a coverage DECLINE, so without this the assertion
		// would stop pinning the mechanism it names the day this fixture's files fell outside
		// the oracle's compiled set.
		Assert.equals(0, result.declined.length, 'and vetoed by the rule, not declined for want of oracle coverage');
		Assert.equals(-1, File.getContent('$dir/Base.hx').indexOf('inline'), 'disk keeps hook physical');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCandidateInASiblingFileIsStillApplied(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixverifscope', [
			{ name: 'Main.hx', source: GROUP_MAIN },
			{ name: 'Lib.hx', source: LIB },
			{ name: 'check.hxml', source: HXML }
		]);
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/Main.hx', source: GROUP_MAIN },
			{ file: '$dir/Lib.hx', source: LIB }
		];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new PreferInline()],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		Assert.equals(1, result.applied.length, 'the full-scope run still attributes the candidate to its own file');
		Assert.notEquals(-1, File.getContent('$dir/Lib.hx').indexOf('inline function one'), 'disk carries the inline');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('fixverifscope', [
			{ name: 'Main.hx', source: 'class Main {\n\n\tstatic function main() {}\n\n}\n' },
			{ name: 'check.hxml', source: HXML }
		]);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
