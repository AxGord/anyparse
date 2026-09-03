package unit.query;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.query.Cli;
import anyparse.query.StdResolver;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * End-to-end proof of the IMPLICIT std resolution channel: the auto-discovered Haxe std joins
 * the resolution index UNCONDITIONALLY, so a plain `import haxe.Exception;` that is never
 * referenced becomes a VERIFIED-deletable `unused-import` `Warning` — removed by `--fix` —
 * exactly as it was under the old hardcoded std `resolutionRoots`. Covered from both sides: a
 * project that activates the scope through `resolutionLibs` (no `resolutionRoots`), and one that
 * declares no resolution key at all — the answer must be the same, since whether a std type
 * resolves cannot depend on the project happening to declare an unrelated library.
 *
 * A NEGATIVE control arm imports a package that resolves NOWHERE and must stay an untouched
 * `Info`, so the two deletions above are attributable to std actually resolving rather than to
 * `unused-import` removing whatever it cannot resolve. An OPT-OUT arm (`"resolutionStd": false`)
 * declines the std and gets the pre-scope answer back — the only thing keeping `Cli`'s no-scope
 * branches reachable on a Haxe-equipped box. The `staticMethodReturns` table FALLBACK is
 * exercised under that same opt-out. Two further arms pin the BLAST RADIUS of the implicit
 * scope: it must widen type resolution without joining `unused-private`'s occurrence proof.
 *
 * Every case skips gracefully when no Haxe std is installed on the machine.
 */
class ImplicitStdScopeTest extends Test {

	#if (sys || nodejs)
	private static final CRASH: String = 'package proj;\n\nimport haxe.Exception;\n\nclass Crash {\n\n\tpublic function new() {}\n\n}\n';

	/** The same shape as `CRASH` but importing a package that resolves NOWHERE — std included. The negative control's fixture. */
	private static final GHOST: String = 'package proj;\n\nimport acme.Widget;\n\nclass Ghost {\n\n\tpublic function new() {}\n\n}\n';

	/**
	 * A `#if`-carrying class with one unused private method whose name — `writeByte` — is all
	 * over the Haxe std. The `#if` is what routes `unused-private`'s fix through its textual
	 * zero-occurrence proof, and the name is what makes the std's presence in that proof decide
	 * the outcome.
	 *
	 * Written in DEFAULT writer style (`():Void`, no space) on purpose: the fixture lands in the
	 * system temp dir, where no `hxformat.json` is discoverable, so anything in this project's
	 * style fails the `--fix` canonical gate — the file is skipped and both arms below pass
	 * vacuously. That is exactly what happened on the first draft.
	 */
	private static final COND: String = 'package proj;\n\nclass Cond {\n\n\tpublic function new() {}\n\n\tpublic function run():Void {\n'
		+ '\t\t#if debug\n\t\ttrace(1);\n\t\t#end\n\t}\n\n\tprivate function writeByte():Void {}\n\n}\n';
	#end

