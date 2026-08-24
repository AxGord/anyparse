package unit;

import utest.Assert;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Naming;
import anyparse.check.Severity;
import anyparse.grammar.haxe.CheckstyleConfigLoader;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.grammar.haxe.HaxeNamingSupport;
import anyparse.query.NamingPolicy.NamedDecl;

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

	public function testUnprojectedEnumAbstractValuesNotFlagged(): Void {
		// Projected under a plain abstract, an enum-abstract value is governed by the FIELD rule and
		// its conventional PascalCase reads as a violation. The exemption lives in `run`, which holds
		// the tree the marker is recovered from — `violationsFor` alone cannot see it.
		final check: Naming = new Naming();
		final plain: String = '@:enum abstract E(Int) { final Red = 0; final Green = 1; }';
		final guarded: String = '#if (haxe_ver >= 4.2) enum #else @:enum #end abstract E(Int) { final Red = 0; final Green = 1; }';
		Assert.equals(0, check.run([{ file: 'C.hx', source: plain }], new HaxeQueryPlugin()).length);
		Assert.equals(0, check.run([{ file: 'C.hx', source: guarded }], new HaxeQueryPlugin()).length);
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

	/**
	 * A `public static var` is not a member name to checkstyle — `MemberNameCheck.checkField` returns
	 * on `f.isStatic(p)` — so a project's `MemberName` regex does not govern one. The instance field
	 * the project DID write that regex for still is.
	 */
	public function testCheckstyleMemberNameSkipsStatics(): Void {
		final policy: NamingPolicy = ponyShapedMemberPolicy();
		Assert.equals(0, violations('class C {\n\tpublic static var ENVKEY:String;\n}', policy).length);
		Assert.equals(1, violations('class C {\n\tpublic var ENVKEY:String;\n}', policy).length);
	}

	/**
	 * And the arm the discriminator brings alive: with both `MemberName` entries loaded, an enum
	 * constructor is judged by the `ENUM` regex. Before, both entries landed on the same category
	 * with the same empty selector, first-applicable-wins made the second unreachable, and an enum
	 * constructor — an `EnumValue`, which neither entry claimed — was governed by nothing at all.
	 */
	public function testCheckstyleMemberNameEnumArmGovernsConstructors(): Void {
		final policy: NamingPolicy = ponyShapedMemberPolicy();
		Assert.equals(0, violations('enum E {\n\tAlpha;\n\tBeta;\n}', policy).length);
		final vs: Array<Violation> = violations('enum E {\n\talpha;\n}', policy);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.startsWith('MemberName'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('naming'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('naming'));
		Assert.equals(173, Linter.builtins().length);
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

	/**
	 * checkstyle's `ignoreExtern` asks about the DECLARING TYPE's `extern` flag and about nothing else
	 * — not the member, not an `@:native`. `HaxeNamingSupport` projects exactly that as an inherited
	 * modifier, the way an interface member inherits `public`, so a rule states the exemption through
	 * the `forbidMods` selector it already has instead of a flag only one check would read.
	 */
	public function testExternTypeMembersCarryTheTypesOwnExternModifier(): Void {
		final decls: Array<NamedDecl> = new HaxeNamingSupport().project(
			new HaxeQueryPlugin().parseFile('extern class E {\n\tvar Bad_Field:Int;\n\tfunction f(Bad_Param:Int):Void;\n}')
		);
		var seen: Int = 0;
		for (decl in decls) if (decl.name == 'Bad_Field' || decl.name == 'Bad_Param' || decl.name == 'E') {
			seen++;
			Assert.isTrue(decl.mods.contains('extern'), '${decl.name} should carry the enclosing extern');
		}
		Assert.equals(3, seen);
		final plain: Array<NamedDecl> =
			new HaxeNamingSupport().project(new HaxeQueryPlugin().parseFile('class E {\n\tvar Bad_Field:Int;\n}'));
		for (decl in plain) Assert.isFalse(decl.mods.contains('extern'));
	}

	/**
	 * The built-in convention states no `ignoreExtern` — it has no config to state one in — so it
	 * states the same answer checkstyle defaults to. Measured before the gate landed:
	 * `lint --fix --rule naming` rewrote `var Bad_Field:Int;` inside an `extern class` to
	 * `var _badField:Int;`, which changes WHICH external symbol the program reads and which no
	 * compiler oracle can catch. The non-extern twin below is the control: every one of these four
	 * declarations is a finding when the type is the project's own.
	 */
	public function testExternDeclarationsAreOutsideTheBuiltInConvention(): Void {
		final members: String = '\n\tvar Bad_Field:Int;\n\tfunction Bad_Method(Bad_Param:Int):Void;\n';
		Assert.equals(0, violations('extern class bad_cls {$members}').length);
		Assert.equals(4, violations('class bad_cls {${members.replace(':Void;', ':Void {}')}}').length);
	}

	/**
	 * `ignoreExtern: false` is a config stating the opposite, and it must still reach the same
	 * declarations. The exemption is one `forbidMods` entry contributed by the flag, never a
	 * suppression the projection applies on its own.
	 */
	public function testIgnoreExternFalseRestoresTheReport(): Void {
		final src: String = 'extern class E {\n\tvar Bad_Field:Int;\n\tfunction Bad_Method():Void;\n}';
		Assert.equals(2, violations(src, externAwarePolicy(false)).length);
		Assert.equals(0, violations(src, externAwarePolicy(true)).length);
	}

	/**
	 * `MethodNameCheck.checkField` returns on `f.isGetter() || f.isSetter()` before it matches a
	 * format: an accessor's spelling is the PROPERTY's, so the finding belongs to the property and a
	 * correction applied to the accessor alone would orphan it. Invisible under the built-in
	 * convention (its Method format accepts every `get_` / `set_` name) and under Pony's config for the
	 * same reason — reached only by a format strict enough to reject an underscore, where it was three
	 * spurious findings for one property pair. The prefix is the whole test, deliberately: an
	 * `override function get_x` backs a property declared in a supertype, so `set_x` here is exempt
	 * with no `x` in sight.
	 */
	public function testAccessorMethodNameIsThePropertysNotTheProjects(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic var other_thing(get, never):Int;\n\tfunction get_other_thing():Int return 1;\n'
			+ '\tfunction set_x(v:Int):Int return v;\n}',
			externAwarePolicy(true)
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'other_thing'"));
	}

	/**
	 * The exemption is a METHOD's. `MemberNameCheck` has no getter / setter arm at all, so a FIELD
	 * that happens to be spelled `get_x` is governed exactly like any other field.
	 */
	public function testAFieldSpelledLikeAnAccessorIsStillGoverned(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic var get_x:Int;\n}', externAwarePolicy(true));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'get_x'"));
	}

	/**
	 * `MethodNameCheck.checkClassType` returns on `d.flags.contains(HInterface)` before it reaches a
	 * field, so to checkstyle an interface declares no method names at all — and a finding this
	 * adapter labels `MethodName` claims to be that check's, which for an interface method it is not.
	 *
	 * ONE-VARIABLE matrix: the same name, the same rule, the same regex, only the enclosing type's
	 * kind differing. `HInterface` is a `ClassFlag` exactly as `HExtern` is, read off the same
	 * `d.flags` of the same arm, so it travels the selector machinery `EXTERN_MOD` opened rather than
	 * a type KIND on `NamedDecl`.
	 */
	public function testACheckstyleMethodRuleSkipsAnInterfaceAndNotAClass(): Void {
		final iface: Array<Violation> = violations('interface I {\n\tfunction Bad_Method():Void;\n}', externAwarePolicy(true));
		final klass: Array<Violation> = violations('class C {\n\tpublic function Bad_Method():Void {}\n}', externAwarePolicy(true));
		Assert.equals(0, iface.length);
		Assert.equals(1, klass.length);
		Assert.isTrue(klass[0].message.contains("'Bad_Method'"));
	}

	/**
	 * The skip is `MethodName`'s ALONE. `MemberNameCheck` and `ConstantNameCheck` have no interface
	 * arm — their `checkClassType` asks only about `HExtern` — so an interface's PROPERTIES stay
	 * governed, and a gate written as "skip interfaces" rather than as this one rule's `forbidMods`
	 * would have taken them with it.
	 */
	public function testAnInterfacePropertyIsStillAMemberName(): Void {
		final vs: Array<Violation> = violations(
			'interface I {\n\tvar Bad_Prop(get, set):Int;\n\tfunction Bad_Method():Void;\n}', externAwarePolicy(true)
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'Bad_Prop'"));
	}

	/**
	 * The STATED BOUNDARY of `INTERFACE_MOD`, pinned so it is read rather than rediscovered.
	 *
	 * A member inside a `#if` region has the `Conditional` as its PARENT, so the conferral - the same
	 * `parent.kind == 'InterfaceDecl'` test that gives an interface member its unwritten `public` -
	 * does not reach it, and the finding this rule means to drop survives there. Closing it means
	 * threading the enclosing type down the walk as `enclosingExtern` is threaded, which would move
	 * the `public` conferral with it.
	 */
	public function testAnInterfaceMethodInsideAConditionalIsStillReported(): Void {
		final vs: Array<Violation> = violations(
			'interface I {\n\t#if js\n\tfunction Bad_Method():Void;\n\t#end\n}', externAwarePolicy(true)
		);
		Assert.equals(1, vs.length);
	}

	/**
	 * The BUILT-IN convention keeps governing an interface method, and that divergence is the point.
	 * `ignoreExtern` reached `defaults()` because an extern member's name is a FOREIGN contract and a
	 * rename of it is silently wrong; an interface method's name is the project's own, and the rename
	 * is complete (measured: declaration, every implementor and every call site, or a refusal). What
	 * checkstyle's skip protects is FIDELITY to a `checkstyle.json` - a label naming a check whose
	 * author excluded this declaration - and the built-in convention has no `checkstyle.json` to be
	 * faithful to.
	 */
	public function testTheBuiltInConventionStillGovernsAnInterfaceMethod(): Void {
		final vs: Array<Violation> = violations('interface I {\n\tfunction _badMethod():Void;\n}');
		// One assertion, exact and total: pushing `INTERFACE_MOD` into `defaults()` empties `vs`, and
		// a length check followed by `vs[0].message` would report that as a null dereference.
		Assert.equals('camelCase method: \'_badMethod\'', vs.length == 1 ? vs[0].message : '<${vs.length} finding(s)>');
	}

	/**
	 * `policyFor` walked up to the project `checkstyle.json`, read it and rebuilt its rules for EVERY
	 * file — 851 disk walks, 851 JSON parses and 851 policy builds for ONE config on the Pony scope.
	 * The memo is keyed by DIRECTORY because `ConfigFinder.findUp` walks up from a file's own
	 * directory, so two files sharing one resolve to the same config by construction; two directories
	 * resolving to the SAME config still build twice, which is the residue that key trades for its
	 * one-line correctness proof.
	 *
	 * The last assertion is the one invariant 1 is about (`docs/design-principles.md` § 2). A new
	 * support answers a new policy, so the memo's lifetime is one check invocation —
	 * `HaxeQueryPlugin.namingSupport()` builds a fresh instance per call — and never the process's.
	 * Make the field `static` and it is this assertion, and only this assertion, that fails.
	 */
	public function testPolicyIsResolvedOncePerDirectoryAndOncePerRun(): Void {
		final support: HaxeNamingSupport = new HaxeNamingSupport();
		final first: NamingPolicy = support.policyFor('pkg/a/C.hx');
		Assert.isTrue(first == support.policyFor('pkg/a/D.hx'));
		Assert.isFalse(first == support.policyFor('pkg/b/E.hx'));
		Assert.isFalse(first == new HaxeNamingSupport().policyFor('pkg/a/C.hx'));
	}

	/** A `MemberName` + `MethodName` pair over checkstyle's own default format, stating `ignoreExtern`. */
	private function externAwarePolicy(ignoreExtern: Bool): NamingPolicy {
		return CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MemberName","props":{"format":"^[a-z][a-zA-Z0-9]*$","tokens":["CLASS","PUBLIC","PRIVATE"],'
			+ '"ignoreExtern":$ignoreExtern}},'
			+ '{"type":"MethodName","props":{"format":"^[a-z][a-zA-Z0-9]*$","ignoreExtern":$ignoreExtern}}]}'
		);
	}

	/** A real project's two `MemberName` entries: instance fields of a class / typedef, and enum constructors. */
	private function ponyShapedMemberPolicy(): NamingPolicy {
		return CheckstyleConfigLoader.load(
			'{"checks":[{"type":"MemberName","props":{"format":"^[_a-z][_a-zA-Z0-9]*$","tokens":["CLASS","PUBLIC","PRIVATE","TYPEDEF"]}},'
			+ '{"type":"MemberName","props":{"format":"^[A-Z][A-z0-9_]*$","tokens":["ENUM"]}}]}'
		);
	}

}
