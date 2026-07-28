package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Naming;
import anyparse.check.Severity;
import anyparse.grammar.haxe.CheckstyleConfigLoader;
import anyparse.grammar.haxe.HaxeNamingSupport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.QueryNode;

using StringTools;

import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;
import anyparse.query.CachingGrammarPlugin;
import anyparse.check.Check.CrossFileEdits;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.CachingGrammarPlugin.LibrarySources;

/**
 * The `naming` check: declarations are tested against the first applicable
 * rule of a `NamingPolicy` (the built-in Haxe default, or one adapted from a
 * `checkstyle.json`). Each test projects an in-memory source through a real
 * `HaxeNamingSupport` + `HaxeQueryPlugin` and asserts the violations — a
 * private field missing its `_`, a lowercase type, a PascalCase method are
 * flagged; conventional names are not; a loaded checkstyle policy overrides
 * the default.
 */
class NamingCheckTest extends Test {

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
		Assert.equals(107, Linter.builtins().length);
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

	public function testFixRenamesLocal(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar MyLocal = 1;\n\t\ttrace(MyLocal);\n\t}\n}';
		assertFixCanonical(src, 'myLocal', 'MyLocal');
	}

	public function testFixRenamesParam(): Void {
		final src: String = 'class C {\n\tpublic function f(BadParam:Int) {\n\t\treturn BadParam;\n\t}\n}';
		assertFixCanonical(src, 'badParam', 'BadParam');
	}

	public function testFixSkipsPrivateField(): Void {
		// A private field is cross-file-reachable (subclass / @:access) — report-only, no rename edit.
		final src: String = 'class C {\n\tprivate var BadField:Int;\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsType(): Void {
		// A type is cross-file-reachable — report-only, no rename edit.
		final src: String = 'class foo {}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixRenamesConfinedPrivateField(): Void {
		// A private field confined to its file (no subtype / @:access / @:allow), all references resolved → renamed.
		final src: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		assertFixCanonicalWithIndex(src, '_shape', 'var shape');
	}

	public function testFixSkipsPrivateFieldWithSubclass(): Void {
		// A subclass (any file) could read the inherited field → report-only.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n}';
		final files = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/D.hx', source: 'package pkg;\nclass D extends C {\n\tpublic function g() { return shape; }\n}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(1, cVs.length);
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsPrivateFieldWithAccessGrant(): Void {
		// Another file with @:access(C) can read C's privates → report-only.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n}';
		final files = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/E.hx', source: 'package pkg;\n@:access(pkg.C)\nclass E {}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsPrivateFieldWithAllow(): Void {
		// @:allow on the class grants another type access → report-only.
		final src: String = 'package pkg;\n@:allow(pkg.X)\nclass C {\n\tprivate var shape:Int;\n}';
		final files = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsPrivateFieldWithNonThisAccess(): Void {
		// A non-`this` access (`o.shape`) is the in-file form the resolver misses → report-only.
		final src: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function eq(o:C) { return o.shape == shape; }\n}';
		final files = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixWithoutIndexLeavesPrivateFieldReportOnly(): Void {
		// No index passed → a private field cannot be proven confined → report-only.
		final src: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'pkg/C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsPrivateFieldWhenAnyFileSkipParses(): Void {
		// A skip-parse file could hide a subtype / @:access we never see → conservatively report-only.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n}';
		final files = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/Bad.hx', source: 'package pkg;\nclass Bad { function f() { ' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsPrivateFieldNameCollision(): Void {
		// Renaming `shape` to `_shape` when `_shape` is already a field of the type
		// would duplicate the binding — skip, report-only.
		final src: String =
			'package pkg;\nclass C {\n\tprivate var _shape:Int;\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape + this._shape; }\n}';
		final files = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsLocalWithSimpleInterpolation(): Void {
		// A local read only through a bare `$name` interpolation is missed by the
		// resolver (the braced `${name}` form is not) — the rename would leave the
		// interpolation dangling, so bail to report-only.
		final src: String = "class C {\n\tpublic function f():String {\n\t\tvar BadLocal = 3;\n\t\treturn 'value is $BadLocal';\n\t}\n}";
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixRenamesLocalWithBracedInterpolation(): Void {
		// The braced `${name}` interpolation IS a resolved reference, so a local
		// rename rewrites both the declaration and the interpolation.
		final src: String = "class C {\n\tpublic function f():String {\n\t\tvar BadLocal = 3;\n\t\treturn 'value is ${BadLocal}';\n\t}\n}";
		assertFixCanonical(src, "${badLocal}", 'BadLocal');
	}

	public function testFixRenamesLocalWithCommentedMention(): Void {
		// A commented-out / prose mention of the old name no longer blocks the rename;
		// the occurrence inside the comment is renamed together with the code.
		final src: String =
			'class C {\n\tpublic function f() {\n\t\t// legacy MyLocal reference\n\t\tvar MyLocal = 1;\n\t\ttrace(MyLocal);\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin()), '// legacy myLocal reference', 'MyLocal');
	}

	public function testFixSkipsLocalMentionedInStringLiteral(): Void {
		// A plain string literal mentioning the old name may be a reflection key, so it
		// blocks the rename (consistent with the reflection-string guards).
		final src: String =
			'class C {\n\tpublic function f():String {\n\t\tvar MyLocal = 1;\n\t\ttrace(MyLocal);\n\t\treturn "MyLocal";\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsLocalMentionedInNoqaComment(): Void {
		// A `noqa`-carrying comment is a machine-meaningful directive line; the rename
		// must not rewrite inside it, so the mention blocks (unlike a plain comment).
		final src: String =
			'class C {\n\tpublic function f() {\n\t\t// noqa: naming keep MyLocal\n\t\tvar MyLocal = 1;\n\t\ttrace(MyLocal);\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsNonDistinctiveFieldMentionedInComment(): Void {
		// An all-lowercase field name is a common word; a word-boundary match inside a comment
		// is likely prose, so the mention blocks the rename (report-only) rather than risk
		// corrupting the comment's prose.
		final src: String =
			'package pkg;\nclass C {\n\t// resets the shape state\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final files = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixRenamesDistinctiveFieldMentionedInComment(): Void {
		// A distinctive field name (carries an uppercase letter) is safe to rename inside a
		// comment too, so a commented-out reference stays consistent with the renamed code.
		final src: String =
			'package pkg;\nclass C {\n\t// legacy xShape fallback\n\tprivate var xShape:Int;\n\tpublic function f() { return this.xShape; }\n}';
		final files = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin(), index), '// legacy _xShape fallback', 'var xShape');
	}

	public function testFixRenamesConfinedStaticFinal(): Void {
		// A confined private static final wrongly given a `_` prefix (the macro-build
		// anchor shape) → the underscore is stripped to a camelCase constant name.
		final src: String = 'package pkg;\nclass C {\n\tprivate static final _forceBuild:Int = 0;\n}';
		assertFixCanonicalWithIndex(src, 'final forceBuild', '_forceBuild');
	}

	public function testFixSkipsStaticFinalNameCollision(): Void {
		// Stripping `_count` → `count` collides with an existing `count` field → report-only.
		final src: String = 'package pkg;\nclass C {\n\tprivate static final _count:Int = 0;\n\tpublic var count:Int;\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsNonDerivableStaticFinal(): Void {
		// Stripping `_FORCE_build` yields `FORCE_build`, not a valid camelCase name → report-only.
		final src: String = 'package pkg;\nclass C {\n\tprivate static final _FORCE_build:Int = 0;\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixRenamesUpperSnakeStaticFinal(): Void {
		// A confined private static final wrongly given a `_` prefix keeps its
		// UPPER_SNAKE shape once the underscore is stripped (`_FORCE_BUILD` →
		// `FORCE_BUILD`, valid per the Constant rule's UPPER_SNAKE branch).
		final src: String = 'package pkg;\nclass C {\n\tprivate static final _FORCE_BUILD:Int = 0;\n}';
		assertFixCanonicalWithIndex(src, 'final FORCE_BUILD', '_FORCE_BUILD');
	}

	public function testFixMemoizesConfinementAcrossFindingsOnOneOwner(): Void {
		// Two flagged private static finals in ONE class: the per-owner confinement
		// memo runs the project-wide scan once, and both findings are still fixed.
		final src: String =
			'package pkg;\nclass C {\n\tprivate static final _forceBuild:Int = 0;\n\tprivate static final _cacheSize:Int = 0;\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(2, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin(), index);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('forceBuild') >= 0);
				Assert.isTrue(text.indexOf('cacheSize') >= 0);
				Assert.isTrue(text.indexOf('_forceBuild') == -1);
				Assert.isTrue(text.indexOf('_cacheSize') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testFixSkipsPrivateFieldReferencedByStringInAnotherFile(): Void {
		#if (sys || nodejs)
		// C's `shape` is confined (no subtype / @:access / @:allow), so WITHOUT the
		// cross-file guard it would be renamed — but Other.hx reaches it by a
		// reflection string `'shape'`, which a rename would break silently.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final otherSrc: String = "package pkg;\nclass Other {\n\tpublic function g() { return Reflect.field(this, 'shape'); }\n}";
		final dir: String = CliFixture.writeDir('namingrefl', [{ name: 'C.hx', source: cSrc }, { name: 'Other.hx', source: otherSrc }]);
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/C.hx', source: cSrc },
			{
				file: '$dir/Other.hx',
				source: otherSrc
			}
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == '$dir/C.hx');
		Assert.equals(1, cVs.length);
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
		cleanupNamingDir(dir, ['C.hx', 'Other.hx']);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFixRenamesPrivateFieldWhenOtherFileHasOnlyIdentifierOrSubstring(): Void {
		#if (sys || nodejs)
		// Other.hx contains `shape` only as an identifier (a param) and as a
		// substring of a longer string ("reshaped:"), neither of which is the exact
		// quoted name — so the cross-file guard does not trip and the rename applies.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final otherSrc: String =
			'package pkg;\nclass Other {\n\tpublic function g(shape:Int):String {\n\t\treturn "reshaped:" + shape;\n\t}\n}';
		final dir: String = CliFixture.writeDir('namingid', [{ name: 'C.hx', source: cSrc }, { name: 'Other.hx', source: otherSrc }]);
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/C.hx', source: cSrc },
			{
				file: '$dir/Other.hx',
				source: otherSrc
			}
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == '$dir/C.hx');
		Assert.equals(1, cVs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(cSrc, cVs, new HaxeQueryPlugin(), index);
		switch RefactorSupport.canonicalize(cSrc, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('_shape') >= 0);
				Assert.isTrue(text.indexOf('var shape') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
		cleanupNamingDir(dir, ['C.hx', 'Other.hx']);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFixSkipsTypedefAnonFields(): Void {
		// A typedef / anon-structure field name is a wire / serialization contract
		// (a server JSON key, a structural-typed payload) whose cross-file consumers
		// a single-file rename cannot see and does not update. The check still reports
		// the convention violation, but the autofix must NOT rename it.
		final src: String = 'typedef T = {\n\tId: Int,\n\tName: String,\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'T.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(2, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsInlineAnonFieldInSignature(): Void {
		// The same wire-contract skip applies to an inline anon type in a signature -
		// the field is a `Required` node inside `Anon`, not a real parameter.
		final src: String = 'class C {\n\tpublic function f(o:{ Id:Int }):Void {}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'Id'"));
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsStructureExtensionField(): Void {
		// A structure-extension body's own field is equally a wire contract - report-only.
		final src: String = 'typedef T = {\n\t> Base,\n\tExtra: Int,\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'T.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'Extra'"));
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsPrivatePropertyWithAccessors(): Void {
		// A confined private property backed by physical `get_`/`set_` accessors:
		// renaming the property to `_value` alone leaves the accessors named
		// `get_Value` / `set_Value`, but Haxe then requires `get__value` /
		// `set__value` - the single-decl autofix would emit non-compiling source, so
		// it must skip the property (report-only).
		final src: String =
			'package pkg;\nclass C {\n\tprivate var Value(get, set):Int;\n\tfunction get_Value():Int return this.Value;\n\tfunction set_Value(v:Int):Int return this.Value = v;\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'Value'"));
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixStillRenamesConfinedPropertylessPrivateField(): Void {
		// Guard against over-skipping: a plain confined private field with no
		// accessor siblings is still renamed - the property skip must not swallow it.
		final src: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		assertFixCanonicalWithIndex(src, '_shape', 'var shape');
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

	public function testFixRenamesUnderscoreLocal(): Void {
		// A local wrongly carrying the private-field `_`/`__` prefix, in a class whose
		// inheritance is fully resolvable (here: no supertype) - the prefix is stripped.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar __adjust = 1;\n\t\ttrace(__adjust);\n\t}\n}';
		assertFixCanonicalWithIndex(src, 'var adjust', '_adjust');
	}

	public function testFixSkipsLocalCollidingWithSiblingLocal(): Void {
		// De-prefixing `_adjust` to `adjust` collides with a sibling local `adjust` - skip.
		final src: String =
			'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\tvar adjust = 2;\n\t\ttrace(_adjust + adjust);\n\t}\n}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixSkipsLocalCollidingWithParam(): Void {
		// De-prefixing `_adjust` to `adjust` collides with a parameter `adjust` - skip.
		final src: String =
			'package pkg;\nclass C {\n\tpublic function f(adjust:Int) {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust + adjust);\n\t}\n}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixSkipsLocalCollidingWithOwnMember(): Void {
		// De-prefixing `_adjust` to `adjust` collides with an own field `adjust` - skip.
		final src: String =
			'package pkg;\nclass C {\n\tpublic var adjust:Int = 0;\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust);\n\t}\n}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}


	public function testFixSkipsLocalDeprefixingToKeyword(): Void {
		// De-prefixing `_new` to `new` yields a Haxe keyword - not a usable identifier - skip.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _new = 1;\n\t\ttrace(_new);\n\t}\n}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
		final superSrc: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _super = 1;\n\t\ttrace(_super);\n\t}\n}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: superSrc }], 'pkg/C.hx', superSrc);
	}

	public function testFixSkipsLocalReferencedBehindConditional(): Void {
		// A reference behind a mid-expression `#if` is kept as raw trivia (a CondSpliceTail),
		// invisible to the resolver - the rename would leave that occurrence dangling, so the
		// completeness guard bails - skip.
		final src: String =
			'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\tvar x = _adjust #if cpp + _adjust #end;\n\t\ttrace(x);\n\t}\n}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	private function violations(src: String, ?policy: NamingPolicy): Array<Violation> {
		final support: HaxeNamingSupport = new HaxeNamingSupport();
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(src);
		return Naming.violationsFor('C.hx', support.project(tree), policy ?? HaxeNamingSupport.defaults());
	}

	private function cleanupNamingDir(dir: String, names: Array<String>): Void {
		#if (sys || nodejs)
		for (n in names) if (sys.FileSystem.exists('$dir/$n')) sys.FileSystem.deleteFile('$dir/$n');
		if (sys.FileSystem.exists(dir)) sys.FileSystem.deleteDirectory(dir);
		#end
	}


	private function assertCanonicalized(src: String, edits: Array<{ span: Span, text: String }>, present: String, absent: String): Void {
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}


	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin()), present, absent);
	}


	private function assertFixCanonicalWithIndex(src: String, present: String, absent: String): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin(), index), present, absent);
	}

	private function assertLocalSkipped(files: Array<{ file: String, source: String }>, targetFile: String, targetSrc: String): Void {
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == targetFile);
		Assert.isTrue(vs.length >= 1);
		Assert.equals(0, check.fix(targetSrc, vs, new HaxeQueryPlugin(), index).length);
	}


	private function assertLocalRenamed(
		files: Array<{ file: String, source: String }>, targetFile: String, targetSrc: String, present: String, absent: String
	): Void {
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == targetFile);
		Assert.isTrue(vs.length >= 1);
		assertCanonicalized(targetSrc, check.fix(targetSrc, vs, new HaxeQueryPlugin(), index), present, absent);
	}


	public function testFixRenamesLocalShadowingInheritedMember(): Void {
		// De-prefixing `_adjust` -> `adjust` where `adjust` is an inherited field: a local
		// SHADOWING an inherited member is legal Haxe (verified), and the whole-file collision
		// scan sees no bare in-file `adjust`, so the rename applies (the inheritance gate is field-only).
		final baseSrc: String = 'package pkg;\nclass Base {\n\tpublic var adjust:Int = 0;\n}';
		final cSrc: String =
			'package pkg;\nclass C extends Base {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust);\n\t}\n}';
		assertLocalRenamed(
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc, 'var adjust', '_adjust'
		);
	}


	public function testFixRenamesLocalUnderUnresolvableInheritance(): Void {
		// The enclosing type extends a base absent from the index. A local cannot clash by
		// REDEFINITION (only a field can) and shadowing is legal, so a local rename no longer
		// depends on resolving inheritance - it applies.
		final src: String =
			'package pkg;\nclass C extends UnknownBase {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust);\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'var adjust', '_adjust');
	}


	public function testFixRenamesSnakeCaseLocal(): Void {
		// A snake_case local is converted to camelCase - the widened normalizer (`min_gap` -> `minGap`).
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar min_gap = 5;\n\t\ttrace(min_gap);\n\t}\n}';
		assertFixCanonical(src, 'minGap', 'min_gap');
	}


	public function testFixRenamesSnakeCaseParam(): Void {
		// A snake_case parameter is converted to camelCase (`grant_type` -> `grantType`).
		final src: String = 'class C {\n\tpublic function f(grant_type:String) {\n\t\treturn grant_type;\n\t}\n}';
		assertFixCanonical(src, 'grantType', 'grant_type');
	}


	public function testFixRenamesUpperSnakeLocal(): Void {
		// An UPPER_SNAKE local is lowercased per-segment then camel-joined (`MAX_LEN` -> `maxLen`).
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar MAX_LEN = 5;\n\t\ttrace(MAX_LEN);\n\t}\n}';
		assertFixCanonical(src, 'maxLen', 'MAX_LEN');
	}


	public function testFixRenamesParamDeprefix(): Void {
		// A `__`-prefixed parameter is de-prefixed to camelCase (a single leading `_` is the
		// deliberate unused-marker and stays conformant; `__` is flagged).
		final src: String = 'class C {\n\tpublic function f(__focusType:Int) {\n\t\treturn __focusType;\n\t}\n}';
		assertFixCanonical(src, 'focusType', '__focusType');
	}


	public function testFixSkipsSnakeLocalCollidingInFile(): Void {
		// The camelCase form already occurs in the file (a sibling local) - the collision scan
		// skips it to avoid a duplicate/shadow the re-parse gate accepts but that would not type-check.
		final src: String =
			'class C {\n\tpublic function f() {\n\t\tvar minGap = 1;\n\t\tvar min_gap = 2;\n\t\ttrace(minGap + min_gap);\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length >= 1);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}


	public function testFixSkipsFieldRedefiningInheritedUnderscoreName(): Void {
		// Renaming `count` -> `_count` would REDEFINE `_count` inherited from Base - a Haxe compile
		// error ("Redefinition of variable in subclass") a local shadow does not have. The field
		// inheritance gate skips it - report-only.
		final baseSrc: String = 'package pkg;\nclass Base {\n\tprivate var _count:Int = 0;\n}';
		final cSrc: String =
			'package pkg;\nclass C extends Base {\n\tprivate var count:Int = 1;\n\tpublic function f() { return this.count; }\n}';
		final files: Array<{ file: String, source: String }> =
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.isTrue(cVs.length >= 1);
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
	}


	public function testFixSkipsFieldInRttiClass(): Void {
		// A field of a class carrying `@:rtti` directly is serialized by reflecting on field NAMES;
		// renaming it breaks saved files. Report-only even though the field is otherwise confined.
		final src: String = 'package pkg;\n@:rtti\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}


	public function testFixSkipsFieldExtendingRttiClass(): Void {
		// A subclass extending a `@:rtti` base (without its own `@:rtti`) is still name-reflected
		// through the base - the transitive index check skips its field.
		final baseSrc: String = 'package pkg;\n@:rtti\nclass Base {\n\tpublic function new() {}\n}';
		final cSrc: String =
			'package pkg;\nclass C extends Base {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final files: Array<{ file: String, source: String }> =
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(1, cVs.length);
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
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
	 * A `_`-prefix field rename resolves its supertype closure through the plugin's
	 * RESOLUTION scope: `Base` lives only in the resolution-scope library (not the
	 * report files), and a clean `Base` lets `x -> _x` proceed. The report-only
	 * `index` (confinement) cannot see `Base`; before the resolution wiring the field
	 * gate consulted THAT index and blocked the rename as an unresolvable supertype.
	 */
	public function testFixFieldResolvesCleanSupertypeThroughResolutionScope(): Void {
		final subSrc: String = 'package pkg;\nclass Sub extends Base {\n\tprivate var x:Int;\n\tpublic function f() { return this.x; }\n}';
		final edits: Array<{ span: Span, text: String }> = fixWithResolutionScope(subSrc, 'package ext;\nclass Base {}');
		assertCanonicalized(subSrc, edits, '_x', 'var x');
	}

	/**
	 * The mirror: when the resolution-scope `Base` DECLARES `_x`, the rename `x -> _x`
	 * would trigger Haxe's "Redefinition of variable in subclass", so the field gate —
	 * now walking the closure through the resolution index — blocks it (report-only).
	 */
	public function testFixFieldBlockedBySupertypeMemberInResolutionScope(): Void {
		final subSrc: String = 'package pkg;\nclass Sub extends Base {\n\tprivate var x:Int;\n\tpublic function f() { return this.x; }\n}';
		final edits: Array<{ span: Span, text: String }> = fixWithResolutionScope(
			subSrc, 'package ext;\nclass Base {\n\tprivate var _x:Int;\n}'
		);
		Assert.equals(0, edits.length);
	}

	public function testCrossFileFixRenamesSubtypeField(): Void {
		// A non-confined private field read by a subclass renames in BOTH the declaring file and
		// the subclass as one atomic cross-file rename — the single-file `fix` leaves it report-only.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g() { return shape; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		// The single-file fix still refuses the non-confined field.
		Assert.equals(0, check.fix(cSrc, vs.filter(v -> v.file == 'pkg/C.hx'), new HaxeQueryPlugin(), index).length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(2, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_shape', 'var shape');
		assertRenameSlice(rename, 'pkg/D.hx', dSrc, '_shape', 'return shape');
	}

	public function testCrossFileFixBlocksOnSubtypeConditional(): Void {
		// A `#if...#end` occurrence of the field name in a subtype is platform-conditional and
		// invisible to the resolver — the whole cross-file rename is refused (report-only).
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String =
			'package pkg;\nclass D extends C {\n\tpublic function g():Int {\n\t\t#if flag\n\t\treturn shape;\n\t\t#else\n\t\treturn 0;\n\t\t#end\n\t}\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testCrossFileFixBlocksOnReflectionString(): Void {
		// A subtype naming the field as a reflection string (`Reflect.field(this, "shape")`) would
		// break silently after a rename — the string occurrence turns the whole rename report-only.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g():Dynamic { return Reflect.field(this, "shape"); }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testCrossFileFixIgnoresDifferentTypedReceiver(): Void {
		// A subtype method accessing a SAME-NAMED field on a DIFFERENT-typed receiver (`o.size` where
		// `o` is `Other`, not the owner `C` nor a subtype of it) provably binds to a different owner, so
		// it is IGNORED — neither renamed nor a blocker. The cross-file rename proceeds, rewriting only
		// the declaring file; the subtype's `o.size` is left untouched.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final otherSrc: String = 'package pkg;\nclass Other {\n\tpublic var size:Int;\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g(o:Other) { return o.size; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/Other.hx', source: otherSrc },
			{ file: 'pkg/D.hx', source: dSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(1, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_size', 'var size');
	}

	public function testCrossFileFixRenamesSubtypeTypedReceiver(): Void {
		// A subtype method accessing the inherited field through a receiver typed as the OWNER (or a
		// subtype of it) — here `d:D`, a subtype of `C` — DOES bind to the inherited field, so the
		// cross-file rename rewrites the declaring file AND the `d.size` access.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g(d:D) { return d.size; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(2, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_size', 'var size');
		assertRenameSlice(rename, 'pkg/D.hx', dSrc, 'd._size', 'd.size');
	}

	public function testStageCrossFileRenameRevertsAllOnCanonicalizationFailure(): Void {
		// Any one file's canonicalization failure reverts the WHOLE multi-file edit set.
		final slices: Array<{ file: String, edits: Array<{ span: Span, text: String }> }> = [
			{ file: 'A.hx', edits: [{ span: new Span(0, 1), text: 'X' }] },
			{ file: 'B.hx', edits: [{ span: new Span(0, 1), text: 'Y' }] }
		];
		final sources: Map<String, String> = ['A.hx' => 'a', 'B.hx' => 'b'];
		final staged: Null<Array<{ file: String, source: String }>> = RefactorSupport.stageCrossFileRename(
			slices, file -> sources[file], (file, source, edits) -> file == 'B.hx' ? EditResult.Err('boom') : EditResult.Ok('X')
		);
		Assert.isNull(staged);
	}

	public function testStageCrossFileRenameCommitsAllOnSuccess(): Void {
		// When every file canonicalizes to a changed result, all rewrites are returned together.
		final slices: Array<{ file: String, edits: Array<{ span: Span, text: String }> }> = [
			{ file: 'A.hx', edits: [{ span: new Span(0, 1), text: 'X' }] },
			{ file: 'B.hx', edits: [{ span: new Span(0, 1), text: 'Y' }] }
		];
		final sources: Map<String, String> = ['A.hx' => 'a', 'B.hx' => 'b'];
		final staged: Null<Array<{ file: String, source: String }>> = RefactorSupport.stageCrossFileRename(
			slices, file -> sources[file], (file, source, edits) -> EditResult.Ok(file == 'A.hx' ? 'X' : 'Y')
		);
		Assert.notNull(staged);
		if (staged != null) Assert.equals(2, staged.length);
	}


	/**
	 * Run naming's field fix on `subSrc` (the sole report file) with `libSrc` as the
	 * only resolution-scope library file. Confinement uses the report-only index; the
	 * field inheritance proof uses the host's resolution index (report UNION library).
	 */
	private function fixWithResolutionScope(subSrc: String, libSrc: String): Array<{ span: Span, text: String }> {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/Sub.hx', source: subSrc }];
		final lib: Array<{ file: String, source: String }> = [{ file: 'ext/Base.hx', source: libSrc }];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({ declared: true, sources: () -> {report: report, library: new LibrarySources(lib) } });
		final reportIndex: SymbolIndex = SymbolIndex.build(report, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(report, scoped).filter(v -> v.file == 'pkg/Sub.hx');
		Assert.equals(1, vs.length);
		return check.fix(subSrc, vs, scoped, reportIndex);
	}

	/** Apply one file's slice of a cross-file rename and assert the `present` name appears and `absent` is gone. */
	private function assertRenameSlice(rename: Array<CrossFileEdits>, file: String, source: String, present: String, absent: String): Void {
		var slice: Null<CrossFileEdits> = null;
		for (s in rename) if (s.file == file) slice = s;
		Assert.notNull(slice);
		if (slice == null) return;
		final applied: String = RefactorSupport.applyEdits(source, slice.edits);
		Assert.isTrue(applied.indexOf(present) >= 0, 'expected "$present" in: $applied');
		Assert.isTrue(applied.indexOf(absent) == -1, 'unexpected "$absent" in: $applied');
	}


	public function testCrossFileFixRenamesUnrelatedSameNamedFieldsIndependently(): Void {
		// Two UNRELATED classes A and B each declare a private `size` and are each subclassed, so both
		// are non-confined cross-file candidates. Each subtype reaches the OTHER class's same-named field
		// through a differently-typed receiver (`b.size` in A's subtype, `a.size` in B's) — a provably
		// DIFFERENT owner that is IGNORED, so neither blocks the other. Both renames proceed in one run.
		final aSrc: String = 'package pkg;\nclass A {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final subASrc: String = 'package pkg;\nclass SubA extends A {\n\tpublic function g(b:B) { return b.size; }\n}';
		final bSrc: String = 'package pkg;\nclass B {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final subBSrc: String = 'package pkg;\nclass SubB extends B {\n\tpublic function g(a:A) { return a.size; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: aSrc },
			{ file: 'pkg/SubA.hx', source: subASrc },
			{ file: 'pkg/B.hx', source: bSrc },
			{ file: 'pkg/SubB.hx', source: subBSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(2, renames.length);
		var renamedA: Bool = false;
		var renamedB: Bool = false;
		for (rename in renames) {
			Assert.equals(1, rename.length);
			if (rename[0].file == 'pkg/A.hx') {
				renamedA = true;
				assertRenameSlice(rename, 'pkg/A.hx', aSrc, '_size', 'var size');
			}
			if (rename[0].file == 'pkg/B.hx') {
				renamedB = true;
				assertRenameSlice(rename, 'pkg/B.hx', bSrc, '_size', 'var size');
			}
		}
		Assert.isTrue(renamedA);
		Assert.isTrue(renamedB);
	}


	public function testCrossFileFixBlocksOnUnresolvableReceiver(): Void {
		// A subtype method reaching `.size` through a receiver whose type cannot be resolved (an untyped
		// parameter) is an occurrence whose owner cannot be proven — it is left uncovered, so the
		// completeness gate blocks the whole cross-file rename (fail-closed, unchanged behaviour).
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g(o) { return o.size; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}


	public function testFixDePrefixesDoubleUnderscoreField(): Void {
		// A private field with a doubled underscore (`__size`) de-prefixes to the single-underscore
		// convention (`_size`), mirroring the snake/de-prefix normalisation already applied to locals.
		final src: String = 'package pkg;\nclass C {\n\tprivate var __size:Int;\n\tpublic function f() { return this.__size; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin(), index);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('_size') >= 0);
				Assert.isTrue(text.indexOf('__size') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}


	public function testFixRenamesThreeSameNameBindings(): Void {
		// One file with THREE distinct `__id` bindings - a private field, a parameter, and a
		// for-loop iterator. Each renames to its OWN target (field -> `_id`, param & loop -> `id`)
		// in a single fix pass; the per-binding spans are disjoint so the edits do not corrupt.
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tprivate var __id:Int = 0;\n' + '\tpublic function add():Int {\n'
			+ '\t\treturn __id++;\n' + '\t}\n' + '\tpublic function remove(__id:Int):Void {\n' + '\t\tremoveAt(__id);\n' + '\t}\n'
			+ '\tpublic function clear():Void {\n' + '\t\tfor (__id in [1, 2, 3]) removeAt(__id);\n' + '\t}\n'
			+ '\tfunction removeAt(x:Int):Void {}\n' + '}';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'pkg/C.hx', source: src }], new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'pkg/C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length >= 3);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin(), index), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(-1, text.indexOf('__id'));
				Assert.isTrue(text.indexOf('var _id') >= 0);
				Assert.isTrue(text.indexOf('remove(id') >= 0);
				Assert.isTrue(text.indexOf('for (id in') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testFixRenamesLocalDespiteSameNameInUnrelatedFunction(): Void {
		// `adjust` also names a local in an UNRELATED method `g` - out of `f`'s scope, so it no
		// longer blocks de-prefixing `_adjust` -> `adjust` in `f` (the collision scan is scope-aware).
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tpublic function f() {\n' + '\t\tvar _adjust = 1;\n'
			+ '\t\ttrace(_adjust);\n' + '\t}\n' + '\tpublic function g() {\n' + '\t\tvar adjust = 2;\n' + '\t\ttrace(adjust);\n' + '\t}\n'
			+ '}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'var adjust', '_adjust');
	}

	public function testFixSkipsLocalCollidingWithEnclosingScopeLocal(): Void {
		// `adjust` is bound in an ENCLOSING block of the SAME function - reachable from the inner
		// scope, so de-prefixing `_adjust` -> `adjust` is a genuine conflict and still skips
		// (scope-awareness exempts only UNRELATED functions, never the binding's own scope chain).
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tpublic function f() {\n' + '\t\tvar adjust = 1;\n'
			+ '\t\tif (adjust > 0) {\n' + '\t\t\tvar _adjust = 2;\n' + '\t\t\ttrace(_adjust + adjust);\n' + '\t\t}\n' + '\t}\n' + '}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixBlocksFieldWithUnresolvableOccurrence(): Void {
		// A field reference behind a mid-expression `#if` is raw trivia the resolver cannot bind -
		// an uncovered active-code occurrence. Even with per-binding attribution, an UNRESOLVABLE
		// occurrence still fails the completeness gate closed, so the field rename is skipped.
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tprivate var __id:Int = 0;\n' + '\tpublic function f():Int {\n'
			+ '\t\treturn __id #if cpp + __id #end;\n' + '\t}\n' + '}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}


	public function testFixSkipsParamCapturedByNestedFunctionLocal(): Void {
		// A `__`-param captured by a NESTED local function whose body declares a same-named local:
		// de-prefixing `__items` -> `items` rebinds the param's in-closure use to that local (capture,
		// "has no field push"). A same-named binding ANYWHERE in the param's own function body -
		// including nested local functions - conflicts, so the rename must skip.
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tpublic function f(__items:Array<Int>):Void {\n'
			+ '\t\tfunction finish():Void {\n' + '\t\t\tfinal items:Int = 1;\n' + '\t\t\t__items.push(items);\n' + '\t\t}\n'
			+ '\t\tfinish();\n' + '\t}\n' + '}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixRenamesParamDespiteSameNameLocalInUnrelatedFunction(): Void {
		// `items` names a local only in an UNRELATED method `g` - out of `f`'s scope, so de-prefixing
		// param `__items` -> `items` in `f` still applies (scope-awareness exempts unrelated functions,
		// but never the binding's own body or its nested closures).
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tpublic function f(__items:Array<Int>):Void {\n'
			+ '\t\t__items.push(1);\n' + '\t}\n' + '\tpublic function g():Void {\n' + '\t\tfinal items:Int = 2;\n' + '\t\ttrace(items);\n'
			+ '\t}\n' + '}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'items.push', '__items');
	}

	public function testFixBlocksFieldWhenCaseLocalLeaksOverUses(): Void {
		// The field `logo` is used bare before and after a `switch` whose case branches each declare a
		// `logo` local. A scope resolver that opens no frame per case branch mis-binds those bare field
		// uses to a case-local; the fix must NOT silently exclude them (which would rename the field decl
		// alone and orphan the uses). It renames them with the field OR - fail-closed - blocks the whole
		// field rename. Here it blocks (the leaked uses stay uncovered active code).
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tprivate var logo:Null<Sprite>;\n'
			+ '\tpublic function make(kind:Int):Void {\n' + '\t\tif (logo != null) removeChild(logo);\n' + '\t\tlogo = switch kind {\n'
			+ '\t\t\tcase 0:\n' + '\t\t\t\tfinal logo:Sprite = new Sprite();\n' + '\t\t\t\tlogo;\n' + '\t\t\tcase _:\n'
			+ '\t\t\t\tfinal logo:Sprite = new Sprite();\n' + '\t\t\t\tlogo;\n' + '\t\t};\n' + '\t\taddChild(logo);\n' + '\t}\n'
			+ '\tfunction removeChild(o:Sprite):Void {}\n' + '\tfunction addChild(o:Sprite):Void {}\n' + '}';
		assertLocalSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixRenamesFieldWithSameNamedParamInAnotherMethod(): Void {
		// The valid counterpart of the leak case: a same-named PARAM in one method (properly scoped) does
		// NOT steal the field's bare uses in ANOTHER method - those correctly bind to the field and rename
		// with it; the param is excluded (it genuinely binds elsewhere) and stays put.
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tprivate var logo:Null<Sprite>;\n'
			+ '\tpublic function set(logo:Sprite):Void {\n' + '\t\tthis.logo = logo;\n' + '\t}\n' + '\tpublic function use():Void {\n'
			+ '\t\tif (logo != null) logo.x = 0;\n' + '\t}\n' + '}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'var _logo', 'var logo');
	}


	public function testFixDoesNotRenameCommentMentionOfUnrelatedBinding(): Void {
		// Two methods each declare a DISTINCT `__x`. Renaming method `a`'s `__x` -> `x` must not rewrite
		// the `__x` mention in method `b`'s comment (which refers to b's own, un-renamed `__x`): comment
		// -along is scoped to the binding's container, so a same-named binding elsewhere is left alone.
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tpublic function a(__x:Int):Int {\n' + '\t\treturn __x;\n' + '\t}\n'
			+ '\tpublic function b(__x:Int):Int {\n' + '\t\tvar x:Int = 5;\n' + '\t\t// keep __x here\n' + '\t\treturn __x + x;\n'
			+ '\t}\n' + '}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('// keep __x here') >= 0);
				Assert.isTrue(text.indexOf('a(x:Int)') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}


	/**
	 * The subtype lives as a SECONDARY type in a module whose PRIMARY type belongs to an
	 * UNRELATED hierarchy that already uses the target name (`_w`, inherited from its own
	 * `Base`). That occurrence cannot clash with the owner's renamed field - different class,
	 * different inherited member - so it must NOT block the cross-file rename. The old guard
	 * was a blunt WHOLE-FILE textual scan and refused the whole rename.
	 */
	public function testCrossFileFixIgnoresTargetNameInUnrelatedSiblingType(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var __w:Int;\n\tpublic function f() { return this.__w; }\n}';
		final baseSrc: String = 'package pkg;\nclass Base {\n\tprivate var _w:Int;\n}';
		final hostSrc: String =
			'package pkg;\nclass Host extends Base {\n\tpublic function h() { return _w; }\n}\n\nclass Sub extends C {\n\tpublic function g() { return __w; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/Base.hx', source: baseSrc },
			{ file: 'pkg/Host.hx', source: hostSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(2, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_w', 'var __w');
		assertRenameSlice(rename, 'pkg/Host.hx', hostSrc, '_w', 'return __w');
	}


	/**
	 * The mirror: the target name is already declared INSIDE the subtype itself, where the
	 * renamed inherited field would hit Haxe's "Redefinition of variable in subclass" - a real
	 * collision, so the rename stays report-only even under the scope-aware guard.
	 */
	public function testCrossFileFixBlocksOnTargetNameInsideSubtype(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var __w:Int;\n\tpublic function f() { return this.__w; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tprivate var _w:Int;\n\tpublic function g() { return __w + _w; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * A same-named MEMBER ACCESS through another value (`t.width`) can never be captured by renaming
	 * a function-scoped binding, so it must not block the de-prefixing. The collision scan is
	 * raw-textual, and without the field-access carve-out `t.width` read as a collision - the shape is
	 * everywhere in UI code (`textField.width = __width`).
	 */
	/**
	 * The mirror: a `this.`-received access DOES resolve in the binding's scope, so the carve-out must
	 * not exclude it - de-prefixing would make the local shadow the member and flip the meaning of
	 * every bare reference. Report-only.
	 */
	/**
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

	public function testCrossFileFixRenamesFinalAndAbstractSubtypeField(): Void {
		// The subtype reads live inside a `final class` (ClassForm) and an `abstract class`
		// (AbstractClassDecl) — receiver attribution must recognise both class shapes, else
		// the completeness gate fails closed and the cross-file rename silently no-ops.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String = 'package pkg;\nfinal class D extends C {\n\tpublic function g() { return shape; }\n}';
		final eSrc: String = 'package pkg;\nabstract class E extends C {\n\tpublic function h() { return shape; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/D.hx', source: dSrc },
			{ file: 'pkg/E.hx', source: eSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(3, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_shape', 'var shape');
		assertRenameSlice(rename, 'pkg/D.hx', dSrc, '_shape', 'return shape');
		assertRenameSlice(rename, 'pkg/E.hx', eSrc, '_shape', 'return shape');
	}

}
