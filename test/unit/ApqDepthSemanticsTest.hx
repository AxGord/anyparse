package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

/**
 * `apq ast --depth <n>` is counted from the displayed root, not from
 * the module:
 *  - No `--select` / `--at` → root is the full module.
 *  - With `--select <kind>` → root is each matched node.
 *  - With `--at <line>:<col>` → root is the innermost enclosing node.
 *
 * In every mode, `--depth 0` prints just the root with no children;
 * `--depth N` shows N levels of children below the root.
 *
 * Tests exercise both modes via `Cli.run` against inline `--code`
 * sources and assert clean exit. Stdout-capture infrastructure is not
 * wired up, so the text content is verified manually and locked in by
 * the help-text + code comment near the `--depth` handler. These tests
 * guard against signature/argv-handling regressions only.
 */
@:nullSafety(Strict)
class ApqDepthSemanticsTest extends Test {

	public function testDepthZeroOnModule(): Void {
		// No --select → depth counts from module. `--depth 0` exits 0.
		Assert.equals(
			0, Cli.run(['ast', '--code', 'class C { var x:Int = 0; }', '--depth', '0']), '--depth 0 without --select is a clean exit'
		);
	}

	public function testDepthOnePlusOnModule(): Void {
		Assert.equals(
			0, Cli.run(['ast', '--code', 'class C { var x:Int = 0; }', '--depth', '1']),
			'--depth 1 (module + one child level) is a clean exit'
		);
		Assert.equals(0, Cli.run(['ast', '--code', 'class C { var x:Int = 0; }', '--depth', '5']), '--depth 5 (full tree) is a clean exit');
	}

	public function testDepthZeroWithSelect(): Void {
		// With --select VarMember → root is the selected VarMember.
		// --depth 0 shows just `(VarMember x)`, no IntLit child.
		Assert.equals(
			0,
			Cli.run([
				'ast',
				'--code',
				'class C { var x:Int = 0; }',
				'--select',
				'VarMember',
				'--depth',
				'0'
			]),
			'--depth 0 with --select shows just the matched node, exits 0'
		);
	}

	public function testDepthOneWithSelect(): Void {
		// With --select VarMember and --depth 1, we get the IntLit child.
		Assert.equals(
			0,
			Cli.run([
				'ast',
				'--code',
				'class C { var x:Int = 0; }',
				'--select',
				'VarMember',
				'--depth',
				'1'
			]),
			'--depth 1 with --select shows one level of children, exits 0'
		);
	}

	public function testDepthZeroWithAt(): Void {
		// With --at LINE:COL → root is the innermost enclosing node.
		// --depth 0 shows just that node.
		Assert.equals(
			0, Cli.run(['ast', '--code', 'class C { var x:Int = 0; }', '--at', '1:15', '--depth', '0']),
			'--depth 0 with --at shows just the enclosing node, exits 0'
		);
	}

	public function testDepthNegativeIsFullTree(): Void {
		// The truncate engine treats depth < 0 as "no truncation".
		// Exercise that path too.
		Assert.equals(
			0, Cli.run(['ast', '--code', 'class C { var x:Int = 0; }', '--depth', '-1']), 'negative --depth is a clean exit (full tree)'
		);
	}

	public function testDepthNonIntegerIsUsageError(): Void {
		Assert.equals(2, Cli.run(['ast', '--code', 'class C {}', '--depth', 'nope']), 'non-integer --depth is a usage error');
	}

}
