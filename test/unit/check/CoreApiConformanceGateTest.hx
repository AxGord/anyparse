package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.InlineConstant;
import anyparse.check.PreferFinalField;
import anyparse.check.PreferFinalPublicField;
import anyparse.check.PreferInline;
import anyparse.check.PreferReadOnlyField;
import anyparse.check.StaticConstant;
import anyparse.check.TrivialGetter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.MakeFinal;
import utest.Assert;
import utest.Test;

/**
 * `@:coreApi` — the one member pin no scope here can ever hold. A `@:coreApi` class replaces a
 * standard-library core type, and the compiler checks it member-for-member against that core
 * type's declaration, which lives in its own std path: not in the report scope, not in the
 * resolution scope, not reachable by any index or text scan this project builds.
 *
 * Six of the seventeen Haxe std files carrying `@:buildXml` are such replacements (`EReg`,
 * `FileSystem`, `Sqlite`, `Mysql`, `Compress`, `Uncompress`), and the substring defect that read
 * `@:buildXml` as `@:build` used to shield them BY ACCIDENT. Removing that accident left them
 * with no gate at all, which is what this one restores.
 *
 * What the pin forbids was measured on Haxe 4.3.7 `--interp`, mutating `sys.net.Socket` /
 * `sys.ssl.Socket` / `sys.ssl.Certificate` against their `extern` core types: every change of a
 * member's PROPERTY ACCESS (`final`, `(default, null)`, `(default, never)`, `static inline var`),
 * of its VISIBILITY, and of its instance-vs-static placement is an error. Member ORDER is free,
 * `inline` on a METHOD is free, and a member the core type does not declare is free — so
 * `member-order` and `prefer-inline` deliberately do NOT take the gate, and the last of those is
 * pinned below so a later widening has to argue with a test.
 *
 * The full matrix lives on `MemberWriteScan.coreApiPinsMemberShape`; this file pins the seven
 * consumers that take it.
 */
class CoreApiConformanceGateTest extends Test {

	/** The annotation under test, spelled as the declaration line that precedes each fixture. */
	private static final CORE_API: String = '@:coreApi\n';

	/** The one file name every single-file fixture is linted under. */
	private static final FIXTURE_FILE: String = 'C.hx';

	/** A private field assigned only at its declaration — `prefer-final-field`'s plain candidate. */
	private static final PRIVATE_FIELD: String =
		'class C {\n\tprivate var _x:Int = 0;\n\tpublic function new() {}\n\tpublic function r():Int return _x;\n}\n';

	/** A public field never written — `prefer-final-public-field`'s plain candidate. */
	private static final PUBLIC_FIELD: String = 'class C {\n\tpublic var x:Int = 0;\n\tpublic function new() {}\n}\n';

	/** A public field written only inside its class — `prefer-read-only-field`'s plain candidate. */
	private static final INTERNALLY_WRITTEN_FIELD: String =
		'class C {\n\tpublic var x:Int = 0;\n\tpublic function new() {}\n\tpublic function s():Void x = 5;\n}\n';

	/** A scalar `static final` — `inline-constant`'s plain candidate. */
	private static final STATIC_CONSTANT: String =
		'class C {\n\tstatic final A:Int = 5;\n\tpublic function new() {}\n\tpublic function r():Int return A;\n}\n';

	/** An instance `final` holding a literal — `static-constant`'s plain candidate. */
	private static final INSTANCE_CONSTANT: String = 'class C {\n\tprivate final _minScale:Float = 0.5;\n'
		+ '\tpublic function new() {}\n\tpublic function f():Float return _minScale;\n}\n';

	/** A read-only property over a private backing field — `trivial-getter`'s plain candidate. */
	private static final TRIVIAL_PROPERTY: String = 'class C {\n\tpublic var active(get, never):Bool;\n'
		+ '\tprivate var _active:Bool = false;\n\tpublic function new() {}\n'
		+ '\tprivate function get_active():Bool { return _active; }\n}\n';

	/** A thin forwarder — `prefer-inline`'s plain candidate, the control for what the gate must NOT reach. */
	private static final THIN_METHOD: String =
		'class C {\n\tprivate var _v:Int = 0;\n\tpublic function new() {}\n\tpublic function getV():Int return _v;\n}\n';

	/** `MakeFinal`'s fixture carries a package statement, so its annotation goes between the two. */
	private static final MAKE_FINAL_HEAD: String = 'package pkg;\n\n';

