package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
import anyparse.query.StdResolver;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * End-to-end proof of the IMPLICIT std resolution channel: when a resolution scope
 * is active (here via `resolutionLibs`, NO `resolutionRoots`), the auto-discovered
 * Haxe std joins the resolution index, so a plain `import haxe.Exception;` that is
 * never referenced becomes a VERIFIED-deletable `unused-import` `Warning` — removed
 * by `--fix` — exactly as it was under the old hardcoded std `resolutionRoots`. A
 * config-less control leaves the same import an unverifiable `Info` (byte-inert: no
 * scope → no std → pre-existing behaviour). Also covers the `staticMethodReturns`
 * table FALLBACK: with no scope, `Date.now()` still infers `:Date` from the table.
 *
 * Every case skips gracefully when no Haxe std is installed on the machine.
 */
class ImplicitStdScopeTest extends Test {

	#if (sys || nodejs)
	private static final CRASH: String = 'package proj;\n\nimport haxe.Exception;\n\nclass Crash {\n\n\tpublic function new() {}\n\n}\n';
	#end

	/**
	 * With a resolution scope active via `resolutionLibs` and NO `resolutionRoots`, the
	 * implicit std makes an unused `import haxe.Exception;` a verified `Warning` — `--fix`
	 * deletes it. The `resolutionLibs` entry only ACTIVATES the scope; it need not resolve
	 * (an unresolved name is skipped gracefully), so the removal is attributable to std.
	 */
	public function testStdImportVerifiedWithoutRoots(): Void {
		#if (sys || nodejs)
		if (StdResolver.stdDir() == null) {
			Assert.pass('no installed Haxe std — implicit-scope verification skipped');
			return;
		}
		final proj: String = CliFixture.writeDir('implstd', [
			{ name: 'Crash.hx', source: CRASH },
			{ name: 'apqlint.json', source: '{"resolutionLibs":["__apq_scope_activator__"]}' }
		]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'unused-import', '$proj/Crash.hx']), 'the fix run succeeds');
		final after: String = File.getContent('$proj/Crash.hx');
		Assert.isTrue(
			after.indexOf('import haxe.Exception;') == -1, 'the unused std import was verified and deleted via the implicit std scope'
		);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The byte-inert control: with NO apqlint.json the resolution scope is inactive, so
	 * std does NOT join — `haxe.Exception` is out of scope and the unused import stays an
	 * unverifiable `Info`, which `--fix` never deletes. This isolates the difference to
	 * the active-scope implicit std, not to unused-import itself.
	 */
	public function testStdImportUnverifiedWithoutScope(): Void {
		#if (sys || nodejs)
		final proj: String = CliFixture.writeDir('implstdctl', [{ name: 'Crash.hx', source: CRASH }]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'unused-import', '$proj/Crash.hx']), 'the fix run succeeds');
		final after: String = File.getContent('$proj/Crash.hx');
		Assert.isTrue(
			after.indexOf('import haxe.Exception;') != -1,
			'without a resolution scope std is not joined — the import stays an unverified Info, not deleted'
		);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The `staticMethodReturns` table remains a live FALLBACK when std is NOT in the
	 * resolution index (config-less run): `Date.now()` infers `:Date` structurally from
	 * the table, so `explicit-local-type --fix` annotates the local. Guards the
	 * regression where indexing std would silently disable the table without a
	 * replacement.
	 */
	public function testStaticMethodReturnsTableFallback(): Void {
		#if (sys || nodejs)
		final src: String = 'package proj;\n\nclass DateUse {\n\n\tpublic function new() {\n\t\tfinal d = Date.now();\n\t\ttrace(d);\n\t}\n\n}\n';
		final proj: String = CliFixture.writeDir('statret', [{ name: 'DateUse.hx', source: src }]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'explicit-local-type', '$proj/DateUse.hx']), 'the fix run succeeds');
		final after: String = File.getContent('$proj/DateUse.hx');
		Assert.isTrue(
			after.indexOf('final d:Date = Date.now();') != -1,
			'Date.now() infers :Date from the staticMethodReturns table fallback (no scope), got: $after'
		);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
