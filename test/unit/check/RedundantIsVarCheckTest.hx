package unit.check;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.cli.command.LintCommand;
import utest.Assert;
import utest.Test;

/**
 * The `redundant-isvar` check: an `@:isVar` on a property whose physical field no accessor body,
 * `@:bypassAccessor`, initializer or reflective name can reach is dead, and the fix deletes it.
 * Each negative case is paired with the positive one it differs from by a single construct.
 */
@:nullSafety(Strict) class RedundantIsVarCheckTest extends Test {

	/** A `(never, set)` property whose setter never spells the name — the base finding. */
	private static inline final DEAD_SETTER: String =
		'class C {\n\t@:isVar public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n}';

	/** A base class whose `(get, set)` accessors never spell the name — the owner every cross-file case extends. */
	private static inline final DEAD_BASE: String = 'class Base {\n\tpublic function new() {}\n\t@:isVar public var level(get, set):Int;\n'
		+ '\tfunction get_level():Int return 1;\n\tfunction set_level(v:Int):Int return v;\n}';

	public function testNeverSetWithoutMentionFlaggedAndFixed(): Void {
		final vs: Array<Violation> = violations(DEAD_SETTER);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('redundant-isvar', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('redundant @:isVar on level: no accessor body, @:bypassAccessor or initializer reaches its storage', vs[0].message);
		Assert.equals(
			'class C {\n\tpublic var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n}', applyFix(DEAD_SETTER)
		);
	}

	public function testGetSetOnItsOwnLineFixedWholeLine(): Void {
		final src: String = 'class C {\n\t@:isVar\n\tpublic var level(get, set):Int;\n\tfunction get_level():Int return 1;\n'
			+ '\tfunction set_level(v:Int):Int return v;\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'class C {\n\tpublic var level(get, set):Int;\n\tfunction get_level():Int return 1;\n'
			+ '\tfunction set_level(v:Int):Int return v;\n}',
			applyFix(src)
		);
	}

	@:pin('control') @:killer('M-ISVAR-SLOTS-ANY')
	public function testDefaultSlotNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\t@:isVar public var level(default, set):Int;\n\tfunction set_level(v:Int):Int return v;\n}').length
		);
		Assert.equals(
			0, violations('class C {\n\t@:isVar public var level(get, null):Int;\n\tfunction get_level():Int return 1;\n}').length
		);
	}

	@:pin('control') @:killer('M-ISVAR-NATIVE-BLIND')
	public function testCppCodeOutsideAnAccessorNotFlagged(): Void {
		// Target code is invisible to the Haxe typer: removing the metadata typechecks and the C++ build fails.
		final src: String = 'class C {\n\t@:isVar public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n'
			+ '\tpublic function peek():Int return untyped __cpp__(\'this->level\');\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('control') @:killer('M-ISVAR-NATIVE-BLIND')
	public function testJsSyntaxCodeOutsideAnAccessorNotFlagged(): Void {
		final src: String = 'class C {\n\t@:isVar public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n'
			+ '\tpublic function peek():Int return js.Syntax.code(\'this.level\');\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('control') @:killer('M-ISVAR-NATIVE-BLIND')
	public function testFunctionCodeMetaNotFlagged(): Void {
		final src: String = 'class C {\n\t@:isVar public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n'
			+ '\t@:functionCode(\'this->level = 1;\')\n\tpublic function reset():Void {}\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('control') @:killer('M-ISVAR-MEMBER-KEEP-BLIND')
	public function testKeptMemberNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\t@:keep @:isVar public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n}').length
		);
	}

	@:pin('control') @:killer('M-ISVAR-EMPTY-CALL-UNFIXED')
	public function testEmptyArgumentListIsFixedAndArgumentsAreNotJudged(): Void {
		final src: String = 'class C {\n\t@:isVar() public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tpublic var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n}', applyFix(src));
		Assert.equals(
			0, violations('class C {\n\t@:isVar(1) public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n}').length
		);
	}

	@:pin('control') @:killer('M-ISVAR-INIT-BLIND')
	public function testInitializerNotFlagged(): Void {
		// `= 5` writes the field directly — it is what the metadata's storage is FOR here.
		Assert.equals(
			0,
			violations('class C {\n\t@:isVar public var level(never, set):Int = 5;\n\tfunction set_level(v:Int):Int return v;\n}').length
		);
	}

	@:pin('control') @:killer('M-ISVAR-ACCESSOR-BODY-BLIND')
	public function testSetterWritingStorageNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\t@:isVar public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return level = v;\n}')
				.length
		);
	}

	@:pin('control') @:killer('M-ISVAR-ACCESSOR-BODY-BLIND')
	public function testGetterReadingStorageNotFlagged(): Void {
		final src: String = 'class C {\n\t@:isVar public var level(get, set):Int;\n\tfunction get_level():Int return this.level;\n'
			+ '\tfunction set_level(v:Int):Int return v;\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('control') @:killer('M-ISVAR-ACCESSOR-BODY-BLIND')
	public function testSubclassOverrideWritingStorageNotFlagged(): Void {
		// An override is still an accessor of the property, so its `level = v` reaches the field.
		final writes: String =
			'class Sub extends Base {\n\toverride function set_level(v:Int):Int {\n\t\tlevel = v;\n\t\treturn v;\n\t}\n}';
		final forwards: String = 'class Sub extends Base {\n\toverride function set_level(v:Int):Int return super.set_level(v);\n}';
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: DEAD_BASE }, { file: 'Sub.hx', source: writes }]).length);
		Assert.equals(1, violationsOf([{ file: 'Base.hx', source: DEAD_BASE }, { file: 'Sub.hx', source: forwards }]).length);
	}

	@:pin('control') @:killer('M-ISVAR-SCOPE-REPORT-ONLY')
	public function testSubclassOverrideOutsideTheReportScopeNotFlagged(): Void {
		// The override sits in the RESOLUTION scope only: a one-file lint of Base must still see it.
		final writes: String =
			'class Sub extends Base {\n\toverride function set_level(v:Int):Int {\n\t\tlevel = v;\n\t\treturn v;\n\t}\n}';
		final report: Array<{ file: String, source: String }> = [{ file: 'Base.hx', source: DEAD_BASE }];
		final check: Null<Check> = Linter.byId('redundant-isvar');
		Assert.notNull(check);
		if (check == null) return;
		Assert.equals(0, check.run(report, scoped(report, [{ file: 'Sub.hx', source: writes }])).length);
		Assert.equals(1, check.run(report, scoped(report, [])).length);
	}

	@:pin('control') @:killer('M-ISVAR-BYPASS-BLIND')
	public function testBypassAccessorNotFlagged(): Void {
		final src: String = 'class C {\n\t@:isVar public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n'
			+ '\tpublic function reset():Void {\n\t\t@:bypassAccessor level = 0;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('control') @:killer('M-ISVAR-REFLECTION-BLIND')
	public function testReflectionByNameNotFlagged(): Void {
		final reflects: String = 'class R {\n\tpublic static function peek(o:Dynamic):Dynamic return Reflect.field(o, \'level\');\n}';
		Assert.equals(0, violationsOf([{ file: 'C.hx', source: DEAD_SETTER }, { file: 'R.hx', source: reflects }]).length);
	}

	@:pin('control') @:killer('M-ISVAR-RTTI-BLIND')
	public function testRttiOwnerNotFlagged(): Void {
		Assert.equals(0, violations('@:rtti $DEAD_SETTER').length);
	}

	@:pin('control') @:killer('M-ISVAR-OPAQUE-BLIND')
	public function testOpaqueCondRegionMentioningTheNameNotFlagged(): Void {
		// The `#if` region is captured raw, so nothing inside it projects and only its text can speak.
		final opaque: String = 'class B {\n\tfunction f(c:Bool):Void {\n\t\t#if js if (c) { g(level); } else #end h();\n\t}\n}';
		Assert.equals(0, violationsOf([{ file: 'C.hx', source: DEAD_SETTER }, { file: 'B.hx', source: opaque }]).length);
	}

	/**
	 * Refused twice over, so no single cut turns it red: `ReflectionScan.runtimeName` asks every
	 * unreadable scope file whether it may spell the name, and `storageReachable` refuses on the same
	 * file before it could walk a tree.
	 */
	public function testUnparseableFileMentioningTheNameNotFlagged(): Void {
		final broken: String = 'class B {\n\tfunction q(: {{{\n\tlevel;\n}\n';
		final inert: String = 'class B {\n\tfunction q(: {{{\n}\n';
		Assert.equals(0, violationsOf([{ file: 'C.hx', source: DEAD_SETTER }, { file: 'B.hx', source: broken }]).length);
		Assert.equals(1, violationsOf([{ file: 'C.hx', source: DEAD_SETTER }, { file: 'B.hx', source: inert }]).length);
	}

	@:pin('control') @:killer('M-ISVAR-CHAIN-UNRESOLVED-ADMITTED')
	public function testUnresolvedSupertypeNotFlagged(): Void {
		final sub: String =
			'class C extends Missing {\n\t@:isVar public var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n}';
		Assert.equals(0, violations(sub).length);
		Assert.equals(
			1, violationsOf([
				{ file: 'C.hx', source: sub },
				{ file: 'Missing.hx', source: 'class Missing {}' }
			]).length
		);
	}

	@:pin('control') @:killer('M-ISVAR-MACRO-FIXED')
	public function testMacroBuiltOwnerDeclinedWithoutTheOracle(): Void {
		// A builder may generate an access the text does not hold; only a verified fix may remove the metadata.
		final src: String = '@:build(M.f()) $DEAD_SETTER';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('redundant @:isVar on level: no accessor body, @:bypassAccessor or initializer reaches its storage', vs[0].message);
		Assert.notNull(vs[0].declineReason);
		Assert.equals(src, applyFix(src));
	}

	@:pin('control') @:killer('M-ISVAR-MACRO-NEVER-ADMITTED')
	public function testMacroBuiltOwnerFixedUnderTheOracle(): Void {
		final src: String = '@:build(M.f()) $DEAD_SETTER';
		final check: Null<Check> = Linter.byId('redundant-isvar');
		Assert.isTrue(check is OracleRelaxable);
		if (check == null || !(check is OracleRelaxable)) return;
		(cast check: OracleRelaxable).setOracleRelaxed(true);
		final fixed: String = CheckFixture.fixedSource(check, src);
		(cast check: OracleRelaxable).setOracleRelaxed(false);
		Assert.equals('@:build(M.f()) class C {\n\tpublic var level(never, set):Int;\n\tfunction set_level(v:Int):Int return v;\n}', fixed);
	}

	/**
	 * The partition that makes the macro arm safe: with an oracle the rule is VERIFIED, without one it
	 * stays in the unverified loop — over the whole file set — where only the macro findings decline.
	 */
	public function testTheOracleDecidesWhichPathTheFixTakes(): Void {
		final check: Null<Check> = Linter.byId('redundant-isvar');
		if (check == null) {
			Assert.fail('redundant-isvar is not registered');
			return;
		}
		Assert.isTrue(check is RiskyFix);
		Assert.equals(1, LintCommand.partitionChecks([check], true).risky.length);
		Assert.equals(1, LintCommand.partitionChecks([check], false).fullScope.length);
	}

	private function violations(src: String): Array<Violation> {
		return violationsOf([{ file: 'C.hx', source: src }]);
	}

	private function violationsOf(files: Array<{ file: String, source: String }>): Array<Violation> {
		final check: Null<Check> = Linter.byId('redundant-isvar');
		return check == null ? [] : check.run(files, new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: Null<Check> = Linter.byId('redundant-isvar');
		return check == null ? src : CheckFixture.fixedSource(check, src);
	}

	/** The plugin `LintCommand` builds for a project declaring `resolutionRoots`, `reach` outside the report scope. */
	private function scoped(
		report: Array<{ file: String, source: String }>, reach: Array<{ file: String, source: String }>
	): GrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {report: report, projectRoots: reach, library: new LibrarySources(reach) }
		});
		return plugin;
	}

}