	/**
	 * The implicit std scope must NOT join `unused-private`'s occurrence proof. That proof is a
	 * TEXTUAL scan for the member's name, used to lift a `#if`-carrying file's whole-file veto —
	 * and a private member of this project can never legitimately be referenced from std. Let the
	 * implicit scope in and a member named `writeByte` is vetoed by the hundreds of occurrences in
	 * `haxe.io`, so `unused-private --fix` silently stops deleting it.
	 *
	 * Measured, not theorised: pointing `widestScopeIndex` at `hasAnyResolutionScope` instead of
	 * `hasDeclaredResolutionScope` turns the deletion below into `fixed 0 issue(s)`.
	 */
	public function testImplicitStdScopeDoesNotVetoUnusedPrivateDeletion(): Void {
		#if (sys || nodejs)
		final proj: String = CliFixture.writeDir('implstdunusedpriv', [{ name: 'Cond.hx', source: COND }]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'unused-private', '$proj/Cond.hx']), 'the fix run succeeds');
		Assert.isTrue(
			File.getContent('$proj/Cond.hx').indexOf('writeByte') == -1,
			'a dead private member is deleted even though its name is common in std — std is not in the occurrence proof'
		);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The discriminator for the test above: a DECLARED resolution root still participates in the
	 * proof, so the same member is kept when a file the project chose to put in scope names it.
	 * Proves the gate narrowed to "declared" rather than being switched off.
	 */
	public function testDeclaredResolutionScopeStillVetoesUnusedPrivateDeletion(): Void {
		#if (sys || nodejs)
		final lib: String = CliFixture.writeDir('implstdprivlib', [
			{
				name: 'Caller.hx',
				source: 'package other;\nclass Caller {\n\tpublic function new() {}\n\tpublic function go(): Void { writeByte(); }\n}'
			}
		]);
		final proj: String = CliFixture.writeDir('implstdprivproj', [
			{ name: 'Cond.hx', source: COND },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$lib"]}' }
		]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'unused-private', '$proj/Cond.hx']), 'the fix run succeeds');
		Assert.isTrue(
			File.getContent('$proj/Cond.hx').indexOf('writeByte') != -1,
			'a declared resolution root naming the member keeps the conservative veto'
		);
		CliFixture.removeDir(proj);
		CliFixture.removeDir(lib);
		#else
		Assert.pass('non-sys target');
		#end
	}

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
	 * The same file with NO apqlint.json at all: std joins the resolution scope even when the
	 * project declares neither `resolutionRoots` nor `resolutionLibs`, so `haxe.Exception` is
	 * resolvable and the unused import is a verified `Warning` that `--fix` deletes. Whether a std
	 * type resolves must not depend on the project happening to declare an unrelated library —
	 * this asserted the opposite before `resolutionThunk` admitted a std-only scope.
	 */
	public function testStdImportVerifiedWithoutAnyConfig(): Void {
		#if (sys || nodejs)
		if (StdResolver.stdDir() == null) {
			Assert.pass('no installed Haxe std — implicit-scope verification skipped');
			return;
		}
		final proj: String = CliFixture.writeDir('implstdctl', [{ name: 'Crash.hx', source: CRASH }]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'unused-import', '$proj/Crash.hx']), 'the fix run succeeds');
		final after: String = File.getContent('$proj/Crash.hx');
		Assert.isTrue(
			after.indexOf('import haxe.Exception;') == -1,
			'std joins the scope with no resolution key declared — the unused std import is verified and deleted'
		);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The NEGATIVE control for both arms above. Same config-less project, same shape, but the
	 * import names a package that resolves NOWHERE — not in the report, not in std. It must stay
	 * an unverifiable `Info` that `--fix` leaves alone.
	 *
	 * Without this, nothing separates "std resolved, so the import is provably unused" from
	 * "unused-import deletes any import it cannot resolve": both arms above assert the same
	 * outcome (deleted), so both would pass under either mechanism. This is the arm whose
	 * outcome DIFFERS, and it is what makes the deletions attributable to std.
	 */
	public function testConfigLessUnresolvableImportStaysInfoAndSurvivesFix(): Void {
		#if (sys || nodejs)
		final proj: String = CliFixture.writeDir('implstdghost', [{ name: 'Ghost.hx', source: GHOST }]);
		Assert.equals(
			1, Cli.run(['lint', '--rule', 'unused-import', '--fail-on', 'info', '$proj/Ghost.hx']),
			'an import nothing in scope declares is reported, as an Info'
		);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'unused-import', '$proj/Ghost.hx']), 'the fix run succeeds');
		Assert.isTrue(
			File.getContent('$proj/Ghost.hx').indexOf('import acme.Widget;') != -1,
			'an unverifiable import is never deleted — so the std arms above are attributable to std actually resolving'
		);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The OPT-OUT, and the only thing that keeps `Cli.resolutionThunk`'s `return null` branch and
	 * `wrapResolution`'s passthrough reachable on a Haxe-equipped machine: `StdResolver` falls
	 * through to `KNOWN_LOCATIONS`, so clearing `HAXE_STD_PATH` and stripping `haxe` from `PATH`
	 * still yields a std. With `"resolutionStd": false` the project declines it, and the very
	 * same file whose std import the config-less arm deletes keeps it — the scope is gone, not
	 * merely narrower.
	 */
	public function testResolutionStdFalseDeclinesTheImplicitStdScope(): Void {
		#if (sys || nodejs)
		final proj: String = CliFixture.writeDir('implstdoptout', [
			{ name: 'Crash.hx', source: CRASH },
			{ name: 'apqlint.json', source: '{"resolutionStd":false}' }
		]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'unused-import', '$proj/Crash.hx']), 'the fix run succeeds');
		Assert.isTrue(
			File.getContent('$proj/Crash.hx').indexOf('import haxe.Exception;') != -1,
			'with the std declined the import is unverifiable again — no scope reached the run at all'
		);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The `staticMethodReturns` table remains a live FALLBACK for a run with NO resolution scope:
	 * `Date.now()` infers `:Date` structurally from the table, so `explicit-local-type --fix`
	 * annotates the local. Guards the regression where indexing std would silently disable the
	 * table without a replacement.
	 *
	 * Runs under `"resolutionStd": false` on purpose. Its own earlier doc conceded it only
	 * exercised the table on a machine with no std — which, since `StdResolver` falls through to
	 * `KNOWN_LOCATIONS`, is a machine that barely exists; the test could no longer fail. Declining
	 * the std is what makes the table the only channel again, so a regression here is detectable.
	 */
	public function testStaticMethodReturnsTableFallback(): Void {
		#if (sys || nodejs)
		final src: String =
			'package proj;\n\nclass DateUse {\n\n\tpublic function new() {\n\t\tfinal d = Date.now();\n\t\ttrace(d);\n\t}\n\n}\n';
		final proj: String = CliFixture.writeDir('statret', [
			{ name: 'DateUse.hx', source: src },
			{ name: 'apqlint.json', source: '{"resolutionStd":false}' }
		]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'explicit-local-type', '$proj/DateUse.hx']), 'the fix run succeeds');
		final after: String = File.getContent('$proj/DateUse.hx');
		Assert.isTrue(
			after.indexOf('final d:Date = Date.now();') != -1,
			'Date.now() infers :Date from the staticMethodReturns table fallback (std declined), got: $after'
		);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
