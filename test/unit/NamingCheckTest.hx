package unit;

import utest.Assert;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Naming;
import anyparse.check.Severity;
import anyparse.grammar.haxe.CheckstyleConfigLoader;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.NamingPolicy.NamingPolicy;

using StringTools;

/**
 * What the `naming` check REPORTS: declarations are tested against the first
 * applicable rule of a `NamingPolicy` (the built-in Haxe default, or one adapted
 * from a `checkstyle.json`). Each test projects an in-memory source through a real
 * `HaxeNamingSupport` + `HaxeQueryPlugin` and asserts the violations — a private
 * field missing its `_`, a lowercase type, a PascalCase method are flagged;
 * conventional names, a discard binder, a magic module-init method, an acronym-
 * shaped or digit-tailed name are not; a loaded checkstyle policy overrides the
 * default.
 *
 * The autofix parts: `NamingCheckLocalFixTest` (locals, parameters, local
 * functions), `NamingCheckMemberFixTest` (private fields, methods, `static final`
 * constants) and `NamingCheckCrossFileFixTest` (a rename staged across files).
 */
class NamingCheckTest extends NamingCheckTestBase {

	public function testPrivateFieldMissingUnderscore(): Void {
		final vs: Array<Violation> = violations('class C {\n\tprivate var count:Int;\n}');
		Assert.equals(1, vs.length);
		Assert.equals('naming', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'count'"));
	}

	public function testPrivateFieldWithUnderscoreOk(): Void {
		Assert.equals(0, violations('class C {\n\tprivate var _count:Int;\n}').length);
	}

	public function testPublicFieldPascalFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic var Count:Int;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('public field'));
	}

	public function testLowercaseTypeFlagged(): Void {
		final vs: Array<Violation> = violations('class foo {}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('type'));
	}

	public function testPascalCaseMethodFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function Doit() {}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('method'));
	}

	public function testStaticFinalConstantOk(): Void {
		Assert.equals(0, violations('class C {\n\tpublic static final MAX_SIZE:Int = 1;\n}').length);
	}

	public function testStaticFinalLenientConstant(): Void {
		// Both UPPER_SNAKE (const literal) and camelCase (singleton/cache) static finals are accepted.
		Assert.equals(0, violations('class C {\n\tpublic static final MAX_SIZE:Int = 1;\n}').length);
		Assert.equals(0, violations('class C {\n\tpublic static final instance:Int = 0;\n}').length);
		// A PascalCase static final is still flagged.
		final vs: Array<Violation> = violations('class C {\n\tpublic static final BadName:Int = 1;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('static final'));
	}

	public function testConventionalClassClean(): Void {
		final src: String = 'class C {\n\tpublic var name:String;\n\tprivate var _count:Int;\n\tpublic function doThing() {}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testCheckstylePolicyOverridesDefault(): Void {
		// A checkstyle.json requiring lowercase type names inverts the default.
		final policy: NamingPolicy = CheckstyleConfigLoader.load('{"checks":[{"type":"TypeName","props":{"format":"^[a-z]+"}}]}');
		Assert.equals(1, violations('class Foo {}', policy).length);
		Assert.equals(0, violations('class foo {}', policy).length);
	}

	public function testCheckstyleEmptyPolicyNoFindings(): Void {
		// A config with no naming-family checks disables naming entirely.
		final policy: NamingPolicy = CheckstyleConfigLoader.load('{"checks":[{"type":"Indentation","props":{}}]}');
		Assert.equals(0, policy.length);
		Assert.equals(0, violations('class foo {}', policy).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('naming'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('naming'));
		Assert.equals(154, Linter.builtins().length);
	}

	public function testSkipParseNoCrash(): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'Bad.hx', source: 'class Bad { function f() { ' }];
		Assert.equals(0, new Naming().run(files, new HaxeQueryPlugin()).length);
	}

	public function testEnumAbstractValuesNotFlaggedAsFields(): Void {
		// enum-abstract values are EnumValue (PascalCase / UPPER_SNAKE), not private fields.
		Assert.equals(0, violations('enum abstract Severity(Int) {\n\tfinal Error = 0;\n\tfinal Warning = 1;\n}').length);
		final vs: Array<Violation> = violations('enum abstract E(Int) {\n\tfinal bad = 0;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('enum value'));
	}

	public function testInterfaceMemberTreatedAsPublic(): Void {
		// Interface members carry no modifier but are public — a camelCase property is not a private-field violation.
		Assert.equals(0, violations('interface I {\n\tvar length(get, never):Int;\n\tfunction doThing():Void;\n}').length);
	}

	public function testMacroReificationSkipped(): Void {
		// Identifiers inside a macro reification block are splice templates, not real decls — not name-checked.
		final src: String = "class C {\n\tpublic function f() {\n\t\tfinal e = macro {\n\t\t\tfinal $localName = 1;\n\t\t};\n\t}\n}";
		Assert.equals(0, violations(src).length);
	}

	/** A CLASS field spelled like a contract key is the project's own name — still reported. */
	public function testClassFieldWithContractLikeNameStillReported(): Void {
		final src: String = 'class C {\n\tprivate var Limit:Int = 0;\n}';
		final vs: Array<Violation> = new Naming().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
	}

	/**
	 * `renameUnsafe` and `contractName` are DIFFERENT verdicts: an accessor-backed property is a
	 * name the project chose and a human can fix, so it keeps its warning — only the autofix stays
	 * out. Losing this distinction would silence a real finding.
	 */
	public function testAccessorBackedPropertyStillReported(): Void {
		final src: String = 'class C {\n\tpublic var Active(get, never):Bool;\n\n\tprivate function get_Active():Bool return true;\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testTypedefAnonFieldsNotReported(): Void {
		// A typedef / anon-structure field name is an EXTERNAL contract (a server JSON key, a
		// structural-typed payload), not a name the project chooses — so it is not a convention
		// violation at all, and reporting one is noise no reader can act on. Contrast
		// `renameUnsafe`, which still reports.
		final src: String = 'typedef T = {\n\tId: Int,\n\tName: String,\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'T.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	public function testInlineAnonFieldInSignatureNotReported(): Void {
		// The same contract reading applies to an inline anon type in a signature - the field is
		// a `Required` node inside `Anon`, not a real parameter.
		final src: String = 'class C {\n\tpublic function f(o:{ Id:Int }):Void {}\n}';
		final vs: Array<Violation> = new Naming().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	public function testStructureExtensionFieldNotReported(): Void {
		// A structure-extension body's own field is equally a contract name.
		final src: String = 'typedef T = {\n\t> Base,\n\tExtra: Int,\n}';
		final vs: Array<Violation> = new Naming().run([{ file: 'T.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	public function testUnderscoreLocalFlagged(): Void {
		// A local carrying the private-field `_` prefix violates the camelCase-local rule.
		final vs: Array<Violation> = violations('class C {\n\tpublic function f() {\n\t\tvar _x = 1;\n\t\ttrace(_x);\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('local'));
		Assert.isTrue(vs[0].message.contains("'_x'"));
	}

	public function testUnderscoreParamNotFlagged(): Void {
		// A `_`-prefixed PARAMETER is the deliberate unused-marker - not flagged.
		Assert.equals(0, violations('class C {\n\tpublic function f(_unused:Int) {\n\t\treturn 1;\n\t}\n}').length);
	}

	public function testStaticInlineVarConstantOk(): Void {
		// A `static inline var` is a compile-time constant (a write is a compile error,
		// "This expression cannot be accessed for writing" - verified with haxe 4.3.7), so
		// UPPER_SNAKE is the correct convention: an event-name constant must NOT be flagged
		// as a camelCase public field.
		Assert.equals(0, violations('class C {\n\tpublic static inline var ITEM_SELECTED:String = "ITEM_SELECTED";\n}').length);
	}

	public function testStaticInlineVarPascalFlaggedAsConstant(): Void {
		// Reclassified as a Constant: a PascalCase `static inline var` is flagged by the
		// constant rule (UPPER_SNAKE or camelCase), not by the camelCase-public-field rule.
		final vs: Array<Violation> = violations('class C {\n\tpublic static inline var BadName:Int = 1;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('static final'));
	}

	public function testStaticMutableVarStillPublicField(): Void {
		// A plain (non-inline) static var is mutable, NOT a constant - it stays under the
		// public-field rule; the reclassification must not over-reach to mutable statics.
		final vs: Array<Violation> = violations('class C {\n\tpublic static var Count:Int = 0;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('public field'));
	}

	/**
	 * A same-named MEMBER ACCESS through another value (`t.width`) can never be captured by renaming
	 * a function-scoped binding, so it must not block the de-prefixing. The collision scan is
	 * raw-textual, and without the field-access carve-out `t.width` read as a collision - the shape is
	 * everywhere in UI code (`textField.width = __width`).
	 * The mirror: a `this.`-received access DOES resolve in the binding's scope, so the carve-out must
	 * not exclude it - de-prefixing would make the local shadow the member and flip the meaning of
	 * every bare reference. Report-only.
	 * De-prefixing `__x -> x` inside a subclass whose supertype declares `x` would SHADOW that
	 * inherited member - and the `__` prefix exists precisely to avoid the clash. The member is in
	 * scope even when the file never mentions it textually, so the whole-file scan cannot see it:
	 * the inheritance gate blocks the rename (report-only). Provable-positive only, so an
	 * unresolvable supertype closure still renames.
	 */

	public function testDiscardLoopVarNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(items:Array<Int>):Void {\n\t\tfor (_ in items) {}\n\t}\n}').length);
	}

	public function testDiscardParamNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(_:Int):Void {}\n}').length);
	}

	public function testModuleInitMagicMethodNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tstatic function __init__():Void {}\n}').length);
	}

	public function testLeadingDunderPrefixFieldStillFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tprivate var __width:Float;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'__width'"));
	}

	/**
	 * The VALUE binder of a key-value `for` is a local like any other, so it is name-checked
	 * like the KEY beside it. It was unreachable while the loop node carried only the key name
	 * — the naming rule saw one binding where the source has two.
	 */
	public function testKeyValueLoopValueBinderNameChecked(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic function f(m:Map<Int, Int>):Void {\n\t\tfor (k => __value in m) trace(k + __value);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('__value') != -1, vs[0].message);
	}

	/** A discarded VALUE binder is the `_` idiom, not a naming violation — the same exemption the key already had. */
	public function testKeyValueLoopDiscardValueBinderNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tpublic function f(m:Map<Int, Int>):Void {\n\t\tfor (k => _ in m) trace(k);\n\t}\n}').length
		);
	}

	/**
	 * A lowercase head over an all-uppercase tail is an artifact of the old first-letter-lowercasing
	 * normalizer (`HEIGHT` -> `hEIGHT`). camelCase accepts it, yet it is not a name anyone wrote.
	 */
	public function testNormalizerArtifactLocalFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function f() {\n\t\tvar hEIGHT = 1;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'hEIGHT'"), vs[0].message);
		Assert.isTrue(vs[0].message.contains('normalizer artifact'), vs[0].message);
	}

	/** A two-character tail is an `iOS`-style deliberate name, not an artifact - the arm needs three. */
	public function testShortAcronymNameNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f() {\n\t\tvar iOS = true;\n\t}\n}').length);
	}

	/** An ordinary camelCase name whose tail carries a lowercase letter is no artifact. */
	public function testCamelNameWithUppercaseWordNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f() {\n\t\tvar xPos = 1;\n\t}\n}').length);
	}

	/**
	 * A digit-only tail lowercases to itself, so there is no correction to report. The fixture
	 * carries a FOUR-character tail so the pattern accepts it and the no-change gate is what
	 * rejects it.
	 */
	public function testDigitTailNameNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f() {\n\t\tvar x1234 = 1;\n\t}\n}').length);
	}

	/**
	 * A three-character tail cannot be told apart from a deliberate head-plus-acronym name
	 * (`sRGB`, `xDPI`, `dBFS`), so the arm must not claim it - lowercasing `sRGB` to `srgb`
	 * destroys a name someone wrote on purpose.
	 */
	public function testHeadPlusAcronymNameNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f() {\n\t\tvar sRGB = 1;\n\t}\n}').length);
	}

}
