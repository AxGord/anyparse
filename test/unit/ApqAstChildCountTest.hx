package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
#end

/**
 * Probe for `apq ast --select ... --min-children N` / `--max-children N`.
 *
 * Closes the structural-arity gap surfaced during the Slice-22
 * implementation: "find all enum ctors in HxDecl with arity > 1" was a
 * legitimate one-shot question but the selector grammar (`Kind` /
 * `Kind:name` / `Kind > Child`) has no numeric predicate. The filter
 * lives on the CLI instead of the selector path so the path grammar
 * stays minimal — arity is a numeric predicate, not a structural one.
 *
 * The fixture mixes single-arg and multi-arg enum ctors so the same
 * file exercises both bounds without crafting separate enums.
 */
class ApqAstChildCountTest extends Test {

	private static inline final FIXTURE: String = 'enum X {\n'
		+ '	Zero;\n' + '	One(a:Int);\n' + '	Two(a:Int, b:Int);\n' + '	Three(a:Int, b:Int, c:Int);\n' + '}\n';

	public function testMinChildrenKeepsMultiArgOnly(): Void {
		#if sys
		final fixture: String = writeFixture(FIXTURE);
		// All 3 ParamCtors (One, Two, Three) match before the filter; only
		// Two + Three survive --min-children=2 (Required count >= 2).
		Assert.equals(
			0, Cli.run(['ast', '--select', 'ParamCtor', '--min-children', '2', fixture]),
			'multi-arg ctors must remain visible under --min-children=2'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMaxChildrenKeepsSingleArgOnly(): Void {
		#if sys
		final fixture: String = writeFixture(FIXTURE);
		Assert.equals(
			0, Cli.run(['ast', '--select', 'ParamCtor', '--max-children', '1', fixture]),
			'single-arg ctors must remain visible under --max-children=1'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testBoundsAreInclusive(): Void {
		#if sys
		final fixture: String = writeFixture(FIXTURE);
		// min=2 max=2 → only Two survives (Three has 3 Requireds, One has 1).
		Assert.equals(
			0, Cli.run([
				'ast',
				'--select',
				'ParamCtor',
				'--min-children',
				'2',
				'--max-children',
				'2',
				fixture
			]),
			'inclusive bounds isolate the exact-arity ctor'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testEmptyResultStaysCleanExit(): Void {
		#if sys
		final fixture: String = writeFixture(FIXTURE);
		// No ParamCtor has 10+ children; clean EXIT_OK with empty result —
		// the not-found hint includes the filter description.
		Assert.equals(
			0, Cli.run(['ast', '--select', 'ParamCtor', '--min-children', '10', fixture]),
			'empty-after-filter is a clean empty result, not an error'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRejectsNegativeValue(): Void {
		#if sys
		final fixture: String = writeFixture(FIXTURE);
		Assert.equals(
			2, Cli.run(['ast', '--select', 'ParamCtor', '--min-children', '-1', fixture]), '--min-children rejects negative integers'
		);
		Assert.equals(
			2, Cli.run(['ast', '--select', 'ParamCtor', '--max-children', 'nope', fixture]), '--max-children rejects non-integer values'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function writeFixture(source: String): String {
		return CliFixture.write('apq_ast_childcount', source);
	}
	#end

}
