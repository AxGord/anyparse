package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
import anyparse.query.HaxelibResolver;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * End-to-end proof of the `apqlint.json` `resolutionRoots` key: the resolution
 * scope (report files UNION declared library roots) reaches a base class that
 * lives ONLY in a library dir, so a `redundant-this` finding fires on the derived
 * file that would be a conservative miss without the scope — while the library
 * file itself is never reported and never edited (it is not named on the command
 * line, and `--fix` leaves it byte-identical).
 *
 * The base's `foo` is an inherited member; `this.foo()` in the derived class is
 * flagged only once `lib.Base` is resolvable through `resolutionRoots`. A
 * config-less control run over the same sources produces no finding, so the
 * difference is attributable to the key.
 */
class ResolutionScopeCliTest extends Test {

	#if (sys || nodejs)
	private static final BASE: String = 'package lib;\nclass Base {\n\tpublic function new() {}\n\tpublic function foo(): Void {}\n}';
	private static final DERIVED: String = 'package proj;\n\nimport lib.Base;\n\nclass Derived extends Base {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n\tpublic function bar():Void {\n\t\tthis.foo();\n\t}\n\n}\n';
	#end

	public function testInheritedMemberResolvedThroughResolutionRoots(): Void {
		#if (sys || nodejs)
		final lib: String = CliFixture.writeDir('reslib', [{ name: 'Base.hx', source: BASE }]);

		// With the library on resolutionRoots the inherited `foo` resolves — this.foo() is flagged (Info trips --fail-on info).
		final withScope: String = CliFixture.writeDir('resproj', [
			{ name: 'Derived.hx', source: DERIVED },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$lib"]}' }
		]);
		Assert.equals(
			1, Cli.run(['lint', '--rule', 'redundant-this', '--fail-on', 'info', '$withScope/Derived.hx']),
			'the inherited this.foo() is flagged once lib.Base is in the resolution scope'
		);
		CliFixture.removeDir(withScope);

		// Without the key the base is out of scope, so the membership gate cannot prove `foo` — no finding.
		final noScope: String = CliFixture.writeDir('resproj', [{ name: 'Derived.hx', source: DERIVED }]);
		Assert.equals(
			0, Cli.run(['lint', '--rule', 'redundant-this', '--fail-on', 'info', '$noScope/Derived.hx']),
			'without resolutionRoots the out-of-scope base leaves this.foo() a conservative miss'
		);
		CliFixture.removeDir(noScope);
		CliFixture.removeDir(lib);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFixEditsReportFileNeverTheLibrary(): Void {
		#if (sys || nodejs)
		final lib: String = CliFixture.writeDir('reslib', [{ name: 'Base.hx', source: BASE }]);
		final proj: String = CliFixture.writeDir('resproj', [
			{ name: 'Derived.hx', source: DERIVED },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$lib"]}' }
		]);

		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'redundant-this', '$proj/Derived.hx']), 'the fix run succeeds');

		final derivedAfter: String = File.getContent('$proj/Derived.hx');
		Assert.isTrue(derivedAfter.indexOf('this.foo()') == -1, 'the redundant this. was dropped in the report file');
		Assert.isTrue(derivedAfter.indexOf('foo();') != -1, 'the bare call remains');
		Assert.equals(BASE, File.getContent('$lib/Base.hx'), 'the library file in the resolution scope is byte-identical — never edited');

		CliFixture.removeDir(proj);
		CliFixture.removeDir(lib);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The report scope given RELATIVE while a `resolutionRoots` entry resolves to the SAME
	 * (absolute) directory: the shared base must land in the SymbolIndex ONCE, not once per
	 * spelling. A raw-string dedup keeps the relative report copy AND the absolute library copy —
	 * duplicate declarations that trip the resolver's ambiguity gate and silently suppress the
	 * inherited-member finding. Runs from the fixture's PARENT with a relative dir arg so the
	 * report paths keep that spelling; the fixture dir is canonicalised through `getCwd` first so
	 * a symlinked temp dir (macOS `/var` → `/private/var`) still normalises to one string.
	 */
	public function testRelativeReportOverlappingAbsoluteRootStillResolves(): Void {
		#if (sys || nodejs)
		final raw: String = CliFixture.writeDir('resrel', [
			{ name: 'Base.hx', source: BASE },
			{ name: 'Derived.hx', source: DERIVED }
		]);
		final oldCwd: String = Sys.getCwd();
		Sys.setCwd(raw);
		final dir: String = stripTrailingSlash(Sys.getCwd());
		final name: String = haxe.io.Path.withoutDirectory(dir);
		File.saveContent('$dir/apqlint.json', '{"resolutionRoots":["$dir"]}');
		Sys.setCwd(haxe.io.Path.directory(dir));
		final exit: Int = try Cli.run(['lint', '--rule', 'redundant-this', '--fail-on', 'info', name]) catch (exception: haxe.Exception) {
			Sys.setCwd(oldCwd);
			throw exception;
		}
		Sys.setCwd(oldCwd);
		Assert.equals(
			1, exit,
			'a relative report scope overlapping an absolute resolutionRoots entry still resolves the inherited member — the shared base is deduped, not double-indexed'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static inline function stripTrailingSlash(p: String): String {
		return StringTools.endsWith(p, '/') ? p.substring(0, p.length - 1) : p;
	}
	#end


	/**
	 * A `resolutionLibs` entry that does not resolve (a typo / uninstalled lib) must not crash the
	 * run: the lazy thunk fires (redundant-this demands the resolution index), attempts the haxelib
	 * lookup, gets nothing, and the lint proceeds as if the lib were absent — the out-of-scope base
	 * stays a conservative miss (exit 0), never an error. Asserts the resolver WAS invoked so the
	 * graceful path is genuinely exercised, not silently skipped.
	 */
	public function testResolutionLibsMissingLibIsGraceful(): Void {
		#if (sys || nodejs)
		final proj: String = CliFixture.writeDir('reslibmiss', [
			{ name: 'Derived.hx', source: DERIVED },
			{ name: 'apqlint.json', source: '{"resolutionLibs":["__apq_not_a_real_lib__"]}' }
		]);
		final before: Int = HaxelibResolver.invocations;
		final exit: Int = Cli.run(['lint', '--rule', 'redundant-this', '--fail-on', 'info', '$proj/Derived.hx']);
		Assert.equals(0, exit, 'an unresolved resolutionLibs entry leaves the base out of scope — a conservative miss, not a crash');
		Assert.isTrue(HaxelibResolver.invocations > before, 'the lazy thunk fired and attempted to resolve the lib name');
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * LAZINESS: a `prefer-single-quotes` run over a project WITH `resolutionLibs` set never demands
	 * the resolution index, so the thunk never fires and `haxelib libpath` is never spawned — the
	 * invocation counter is untouched. The haxelib cost is paid ONLY by a check that builds the index.
	 */
	public function testPreferSingleQuotesNeverSpawnsHaxelib(): Void {
		#if (sys || nodejs)
		final stringy: String = 'package q;\n\nclass Q {\n\n\tpublic function new() {}\n\n\tpublic function s(): String {\n\t\treturn "plain";\n\t}\n\n}\n';
		final proj: String = CliFixture.writeDir('reslibquotes', [
			{ name: 'Q.hx', source: stringy },
			{ name: 'apqlint.json', source: '{"resolutionLibs":["openfl"]}' }
		]);
		final before: Int = HaxelibResolver.invocations;
		Cli.run(['lint', '--rule', 'prefer-single-quotes', '$proj/Q.hx']);
		Assert.equals(before, HaxelibResolver.invocations, 'prefer-single-quotes builds no index, so haxelib is never spawned');
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