	/** The body `MakeFinal` is asked to finalize — one declaration-initialised public field. */
	private static final MAKE_FINAL_BODY: String =
		'class Cfg {\n\tpublic var x:Int = 5;\n\tpublic function new() {}\n\tpublic function read():Int return x;\n}\n';

	/** `var` -> `final` on a PRIVATE field: core types do declare private fields (`haxe.Timer.id`, `haxe.ds.List.h`). */
	public function testPreferFinalFieldDeclinesUnderCoreApi(): Void {
		assertGated(PRIVATE_FIELD, files -> new PreferFinalField().run(files, new HaxeQueryPlugin()));
	}

	/** `var` -> `final` on a public field: "Field x has different property access than core type". */
	public function testPreferFinalPublicFieldDeclinesUnderCoreApi(): Void {
		assertGated(PUBLIC_FIELD, files -> new PreferFinalPublicField().run(files, new HaxeQueryPlugin()));
	}

	/** `var` -> `var(default, null)`: the same property-access error, measured for `(default, never)` too. */
	public function testPreferReadOnlyFieldDeclinesUnderCoreApi(): Void {
		assertGated(INTERNALLY_WRITTEN_FIELD, files -> new PreferReadOnlyField().run(files, new HaxeQueryPlugin()));
	}

	/** `static final` -> `static inline final`: `static var X` -> `static inline var X` already errors. */
	public function testInlineConstantDeclinesUnderCoreApi(): Void {
		assertGated(STATIC_CONSTANT, files -> new InlineConstant().run(files, new HaxeQueryPlugin()));
	}

	/** An instance `final` promoted to `static` leaves the instance member set: "Missing field required by core type". */
	public function testStaticConstantDeclinesUnderCoreApi(): Void {
		assertGated(INSTANCE_CONSTANT, files -> new StaticConstant().run(files, new HaxeQueryPlugin()));
	}

	/** Collapsing `(get, never)` to `(default, null)` rewrites the accessor pair — a property-access change. */
	public function testTrivialGetterDeclinesUnderCoreApi(): Void {
		assertGated(TRIVIAL_PROPERTY, files -> new TrivialGetter().run(files, new HaxeQueryPlugin()));
	}

	/** The `make-final` op takes the gate as a refusal, before the index it would otherwise build. */
	public function testMakeFinalRefusesUnderCoreApi(): Void {
		switch runMakeFinal(MAKE_FINAL_HEAD + MAKE_FINAL_BODY) {
			case Ok(_):
				Assert.pass();
			case Err(message):
				Assert.fail('expected Ok on the ungated arm, got Err: $message');
		}
		switch runMakeFinal(MAKE_FINAL_HEAD + CORE_API + MAKE_FINAL_BODY) {
			case Ok(_):
				Assert.fail('expected Err on the @:coreApi arm');
			case Err(message):
				Assert.isTrue(message.indexOf('@:coreApi') >= 0, 'the refusal names the annotation');
		}
	}

	/**
	 * The control. `inline` on a method is LEGAL under `@:coreApi` (measured on both an instance
	 * and a static method), so this rule must not take the gate — and it already declines such a
	 * class through its own inline-neutral metadata whitelist, which is what the second assert
	 * pins. If the gate is ever widened to `prefer-inline`, this test still passes, so the reason
	 * NOT to widen it is written above, not left to the numbers.
	 */
	public function testPreferInlineIsUnaffectedByTheGate(): Void {
		Assert.equals(1, new PreferInline().run([{ file: FIXTURE_FILE, source: THIN_METHOD }], new HaxeQueryPlugin()).length);
		Assert.equals(0, new PreferInline().run([{ file: FIXTURE_FILE, source: CORE_API + THIN_METHOD }], new HaxeQueryPlugin()).length);
	}

	/**
	 * Assert the rule fires exactly once on `body` and not at all on the same body carrying
	 * `@:coreApi`. Both halves matter: a rule that stopped firing outright would satisfy the
	 * gated half alone.
	 */
	private function assertGated(body: String, run: (files:Array<{ file: String, source: String }>) -> Array<Violation>): Void {
		Assert.equals(1, run([{ file: FIXTURE_FILE, source: body }]).length, 'the ungated arm still fires');
		Assert.equals(0, run([{ file: FIXTURE_FILE, source: CORE_API + body }]).length, 'the @:coreApi arm declines');
	}

	/** `MakeFinal.makeFinal` over a one-file scope, finalizing `Cfg.x`. */
	private function runMakeFinal(source: String): EditResult {
		return MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'x', [{ file: 'pkg/Cfg.hx', source: source }], new HaxeQueryPlugin());
	}

}
