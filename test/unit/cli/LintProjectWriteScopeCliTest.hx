package unit.cli;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * The write proof of `prefer-final-public-field` / `prefer-read-only-field` over a lint scope
 * NARROWER than the project: the field is declared in the one file named on the command line and
 * assigned from a DIFFERENT module that the run never lints.
 *
 * That module is reachable — the project declares it under `apqlint.json` `resolutionRoots`, the
 * key whose whole purpose is that a narrow lint still answers over the whole project — but until
 * S95 neither rule looked there: both built their `FieldWriteIndex` from the report files alone.
 * The reproduction was `hxq lint src/anyparse/core --fix`, which turned three `public var` on
 * `LoweringCtx` into `public final` and left the project unable to compile, `src/anyparse/macro/Build.hx`
 * assigning all three. Under `--no-oracle` there is no revert net, so the broken tree stays on disk.
 *
 * The writer here is NOT a subtype — that arm was already covered (`ResolutionScopeCliTest`
 * pins it for both rules). It is an ordinary typed receiver in an unrelated class, the shape
 * `Build.hx` actually has.
 *
 * Each veto is paired with the same module only READING the field, so the difference is
 * attributable to the WRITE and not to the file's mere presence in the scope. Those read arms
 * pass at base too: they guard behaviour the fix must not lose.
 */
class LintProjectWriteScopeCliTest extends Test {

	#if (sys || nodejs)
	/** A public field with no write in its own file — `prefer-final-public-field`'s candidate. */
	private static final CTX: String = 'package proj;\n\nclass Ctx {\n\n\tpublic var mode: Int = 0;\n\n\tpublic function new() {}\n\n}\n';

	/** A public field written only inside its own class — `prefer-read-only-field`'s candidate. */
	private static final BOX: String = 'package proj;\n\nclass Box {\n\n\tpublic var slot: Int = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function bump(): Void {\n\t\tthis.slot = 1;\n\t}\n\n}\n';
	#end

	/**
	 * The reproduction, reduced: a project module outside the lint scope assigns the public field
	 * through a typed local. `var -> final` there is the edit the compiler rejects with "This
	 * expression cannot be accessed for writing", so the finding must not be reported at all.
	 */
	public function testProjectRootWriteBlocksPreferFinalPublicField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			0, lintWithRoots('prefer-final-public-field', 'Ctx.hx', CTX, [{ name: 'Build.hx', source: userOf('Ctx', 'c.mode = 1;') }]),
			'a write from another project module vetoes var -> final'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The discriminator: the same out-of-scope module only READING the field leaves the rewrite sound. */
	public function testProjectRootReadStillFlagsPreferFinalPublicField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			1, lintWithRoots('prefer-final-public-field', 'Ctx.hx', CTX, [{ name: 'Build.hx', source: userOf('Ctx', 'trace(c.mode);') }]),
			'a read from another project module must not veto'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `prefer-read-only-field`'s half: an external write from a project module outside the lint scope. */
	public function testProjectRootWriteBlocksPreferReadOnlyField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			0, lintWithRoots('prefer-read-only-field', 'Box.hx', BOX, [{ name: 'Use.hx', source: userOf('Box', 'c.slot = 2;') }]),
			'an external write from another project module vetoes (default, null)'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The discriminator for it: the same module reading the field leaves the internal-only proof standing. */
	public function testProjectRootReadStillFlagsPreferReadOnlyField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			1, lintWithRoots('prefer-read-only-field', 'Box.hx', BOX, [{ name: 'Use.hx', source: userOf('Box', 'trace(c.slot);') }]),
			'a read from another project module must not veto'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * A class in another package that constructs `type` into a typed local and runs `body` on it —
	 * an ordinary consumer, not a subtype, so only the write index can see what it does.
	 */
	private static function userOf(type: String, body: String): String {
		return 'package lib;\n\nimport proj.$type;\n\nclass User {\n\n\tpublic function new() {}\n\n\tpublic function go(): Void {'
			+ '\n\t\tfinal c: $type = new $type();\n\t\t$body\n\t}\n\n}\n';
	}

	/**
	 * Lint the ONE report file under a project whose `apqlint.json` declares `rootFiles`' directory
	 * as a `resolutionRoots` entry. `--fail-on info` turns the answer into the exit code: 1 when the
	 * rule reports, 0 when it does not.
	 */
	private static function lintWithRoots(
		rule: String, name: String, source: String, rootFiles: Array<{ name: String, source: String }>
	): Int {
		final root: String = CliFixture.writeDir('projwriteroot', rootFiles);
		final proj: String = CliFixture.writeDir('projwriteproj', [
			{ name: name, source: source },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$root"]}' }
		]);
		final exit: Int = Cli.run(['lint', '--rule', rule, '--fail-on', 'info', '$proj/$name']);
		CliFixture.removeDir(proj);
		CliFixture.removeDir(root);
		return exit;
	}
	#end

}
