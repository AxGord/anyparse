package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
import anyparse.query.HaxelibResolver;
import anyparse.query.StdResolver;

using StringTools;

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
	private static final DERIVED: String = 'package proj;\n\nimport lib.Base;\n\nclass Derived extends Base {\n\n\tpublic function new() {'
		+ '\n\t\tsuper();\n\t}\n\n\tpublic function bar():Void {\n\t\tthis.foo();\n\t}\n\n}\n';

	/** A public field with no write anywhere — `prefer-final-public-field`'s candidate. */
	private static final OWNER: String =
		'package proj;\n\nclass Owner {\n\n\tpublic var tag: Int = 0;\n\n\tpublic function new() {}\n\n}\n';

	/** A public field written only inside its own class — `prefer-read-only-field`'s candidate. */
	private static final BOX: String = 'package proj;\n\nclass Box {\n\n\tpublic var slot: Int = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function bump(): Void {\n\t\tthis.slot = 1;\n\t}\n\n}\n';

	/** A library class unrelated to the report types — a resolution scope that vetoes nothing. */
	private static final UNRELATED: String = 'package lib;\n\nclass Unrelated {\n\n\tpublic function new() {}\n\n}\n';

	/**
	 * A library file the grammar cannot read. Routine in a real library, and the reason the
	 * `skippedFiles` bail must keep asking the REPORT index: asked of the resolution index it
	 * would be permanently non-empty and every finding below would vanish.
	 */
	private static final BROKEN: String = 'package lib;\n\nclass Broken {\n\t@@@ not haxe at all %%%\n}\n';

	/** A PRIVATE field assigned only at its declaration — `prefer-final-field`'s candidate. */
	private static final VAULT: String = 'package proj;\n\nclass Vault {\n\n\tprivate var _key: Int = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function read(): Int {\n\t\treturn _key;\n\t}\n\n}\n';
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
			'a relative report scope overlapping an absolute resolutionRoots entry still resolves the inherited member — the shared base '
			+ 'is deduped, not double-indexed'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

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
		final stringy: String =
			'package q;\n\nclass Q {\n\n\tpublic function new() {}\n\n\tpublic function s(): String {\n\t\treturn "plain";\n\t}\n\n}\n';
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

	/**
	 * The reproduction: a subtype that WRITES the public field lives only in a `resolutionRoots`
	 * library, so the report-scoped index cannot see it. The subtype gate must ask the resolution
	 * index, else `var -> final` is emitted against a subtype write the compiler rejects.
	 */
	public function testResolutionScopeSubtypeWriteBlocksPreferFinalPublicField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			0,
			lintWithLib('prefer-final-public-field', 'Owner.hx', OWNER, [{ name: 'Sub.hx', source: subtypeOf('Owner', 'this.tag = 1;') }]),
			'a resolution-scope subtype writing the field vetoes var -> final'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The discriminator for the test above: the same resolution-scope subtype that only READS the
	 * field leaves the rewrite sound, so the finding must still fire. Proves the gate asks "does it
	 * WRITE", not the blanket "does a subtype exist".
	 */
	public function testResolutionScopeSubtypeReadStillFlagsPreferFinalPublicField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			1,
			lintWithLib(
				'prefer-final-public-field', 'Owner.hx', OWNER,
				[{ name: 'Sub.hx', source: subtypeOf('Owner', 'trace(this.tag);') }]
			),
			'a resolution-scope subtype that only reads the field still allows var -> final'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Regression guard for the `skippedFiles` bail: a configured resolution scope carrying a
	 * skip-parsed library file (and no subtype at all) must still produce the normal finding. Point
	 * that bail at the resolution index and the rule goes permanently silent on every project with
	 * libraries.
	 */
	public function testResolutionScopeConfiguredStillFlagsPreferFinalPublicField(): Void {
		#if (sys || nodejs)
		Assert.equals(1, lintWithLib('prefer-final-public-field', 'Owner.hx', OWNER, [
			{ name: 'Unrelated.hx', source: UNRELATED },
			{ name: 'Broken.hx', source: BROKEN }
		]), 'a resolution scope with no offending subtype — skip-parsed library file included — still yields the finding');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `prefer-read-only-field`'s half of the reproduction: a resolution-scope subtype writing the field vetoes `(default, null)`. */
	public function testResolutionScopeSubtypeWriteBlocksPreferReadOnlyField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			0, lintWithLib('prefer-read-only-field', 'Box.hx', BOX, [{ name: 'Sub.hx', source: subtypeOf('Box', 'this.slot = 2;') }]),
			'a resolution-scope subtype writing the field vetoes (default, null)'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The discriminator: a resolution-scope subtype that only READS the field still leaves it internally-written-only. */
	public function testResolutionScopeSubtypeReadStillFlagsPreferReadOnlyField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			1, lintWithLib('prefer-read-only-field', 'Box.hx', BOX, [{ name: 'Sub.hx', source: subtypeOf('Box', 'trace(this.slot);') }]),
			'a resolution-scope subtype that only reads the field still allows (default, null)'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Regression guard: a resolution scope with a skip-parsed library file and no subtype still yields the normal finding. */
	public function testResolutionScopeConfiguredStillFlagsPreferReadOnlyField(): Void {
		#if (sys || nodejs)
		Assert.equals(1, lintWithLib('prefer-read-only-field', 'Box.hx', BOX, [
			{ name: 'Unrelated.hx', source: UNRELATED },
			{ name: 'Broken.hx', source: BROKEN }
		]), 'a resolution scope with no offending subtype — skip-parsed library file included — still yields the finding');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The reproduction: with `apqlint.json` declaring NEITHER `resolutionRoots` nor
	 * `resolutionLibs`, a field typed by a std class must still resolve. `haxe.io.BytesOutput` is
	 * not an abstract, so a method call on the binding rebinds no `this` and `prefer-final-field`
	 * fires. Before std joined the scope unconditionally the answer depended on the project
	 * happening to declare an unrelated library — which is the defect this pins.
	 */
	public function testConfigLessProjectResolvesStdTypedField(): Void {
		#if (sys || nodejs)
		if (StdResolver.stdDir() == null) {
			Assert.pass('no installed Haxe std — implicit-scope resolution skipped');
			return;
		}
		final source: String = 'package proj;\n\nclass Sink {\n\n\tprivate var _out: haxe.io.BytesOutput = new haxe.io.BytesOutput();\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function f(): Void {\n\t\t_out.writeByte(1);\n\t}\n\n}\n';
		Assert.equals(
			1, lintConfigLess('prefer-final-field', 'Sink.hx', source),
			'a std-typed field is final-able with no resolution key declared — std joins the scope on its own'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The control for the test above: a field type resolvable NOWHERE — std included — stays a
	 * conservative miss in the very same config-less project. So the std-typed finding is
	 * attributable to std actually resolving, not to the mutation gate having been loosened for
	 * every unknown type.
	 */
	public function testConfigLessProjectStaysConservativeOnUnresolvableType(): Void {
		#if (sys || nodejs)
		final source: String = 'package proj;\n\nclass Holder {\n\n\tprivate var _thing: acme.Widget = new acme.Widget();\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function f(): Void {\n\t\t_thing.poke();\n\t}\n\n}\n';
		Assert.equals(
			0, lintConfigLess('prefer-final-field', 'Holder.hx', source), 'a type nothing in the scope declares still blocks var -> final'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The NARROWED inertness guarantee for a project declaring neither resolution key: the
	 * null-decision now probes for a std, so "spawns nothing" no longer holds — but "spawns no
	 * haxelib, and one `which haxe` at most for the whole process" must. `StdResolver.stdDir`
	 * memoises, so two config-less runs of a check that builds no index move neither counter by
	 * more than that.
	 */
	public function testConfigLessRunSpawnsNoHaxelibAndProbesStdAtMostOnce(): Void {
		#if (sys || nodejs)
		final source: String =
			'package q;\n\nclass Z {\n\n\tpublic function new() {}\n\n\tpublic function s(): String {\n\t\treturn "plain";\n\t}\n\n}\n';
		final proj: String = CliFixture.writeDir('resstdquotes', [
			{ name: 'Z.hx', source: source },
			{ name: 'apqlint.json', source: '{"rules":{}}' }
		]);
		final haxelibBefore: Int = HaxelibResolver.invocations;
		final stdBefore: Int = StdResolver.discoveries;
		// Both exit codes asserted: an ERRORED run spawns nothing either, so without this the
		// counter assertions below would be satisfied by a run that never got off the ground —
		// fatal for a test whose whole claim is "the run PROCEEDS without spawning".
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-single-quotes', '$proj/Z.hx']), 'the first run succeeds');
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-single-quotes', '$proj/Z.hx']), 'the second run succeeds');
		Assert.equals(haxelibBefore, HaxelibResolver.invocations, 'a config-less run never spawns haxelib');
		Assert.isTrue(
			StdResolver.discoveries - stdBefore <= 1, 'the std probe is memoised — one `which haxe` at most for the whole process'
		);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `prefer-final-field` is the largest of the three conversions and has TWO call sites
	 * (the decl-initialised path and the no-initializer constructor path); it is also the
	 * only rule whose `@:access` gate was widened. A resolution-scope subtype writing the
	 * inherited private field must veto it.
	 */
	public function testResolutionScopeSubtypeWriteBlocksPreferFinalField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			0, lintWithLib('prefer-final-field', 'Vault.hx', VAULT, [{ name: 'Sub.hx', source: subtypeOf('Vault', 'this._key = 1;') }]),
			'a resolution-scope subtype writing the private field vetoes var -> final'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same subtype only READING it leaves the finalization alone — a read survives `final`. */
	public function testResolutionScopeSubtypeReadStillFlagsPreferFinalField(): Void {
		#if (sys || nodejs)
		Assert.equals(
			1, lintWithLib('prefer-final-field', 'Vault.hx', VAULT, [{ name: 'Sub.hx', source: subtypeOf('Vault', 'trace(this._key);') }]),
			'a read-only resolution-scope subtype must not veto'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `@:access(<subtype>)` in a library file reaches a PRIVATE field declared in the
	 * subtype's SUPERtype — compiler-verified — and a grant scan keyed on the owner never
	 * sees it, so the subtype gate has to carry it across the resolution scope too.
	 */
	public function testResolutionScopeAccessGrantOnSubtypeBlocksPreferFinalField(): Void {
		#if (sys || nodejs)
		Assert.equals(0, lintWithLib('prefer-final-field', 'Vault.hx', VAULT, [
			{ name: 'Sub.hx', source: subtypeOf('Vault', 'trace(this);') },
			{ name: 'Poker.hx', source: grantOnSubtype('s._key = 9;') }
		]), 'an @:access(Sub) grantee writing the inherited private field vetoes var -> final');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A resolution scope that vetoes nothing must still leave the finding — the `skippedFiles` guard. */
	public function testResolutionScopeConfiguredStillFlagsPreferFinalField(): Void {
		#if (sys || nodejs)
		Assert.equals(1, lintWithLib('prefer-final-field', 'Vault.hx', VAULT, [
			{ name: 'Unrelated.hx', source: UNRELATED },
			{ name: 'Broken.hx', source: BROKEN }
		]), 'a library skip-parse must not silence the rule');
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static inline function stripTrailingSlash(p: String): String {
		return p.endsWith('/') ? p.substring(0, p.length - 1) : p;
	}

	/** A library file granting itself `@:access(Sub)` and writing the inherited PRIVATE field through it. */
	private static function grantOnSubtype(body: String): String {
		return 'package lib;\n\n@:access(Sub)\nclass Poker {\n\n\tpublic function new() {}\n\n\tpublic function poke(s: Sub): Void {\n\t\t'
			+ '$body\n\t}\n\n}\n';
	}

	/** A library subtype of `base` whose `touch()` body is `body` — the resolution-scope side of each gate test. */
	private static function subtypeOf(base: String, body: String): String {
		return 'package lib;\n\nimport proj.$base;\n\nclass Sub extends $base {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n'
			+ '\tpublic function touch(): Void {\n\t\t$body\n\t}\n\n}\n';
	}

	/**
	 * Lint the single report file `name` (source `source`) under `rule`, with `libFiles` written
	 * into a separate directory declared on `resolutionRoots`. Returns the CLI exit code — 1 when
	 * an Info finding fires (`--fail-on info`), 0 when the rule stays silent.
	 */
	private static function lintWithLib(
		rule: String, name: String, source: String, libFiles: Array<{ name: String, source: String }>
	): Int {
		final lib: String = CliFixture.writeDir('resfieldlib', libFiles);
		final proj: String = CliFixture.writeDir('resfieldproj', [
			{ name: name, source: source },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$lib"]}' }
		]);
		final exit: Int = Cli.run(['lint', '--rule', rule, '--fail-on', 'info', '$proj/$name']);
		CliFixture.removeDir(proj);
		CliFixture.removeDir(lib);
		return exit;
	}

	/**
	 * Lint the single report file `name` (source `source`) under `rule` in a project whose
	 * `apqlint.json` declares NO resolution key at all. Returns the CLI exit code — 1 when an Info
	 * finding fires (`--fail-on info`), 0 when the rule stays silent. The config-less sibling of
	 * `lintWithLib`: whatever resolves here comes from the auto-discovered std alone.
	 */
	private static function lintConfigLess(rule: String, name: String, source: String): Int {
		final proj: String = CliFixture.writeDir('resnocfg', [
			{ name: name, source: source },
			{ name: 'apqlint.json', source: '{"rules":{}}' }
		]);
		final exit: Int = Cli.run(['lint', '--rule', rule, '--fail-on', 'info', '$proj/$name']);
		CliFixture.removeDir(proj);
		return exit;
	}
	#end

}
