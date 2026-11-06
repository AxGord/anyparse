package unit.dev;

import anyparse.check.LintConfig;
import dev.Binaries;
import haxe.io.Path;
import sys.io.File;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * The split between a real build and the typecheck the compiler oracle runs: every build leaf of `Binaries.HXMLS` carries
 * `-D analyzer-optimize`, the typecheck leaf `Binaries.checkOf` names carries the same flags without it, and `apq.json`
 * declares the typecheck leaf to the oracle, never the build leaf.
 */
@:nullSafety(Strict)
final class BuildFlagsTest extends Test {

	/** The line that makes a typecheck leaf write nothing, whoever runs it by hand. */
	private static inline final TYPECHECK_ONLY: String = '--no-output';

	private static final CODEGEN: String = Binaries.CODEGEN.join(' ');

	public function testEveryBuildLeafCarriesTheCodegenFlagAndNoTypecheckLeafDoes(): Void {
		for (leaf in Binaries.HXMLS) {
			Assert.contains(CODEGEN, flags(leaf), '$leaf is a real build');
			Assert.notContains(CODEGEN, flags(Binaries.checkOf(leaf)), '${Binaries.checkOf(leaf)} is a typecheck');
		}
	}

	public function testATypecheckLeafIsItsBuildLeafWithoutTheCodegenFlag(): Void {
		for (leaf in Binaries.HXMLS) {
			final build: Array<String> = flags(leaf).filter(flag -> flag != CODEGEN);
			final check: Array<String> = flags(Binaries.checkOf(leaf));
			Assert.contains(TYPECHECK_ONLY, check, '${Binaries.checkOf(leaf)} writes nothing');
			Assert.notContains(TYPECHECK_ONLY, build, '$leaf is a real build');
			Assert.equals(build.join('\n'), check.filter(flag -> flag != TYPECHECK_ONLY).join('\n'), leaf);
		}
	}

	public function testTheOracleIsDeclaredTheTypecheckLeavesOnly(): Void {
		final declared: Array<String> = [
			for (oracle in LintConfig.discover('apq.json').compilerOracles()) Path.normalize(oracle.hxml)
		];
		for (leaf in Binaries.HXMLS) {
			Assert.isTrue(declared.exists(hxml -> hxml.endsWith('/${Binaries.checkOf(leaf)}')), 'declared: ${Binaries.checkOf(leaf)}');
			Assert.isFalse(declared.exists(hxml -> hxml.endsWith('/$leaf')), 'not declared: $leaf');
		}
	}

	/** Every engine build (the shared leaf, `dev worker-build`, `dev base-engine`) reaches full DCE through the engine's common flags. */
	public function testTheEngineIsBuiltUnderFullDce(): Void {
		Assert.contains('-dce full', flags('bin/apq-js-common.hxml'));
	}

	public function testATypecheckLeafIsNamedByItsBuildLeaf(): Void {
		Assert.equals('bin/apq-js-check.hxml', Binaries.checkOf('bin/apq-js.hxml'));
		Assert.equals('test-js-check.hxml', Binaries.checkOf('test-js.hxml'));
	}

	/** The flag lines of `hxml` with every hxml it includes expanded in place, sorted; a `--cmd` is a build step, not a flag. */
	private static function flags(hxml: String): Array<String> {
		final out: Array<String> = [];
		for (raw in File.getContent(hxml).split('\n')) {
			final line: String = raw.trim();
			if (line == '' || line.startsWith('#') || line.startsWith('--cmd')) continue;
			if (!line.startsWith('-') && line.endsWith('.hxml'))
				for (flag in flags(line)) out.push(flag)
			else
				out.push(line);
		}
		out.sort(Reflect.compare);
		return out;
	}

}
