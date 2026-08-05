package unit;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `orphan-accessor` check: a `get_X` / `set_X` method whose property `X` declares no matching
 * accessor slot anywhere in the inheritance chain is an accessor Haxe never calls. A property that
 * DOES declare the slot — in the class, in a superclass an `override` accessor serves, in an
 * implemented interface, or via `dynamic` — is legit. The autofix deletes the method (with its
 * modifier run and doc comment) only when the absence is proven and the name has zero direct call
 * references.
 */
@:nullSafety(Strict) class OrphanAccessorCheckTest extends Test {

	public function testDefaultSetPropertyWithGetterFlagged(): Void {
		final src: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tfunction set_data(v:Int):Int return data = v;\n'
			+ '\tpublic inline function get_data():Int {\n\t\treturn data;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('orphan-accessor', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('get_data has no property to serve: data declares no get accessor', vs[0].message);
	}

	public function testGetSetPropertyNotFlagged(): Void {
		final src: String = 'class C {\n\tpublic var data(get, set):Int;\n\tfunction get_data():Int return 1;\n'
			+ '\tfunction set_data(v:Int):Int return v;\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testGetNullPropertySetterFlagged(): Void {
		final src: String = 'class C {\n\tpublic var data(get, null):Int;\n\tfunction get_data():Int return 1;\n'
			+ '\tfunction set_data(v:Int):Int return v;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('set_data has no property to serve: data declares no set accessor', vs[0].message);
	}

	public function testDynamicAccessorCountsAsDeclared(): Void {
		// A `dynamic` accessor is a real, re-bindable one — the slot IS declared.
		final src: String = 'class C {\n\tpublic var data(dynamic, dynamic):Int;\n\tdynamic function get_data():Int return 1;\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testPlainFieldWithGetterFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tpublic var data:Int = 0;\n\tfunction get_data():Int return data;\n}').length);
	}

	public function testNoPropertyAtAllFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction get_data():Int return 1;\n}');
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('get_data has no property to serve: neither C nor its supertypes declare data', vs[0].message);
	}

	public function testOverrideOfInheritedPropertyNotFlagged(): Void {
		final base: String = 'class Base {\n\tpublic var selected(default, set):Bool = false;\n'
			+ '\tpublic function set_selected(v:Bool):Bool {\n\t\tselected = v;\n\t\treturn v;\n\t}\n}';
		final sub: String =
			'class Sub extends Base {\n\toverride public function set_selected(v:Bool):Bool return super.set_selected(v);\n}';
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: sub }]).length);
	}

	public function testOverrideOfSlotlessInheritedPropertyFlagged(): Void {
		final base: String = 'class Base {\n\tpublic var selected(default, null):Bool = false;\n}';
		final sub: String = 'class Sub extends Base {\n\toverride public function set_selected(v:Bool):Bool return v;\n}';
		final vs: Array<Violation> = violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: sub }]);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('set_selected has no property to serve: selected declares no set accessor', vs[0].message);
	}

	public function testInterfacePropertyNotFlagged(): Void {
		final iface: String = 'interface IData {\n\tpublic var data(get, never):Int;\n}';
		final impl: String = 'class C implements IData {\n\tpublic function get_data():Int return 1;\n}';
		Assert.equals(0, violationsOf([{ file: 'IData.hx', source: iface }, { file: 'C.hx', source: impl }]).length);
	}

	public function testSubtypeDeclaredPropertyNotFlagged(): Void {
		// Haxe resolves an accessor UPWARD from the property, so `Sub.v(get, never)` is served by
		// `Base.get_v` — the base method is legit even though nothing at or above Base declares v.
		final base: String = 'class Base {\n\tfunction get_v():Int return 42;\n}';
		final sub: String = 'class Sub extends Base {\n\tpublic var v(get, never):Int;\n}';
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: sub }]).length);
	}

	public function testBuildMacroClassNotFlagged(): Void {
		// A `@:build` macro can declare the very property the accessor serves; its members never
		// reach the index, so the whole class is skipped. The bare source IS a finding — the pair
		// is what shows the metadata is doing the work.
		final body: String = 'class C {\n\tfunction get_data():Int return 1;\n}';
		Assert.equals(1, violations(body).length);
		Assert.equals(0, violations('@:build(M.f()) $body').length);
	}

	public function testAutoBuildOnTheCarrierDoesNotProtectIt(): Void {
		// `@:autoBuild` generates into DESCENDANTS, never into the type carrying it — so the
		// carrier's own accessor is judged normally. (`@:build` is the one that protects here.)
		Assert.equals(1, violations('@:autoBuild(M.f()) class C {\n\tfunction get_data():Int return 1;\n}').length);
	}

	public function testAutoBuildSuperclassProtectsDescendant(): Void {
		final base: String = '@:autoBuild(M.f()) class Base {\n\tpublic function new() {}\n}';
		final sub: String = 'class Sub extends Base {\n\tfunction get_v():Int return 1;\n}';
		final plain: String = 'class Base {\n\tpublic function new() {}\n}';
		Assert.equals(1, violationsOf([{ file: 'Base.hx', source: plain }, { file: 'Sub.hx', source: sub }]).length);
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: sub }]).length);
	}

	public function testAutoBuildInterfaceProtectsImplementor(): Void {
		// The canonical Haxe idiom: `@:autoBuild` on an interface, members generated into every
		// `implements` — the implementor's property is invisible to the index.
		final iface: String = '@:autoBuild(M.f()) interface IGen {}';
		final impl: String = 'class C implements IGen {\n\tfunction get_v():Int return 1;\n}';
		Assert.equals(0, violationsOf([{ file: 'IGen.hx', source: iface }, { file: 'C.hx', source: impl }]).length);
	}

	public function testStaticPropertyDoesNotSatisfyInstanceAccessor(): Void {
		// Statics and instance members are separate namespaces: the static `v` is not the property
		// an instance `get_v` serves.
		final src: String = 'class C {\n\tpublic static var v(get, never):Int;\n\tstatic function get_v():Int return 1;\n}';
		Assert.equals(0, violations(src).length);
		final mixed: String = 'class Base {\n\tpublic static var v(get, never):Int;\n\tstatic function get_v():Int return 1;\n}';
		final sub: String = 'class Sub extends Base {\n\tfunction get_v():Int return 2;\n}';
		Assert.equals(1, violationsOf([{ file: 'Base.hx', source: mixed }, { file: 'Sub.hx', source: sub }]).length);
	}

	public function testInstancePropertyDoesNotSatisfyStaticAccessor(): Void {
		final src: String = 'class C {\n\tpublic var v(get, never):Int;\n\tfunction get_v():Int return 1;\n'
			+ '\tpublic static var w:Int = 0;\n\tstatic function get_w():Int return w;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('get_w has no property to serve: w declares no get accessor', vs[0].message);
	}

	public function testAmbiguousSubtypeSimpleNameBlocksTheFinding(): Void {
		// `Leaf` reaches `Base` only through `Mid`, a simple name two packages declare. A walk that
		// re-resolves that link by name proves nothing and answers "not a subtype" — which for this
		// gate is the UNSAFE default: `Base.get_v` would be reported and deleted while `Leaf.v` is
		// still served by it.
		final base: String = 'class Base {\n\tfunction get_v():Int return 1;\n}';
		final midA: String = 'package a;\nclass Mid extends Base {}';
		final midB: String = 'package b;\nclass Mid extends Base {}';
		final leaf: String = 'package a;\nclass Leaf extends Mid {\n\tpublic var v(get, never):Int;\n}';
		Assert.equals(0, violationsOf([
			{ file: 'Base.hx', source: base },
			{ file: 'a/Mid.hx', source: midA },
			{ file: 'b/Mid.hx', source: midB },
			{ file: 'a/Leaf.hx', source: leaf }
		]).length);
	}

	public function testMemberKeepBlocksFix(): Void {
		final src: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\t@:keep function get_data():Int return data;\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testPrecedingFieldModifiersDoNotLeakOntoTheAccessor(): Void {
		// The `static` and `@:keep` here belong to `other`, not to `get_data` — a run that reset
		// only at methods would read the accessor as static (no instance property found -> a
		// different arm and message) and as kept (never fixed).
		final src: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\t@:keep public static var other:Int = 0;\n'
			+ '\tfunction get_data():Int return data;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('get_data has no property to serve: data declares no get accessor', vs[0].message);
		Assert.equals('class C {\n\tpublic var data(default, set):Int = 0;\n\t@:keep public static var other:Int = 0;\n}', applyFix(src));
	}

	public function testInterpolatedReflectionTargetBlocksFix(): Void {
		// `literalOf` answers null for an interpolated string, so its static FRAGMENTS are what
		// carry the reflection intent — `'get_$suffix'` may name this very method at runtime.
		final owner: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tpublic function get_data():Int return data;\n}';
		final user: String = 'class U {\n\tfunction f(c:C, suffix:String):Dynamic return Reflect.field(c, \'get_$$suffix\');\n}';
		Assert.equals(1, fixEditCount(owner, [{ file: 'C.hx', source: owner }]));
		Assert.equals(0, fixEditCount(owner, [{ file: 'C.hx', source: owner }, { file: 'U.hx', source: user }]));
	}

	public function testKeepClassFlaggedButNotFixed(): Void {
		// `@:keep` members are reached by machinery no scan models — reported, never deleted.
		final src: String = '@:keep class C {\n\tpublic var data(default, set):Int = 0;\n\tfunction get_data():Int return data;\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testFinalClassMetadataIsStillSeen(): Void {
		// A `final class` projects as a FinalDecl WRAPPER, so the metadata run sits before the
		// wrapper — reading the body's own sibling list would clear the gate on every such class.
		Assert.equals(0, violations('@:build(M.f()) final class C {\n\tfunction get_data():Int return 1;\n}').length);
	}

	public function testReflectionStringBlocksFix(): Void {
		// A `Reflect.field(c, 'get_data')` breakage is SILENT at runtime, not a compile error.
		final owner: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tpublic function get_data():Int return data;\n}';
		final user: String = 'class U {\n\tfunction f(c:C):Dynamic return Reflect.field(c, \'get_data\');\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: owner }, { file: 'U.hx', source: user }];
		final check: Null<Check> = Linter.byId('orphan-accessor');
		Assert.notNull(check);
		if (check == null) return;
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run(files, plugin);
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(owner, vs, plugin).length);
	}

	public function testInterpolatedReferenceBlocksFix(): Void {
		// A simple `$name` inside an interpolated string projects as its OWN kind, not identKind.
		final src: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tfunction get_data():Int return data;\n'
			+ '\tfunction tag():String return \'$$get_data\';\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testSpeculativeWalkDoesNotMaskALaterResolvedDeclaration(): Void {
		// `Common` resolves only speculatively (parent package, no import) and withholds its
		// `declared` evidence; `IPar` resolves normally and declares `v` with no set slot. The
		// arm-1 proof must survive regardless of which clause the walk reaches first.
		final common: String = 'package a;\ninterface Common {\n\tpublic var v(get, never):Int;\n}';
		final par: String = 'package a.b;\ninterface IPar {\n\tpublic var v(default, null):Int;\n}';
		final first: String = 'package a.b;\nclass Sub implements Common implements IPar {\n\tfunction set_v(x:Int):Int return x;\n}';
		final second: String = 'package a.b;\nclass Sub implements IPar implements Common {\n\tfunction set_v(x:Int):Int return x;\n}';
		for (sub in [first, second]) {
			final vs: Array<Violation> = violationsOf([
				{ file: 'a/Common.hx', source: common },
				{ file: 'a/b/IPar.hx', source: par },
				{ file: 'a/b/Sub.hx', source: sub }
			]);
			Assert.equals(1, vs.length);
			if (vs.length != 1) continue;
			Assert.equals('set_v has no property to serve: v declares no set accessor', vs[0].message);
		}
	}

	public function testFinalMethodAccessorFlagged(): Void {
		// `FinalModifiedMember` is the other half of METHOD_KINDS — flagged and deleted like a plain one.
		final src: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tfinal function get_data():Int return data;\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tpublic var data(default, set):Int = 0;\n}', applyFix(src));
	}

	public function testAbstractClassAccessorFlagged(): Void {
		final src: String = 'abstract class C {\n\tpublic var data(default, set):Int = 0;\n\tfunction get_data():Int return data;\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testSkipParseInScopeBlocksFix(): Void {
		// An unparseable report file could hold a call the scans cannot see.
		final owner: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tpublic function get_data():Int return data;\n}';
		final broken: String = 'class Bad { function f() {';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: owner }, { file: 'Bad.hx', source: broken }];
		final check: Null<Check> = Linter.byId('orphan-accessor');
		Assert.notNull(check);
		if (check == null) return;
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run(files, plugin);
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(owner, vs, plugin).length);
	}

	public function testFixWithoutRunEditsNothing(): Void {
		// The deletability memo is populated by `run`; a bare `fix` is fail-closed.
		final src: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tfunction get_data():Int return data;\n}';
		final check: Null<Check> = Linter.byId('orphan-accessor');
		Assert.notNull(check);
		if (check == null) return;
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final probe: Null<Check> = Linter.byId('orphan-accessor');
		if (probe == null) return;
		final vs: Array<Violation> = probe.run([{ file: 'C.hx', source: src }], plugin);
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, plugin).length);
	}

	public function testDynamicWriteSlotCountsAsDeclared(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tpublic var data(default, dynamic):Int;\n\tdynamic function set_data(v:Int):Int return v;\n}').length
		);
	}

	public function testParentPackageSupertypeSlotSilencesTheFinding(): Void {
		// `a.b.Sub` names `a.Base` with no import — legal Haxe (a parent package needs none) but
		// invisible to the index's import-visibility resolution. The unique-simple-name fallback
		// finds the property and its `get` slot, so nothing is reported.
		final base: String = 'package a;\nclass Base {\n\tpublic var v(get, never):Int;\n\tfunction get_v():Int return 1;\n}';
		final sub: String = 'package a.b;\nclass Sub extends Base {\n\toverride function get_v():Int return 2;\n}';
		Assert.equals(0, violationsOf([{ file: 'a/Base.hx', source: base }, { file: 'a/b/Sub.hx', source: sub }]).length);
	}

	public function testParentPackageSupertypeWithoutSlotStaysInfoOnly(): Void {
		// The same fallback resolution, but the parent declares `v` with NO get slot. A
		// speculatively-resolved type may not be the real supertype, so its member list never
		// promotes the finding to `Warning` — it stays the unproven `Info` arm, and unfixed.
		final base: String = 'package a;\nclass Base {\n\tpublic var v(default, null):Int = 0;\n}';
		final sub: String = 'package a.b;\nclass Sub extends Base {\n\toverride function get_v():Int return 2;\n}';
		final vs: Array<Violation> = violationsOf([{ file: 'a/Base.hx', source: base }, { file: 'a/b/Sub.hx', source: sub }]);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testAmbiguousSimpleNameIsNotSpeculativelyResolved(): Void {
		// Two `Base` declarations — the fallback refuses to guess, so the chain stays unresolved.
		final one: String = 'package a;\nclass Base {\n\tpublic var v(get, never):Int;\n\tfunction get_v():Int return 1;\n}';
		final two: String = 'package c;\nclass Base {\n\tpublic var v(get, never):Int;\n\tfunction get_v():Int return 1;\n}';
		final sub: String = 'package a.b;\nclass Sub extends Base {\n\toverride function get_v():Int return 2;\n}';
		final vs: Array<Violation> = violationsOf([
			{ file: 'a/Base.hx', source: one },
			{ file: 'c/Base.hx', source: two },
			{ file: 'a/b/Sub.hx', source: sub }
		]);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testUnresolvableSupertypeIsInfoOnly(): Void {
		final vs: Array<Violation> = violations('class C extends Unknown {\n\tfunction get_data():Int return 1;\n}');
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(StringTools.startsWith(vs[0].message, 'get_data may have no property to serve'));
	}

	public function testUnresolvableSupertypeNotFixed(): Void {
		final src: String = 'class C extends Unknown {\n\tfunction get_data():Int return 1;\n}';
		Assert.equals(src, applyFix(src));
	}

	public function testOwnClassDeclarationBeatsUnresolvableSupertype(): Void {
		// Haxe forbids redeclaring an inherited field, so the own-class `data` is conclusive
		// even though `Unknown` never resolves — the finding is a proven orphan and IS fixed.
		final src: String =
			'class C extends Unknown {\n\tpublic var data(default, set):Int = 0;\n\tfunction get_data():Int return data;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('class C extends Unknown {\n\tpublic var data(default, set):Int = 0;\n}', applyFix(src));
	}

	public function testFixDeletesMethodWithModifierRun(): Void {
		final src: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tpublic inline function get_data():Int {\n'
			+ '\t\treturn data;\n\t}\n}';
		Assert.equals('class C {\n\tpublic var data(default, set):Int = 0;\n}', applyFix(src));
	}

	public function testFixDeletesLeadingDocComment(): Void {
		final src: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\n\t/** The data. */\n'
			+ '\tpublic function get_data():Int return data;\n}';
		Assert.equals('class C {\n\tpublic var data(default, set):Int = 0;\n\n}', applyFix(src));
	}

	public function testDirectCallBlocksFix(): Void {
		final src: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tfunction get_data():Int return data;\n'
			+ '\tfunction f():Int return get_data();\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	public function testCrossFileCallBlocksFix(): Void {
		final owner: String = 'class C {\n\tpublic var data(default, set):Int = 0;\n\tpublic function get_data():Int return data;\n}';
		final user: String = 'class U {\n\tfunction f(c:C):Int return c.get_data();\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: owner }, { file: 'U.hx', source: user }];
		final check: Null<Check> = Linter.byId('orphan-accessor');
		Assert.notNull(check);
		if (check == null) return;
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run(files, plugin);
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(owner, vs, plugin).length);
	}

	public function testEmptyPropertyNameSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction get_():Int return 1;\n}').length);
	}

	public function testNonAccessorMethodIgnored(): Void {
		Assert.equals(0, violations('class C {\n\tfunction getData():Int return 1;\n}').length);
	}

	public function testInterfaceBodyIgnored(): Void {
		Assert.equals(0, violations('interface I {\n\tpublic function get_data():Int;\n}').length);
	}

	public function testAbstractBodyIgnored(): Void {
		Assert.equals(0, violations('abstract A(Int) {\n\tpublic function get_data():Int return this;\n}').length);
	}

	public function testStaticPropertyNotFlagged(): Void {
		final src: String = 'class C {\n\tpublic static var data(get, never):Int;\n\tstatic function get_data():Int return 1;\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testRegisteredInBuiltinsAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('orphan-accessor');
		Assert.notNull(check);
		if (check != null) Assert.isTrue(check is DefaultOff);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function get_data():Int {').length);
	}

	private function violations(src: String): Array<Violation> {
		return violationsOf([{ file: 'C.hx', source: src }]);
	}

	private function violationsOf(files: Array<{ file: String, source: String }>): Array<Violation> {
		final check: Null<Check> = Linter.byId('orphan-accessor');
		return check == null ? [] : check.run(files, new HaxeQueryPlugin());
	}

	/** The number of edits `fix` yields for `owner` after `run` over `files` — the deletion gate's verdict. */
	private function fixEditCount(owner: String, files: Array<{ file: String, source: String }>): Int {
		final check: Null<Check> = Linter.byId('orphan-accessor');
		Assert.notNull(check);
		if (check == null) return -1;
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return check.fix(owner, check.run(files, plugin), plugin).length;
	}

	private function applyFix(src: String): String {
		final check: Null<Check> = Linter.byId('orphan-accessor');
		if (check == null) return src;
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
