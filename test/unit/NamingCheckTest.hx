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
		Assert.equals(143, Linter.builtins().length);
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

	public function testFixRenamesLocalWithSimpleInterpolation(): Void {
		// A bare `$name` interpolation read IS in the resolver index (as is the braced
		// `${name}` form), so the rename rewrites it along with the declaration instead
		// of bailing to report-only.
		final src: String = "class C {\n\tpublic function f():String {\n\t\tvar BadLocal = 3;\n\t\treturn 'value is $BadLocal';\n\t}\n}";
		assertFixCanonical(src, "$badLocal", 'BadLocal');
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
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixSkipsLocalCollidingWithParam(): Void {
		// De-prefixing `_adjust` to `adjust` collides with a parameter `adjust` - skip.
		final src: String =
			'package pkg;\nclass C {\n\tpublic function f(adjust:Int) {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust + adjust);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixSkipsLocalCollidingWithOwnMember(): Void {
		// De-prefixing `_adjust` to `adjust` collides with an own field `adjust` - skip.
		final src: String =
			'package pkg;\nclass C {\n\tpublic var adjust:Int = 0;\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}


	public function testFixSkipsLocalDeprefixingToKeyword(): Void {
		// De-prefixing `_new` to `new` yields a Haxe keyword - not a usable identifier - skip.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _new = 1;\n\t\ttrace(_new);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
		final superSrc: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _super = 1;\n\t\ttrace(_super);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: superSrc }], 'pkg/C.hx', superSrc);
	}

	public function testFixSkipsLocalReferencedBehindConditional(): Void {
		// A reference behind a mid-expression `#if` is kept as raw trivia (a CondSpliceTail),
		// invisible to the resolver - the rename would leave that occurrence dangling, so the
		// completeness guard bails - skip.
		final src: String =
			'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\tvar x = _adjust #if cpp + _adjust #end;\n\t\ttrace(x);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
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

	/** Assert the naming autofix emits NO edit for `targetFile`, which must still carry at least one finding. */
	private function assertFixSkipped(files: Array<{ file: String, source: String }>, targetFile: String, targetSrc: String): Void {
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
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixBlocksFieldWithUnresolvableOccurrence(): Void {
		// A field reference behind a mid-expression `#if` is raw trivia the resolver cannot bind -
		// an uncovered active-code occurrence. Even with per-binding attribution, an UNRESOLVABLE
		// occurrence still fails the completeness gate closed, so the field rename is skipped.
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tprivate var __id:Int = 0;\n' + '\tpublic function f():Int {\n'
			+ '\t\treturn __id #if cpp + __id #end;\n' + '\t}\n' + '}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}


	public function testFixSkipsParamCapturedByNestedFunctionLocal(): Void {
		// A `__`-param captured by a NESTED local function whose body declares a same-named local:
		// de-prefixing `__items` -> `items` rebinds the param's in-closure use to that local (capture,
		// "has no field push"). A same-named binding ANYWHERE in the param's own function body -
		// including nested local functions - conflicts, so the rename must skip.
		final src: String = 'package pkg;\n' + 'class C {\n' + '\tpublic function f(__items:Array<Int>):Void {\n'
			+ '\t\tfunction finish():Void {\n' + '\t\t\tfinal items:Int = 1;\n' + '\t\t\t__items.push(items);\n' + '\t\t}\n'
			+ '\t\tfinish();\n' + '\t}\n' + '}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
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
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
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

	/**
	 * HALF-APPLIED HAZARD: the subtype's simple name is AMBIGUOUS in the scope (a secondary type
	 * elsewhere in the set shares it), so the positive `isSubtype` proof MISSES - it needs a unique
	 * decl at every closure step. The occurrence must then stay UNCOVERED so the completeness gate
	 * blocks; attributing it to the "different owner" ignore bucket instead drops it silently and the
	 * rename commits the declaring file ALONE, leaving the subtype reading a name that no longer
	 * exists (`Unknown identifier`). Observed live on a 798-file tree where the subtype's simple name
	 * collided with a secondary type in another module.
	 */
	public function testCrossFileFixBlocksWhenSubtypeNameIsAmbiguous(): Void {
		// A bare inherited read in the subtype, attributed by its ENCLOSING class.
		assertAmbiguousSubtypeBlocks('package pkg;\nclass D extends C {\n\tpublic function g() { return size; }\n}');
	}

	/**
	 * The typed-receiver twin of the ambiguous-subtype hazard: `d.size` where `d:D` and `D`'s simple
	 * name is ambiguous. `isSubtype('D', 'C')` misses, and the old `else` arm swept EVERY resolvable
	 * non-subtype receiver into the ignore bucket, so the access was dropped and the rename
	 * half-applied. A receiver type that is not PROVABLY unrelated must block instead.
	 */
	public function testCrossFileFixBlocksOnAmbiguousReceiverType(): Void {
		assertAmbiguousSubtypeBlocks('package pkg;\nclass D extends C {\n\tpublic function g(d:D) { return d.size; }\n}');
	}

	/**
	 * The POSITIVE control for both blockers: the identical fixture WITHOUT the ambiguity-creating
	 * twin module renames completely, across both files. It pins the AMBIGUITY as the reason the two
	 * tests above see zero renames — without it they would stay green if anything upstream (the
	 * policy, `crossFileCandidate`, the rename-safety gate) stopped producing the candidate at all.
	 */
	public function testCrossFileFixRenamesUnambiguousSubtypeControl(): Void {
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g() { return size; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: AMBIGUITY_OWNER_SRC },
			{ file: 'pkg/D.hx', source: dSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		assertNotHalfApplied(renames, 'pkg/C.hx', 'pkg/D.hx');
		assertRenameSlice(renames[0], 'pkg/C.hx', AMBIGUITY_OWNER_SRC, '_size', 'var size');
		assertRenameSlice(renames[0], 'pkg/D.hx', dSrc, '_size', 'return size');
	}

	/**
	 * An ALIASING decl reaches its target through a link no `extends` / `implements` clause records,
	 * so its indexed `supertypes` is EMPTY — and an empty closure "excludes" everything. Here the
	 * subtype reads the inherited field through a receiver typed `Alias`, a `typedef` for the owner
	 * itself: reading that vacuous closure as a proof of unrelatedness filed a genuine owner-bound
	 * access under "different owner" and half-applied the rename. The proof must refuse an aliasing
	 * decl outright, leaving the access uncovered so the completeness gate blocks.
	 */
	public function testCrossFileFixBlocksOnTypedefAliasedReceiver(): Void {
		final aliasSrc: String = 'package pkg;\ntypedef Alias = C;';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g(a:Alias) { return a.size; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: AMBIGUITY_OWNER_SRC },
			{ file: 'pkg/Alias.hx', source: aliasSrc },
			{ file: 'pkg/D.hx', source: dSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		assertNotHalfApplied(renames, 'pkg/C.hx', 'pkg/D.hx');
		Assert.equals(0, renames.length);
	}

	/**
	 * The collision-scan face of the same non-proof. The subtype already declares the TARGET name
	 * (`_size`), which is exactly the clash the target-name scan exists to catch — but that scan
	 * subtracts the spans of types deemed "unrelated" to the owner, and deeming them so from a false
	 * `isSubtype` excluded the REAL subtype's whole body under an ambiguous simple name. The clash
	 * went unseen and the rename emitted `Redefinition of variable _size in subclass` (verified).
	 * Unlike the ignore-bucket arms, nothing downstream re-checks what this set drops.
	 */
	public function testCrossFileFixBlocksOnTargetNameInAmbiguouslyNamedSubtype(): Void {
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tprivate var _size:Int;\n\tpublic function g() { return _size; }\n}';
		final twinSrc: String = 'package pkg;\nclass Twin {}\n\nclass D {\n\tpublic var other:Int;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: AMBIGUITY_OWNER_SRC },
			{ file: 'pkg/D.hx', source: dSrc },
			{ file: 'pkg/Twin.hx', source: twinSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		assertNotHalfApplied(renames, 'pkg/C.hx', 'pkg/D.hx');
		Assert.equals(0, renames.length);
	}

	/** The owner of the ambiguity fixtures: a non-confined private `size` read through `this.`. */
	private static final AMBIGUITY_OWNER_SRC: String =
		'package pkg;\nclass C {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';

	/**
	 * Run the cross-file rename over `dSrc` (a subtype of `C` reading the inherited `size`) alongside
	 * a module declaring a SECOND type named `D`, and assert the rename is refused outright. The twin
	 * makes `declsNamed('D')` ambiguous, which is what defeats the positive `isSubtype` proof.
	 */
	private function assertAmbiguousSubtypeBlocks(dSrc: String): Void {
		final twinSrc: String = 'package pkg;\nclass Twin {}\n\nclass D {\n\tpublic var other:Int;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: AMBIGUITY_OWNER_SRC },
			{ file: 'pkg/D.hx', source: dSrc },
			{ file: 'pkg/Twin.hx', source: twinSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		// The candidate MUST exist, or the zero below would prove nothing.
		Assert.equals(1, vs.length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		// Either a COMPLETE rename (both files) or none - never the declaring file alone.
		assertNotHalfApplied(renames, 'pkg/C.hx', 'pkg/D.hx');
		Assert.equals(0, renames.length);
	}

	/**
	 * A cross-file rename touching `declFile` must also carry `subFile`: committing the declaring
	 * file alone orphans the subtype's inherited read and breaks the build.
	 */
	private function assertNotHalfApplied(renames: Array<Array<CrossFileEdits>>, declFile: String, subFile: String): Void {
		for (rename in renames) {
			var hasDecl: Bool = false;
			var hasSub: Bool = false;
			for (slice in rename) {
				if (slice.file == declFile) hasDecl = true;
				if (slice.file == subFile) hasSub = true;
			}
			if (hasDecl) Assert.isTrue(hasSub, 'half-applied: $declFile renamed without $subFile');
		}
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


	/**
	 * A COMMENT in an affected file that spells the rename TARGET is not a binding of
	 * it, so it must not refuse the cross-file rename. The collision gate asked a raw
	 * word-boundary text scan, which counted the comment and turned the whole rename
	 * report-only; it now asks `RefactorSupport.nameBoundInRange`.
	 */
	public function testCrossFileFixIgnoresTargetNameInComment(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String =
			'package pkg;\nclass D extends C {\n\t// _shape is inherited from C\n\tpublic function g() { return shape; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		assertRenameSlice(renames[0], 'pkg/D.hx', dSrc, '_shape', 'return shape');
	}

	/**
	 * The member-rename path DECLINES on a bound target name — it never qualifies the
	 * rewritten references (`this.x`) the way the `trivial-getter` collapse does. Kept as
	 * a contract test: the sibling audit of the loop-variable shadow hole turned on this
	 * difference, and the decline is what makes the naming fix immune to it.
	 */
	public function testMemberRenameDeclinesOnBoundTargetName(): Void {
		final src: String =
			'class C {\n\tprivate var __count:Int = 0;\n\tprivate var _count:Int = 1;\n\tpublic function sum():Int return __count + _count;\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * GUARD: a REAL binding of the target name in an affected file still refuses the
	 * whole cross-file rename.
	 */
	public function testCrossFileFixBlocksOnRealTargetBinding(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String =
			'package pkg;\nclass D extends C {\n\tprivate var _shape:Int;\n\tpublic function g() { return shape + _shape; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}


	/**
	 * A private METHOD confined to its file de-prefixes like a private field: the resolver
	 * binds its declaration and every in-file call, so `__startCycle` -> `startCycle` is a
	 * complete rename. The autofix used to refuse the whole Method category, leaving the
	 * `__`-prefix findings report-only forever.
	 */
	public function testFixRenamesConfinedPrivateMethod(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function new() { __startCycle(); }\n'
			+ '\tprivate function __startCycle():Void { trace(1); }\n}';
		assertFixCanonicalWithIndex(src, 'startCycle', '__startCycle');
	}


	/**
	 * The callback-value shape: the method is never CALLED, only passed by name to a
	 * subscribe / unsubscribe pair. Both value reads resolve to the declaration, so the
	 * completeness gate is satisfied and all three occurrences rename together.
	 */
	public function testFixRenamesPrivateMethodUsedAsCallbackValue(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function new() { add(__onHover); }\n'
			+ '\tpublic function dispose():Void { remove(__onHover); }\n' + '\tprivate function __onHover(e:Int):Void { trace(e); }\n'
			+ '\tprivate function add(f:Int -> Void):Void {}\n' + '\tprivate function remove(f:Int -> Void):Void {}\n}';
		assertFixCanonicalWithIndex(src, 'add(onHover)', '__onHover');
	}


	/**
	 * An `override` binds the name to the SUPERTYPE's declaration - renaming the override
	 * alone orphans it ("Field ... is declared 'override' but ... does not override"). The
	 * member is still confined and its target name still free, so only the override gate
	 * can refuse it.
	 */
	public function testFixSkipsOverridePrivateMethod(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tprivate function __render():Void {}\n}';
		final cSrc: String = 'package pkg;\nclass C extends Base {\n\toverride private function __render():Void { trace(1); }\n}';
		assertFixSkipped([{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc);
	}


	/**
	 * A subclass can call the inherited private method, so the member is NOT confined and a
	 * single-file rename would leave the subclass calling a name that no longer exists. The
	 * cross-file rename path stays field/constant-only, so this is report-only.
	 */
	public function testFixSkipsPrivateMethodWithSubclass(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate function __tick():Void {}\n\tpublic function f() { __tick(); }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g() { __tick(); }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }], 'pkg/C.hx', cSrc);
	}


	/**
	 * Renaming `__tick` -> `tick` where a supertype already declares `tick` is a Haxe compile
	 * error ("Field tick should be declared with 'override' since it is inherited from
	 * superclass"). The inherited-member gate - previously field-only - must cover a method too.
	 */
	public function testFixSkipsMethodRedefiningInheritedName(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tprivate function tick():Void {}\n}';
		final cSrc: String = 'package pkg;\nclass C extends Base {\n\tprivate function __tick():Void { trace(1); }\n'
			+ '\tpublic function f() { __tick(); }\n}';
		assertFixSkipped([{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc);
	}


	/** A PUBLIC method is reachable from anywhere - outside the single-file rename's proof - so it stays report-only. */
	public function testFixSkipsPublicMethod(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function __run():Void {}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}


	/**
	 * An annotated method is `implicitlyReachable`: a macro / `@:keep` / framework can reach it
	 * by NAME through a channel no identifier-level completeness proof sees. Report-only.
	 */
	public function testFixSkipsAnnotatedPrivateMethod(): Void {
		final src: String = 'package pkg;\nclass C {\n\t@:keep private function __boot():Void {}\n\tpublic function f() { __boot(); }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}


	/**
	 * `_new` de-prefixes to `new` - the CONSTRUCTOR name, not a usable method identifier. The
	 * de-prefix normalizer must refuse a keyword result, as the local / param one already does.
	 */
	public function testFixSkipsMethodDeprefixingToKeyword(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate function _new():Void {}\n\tpublic function f() { _new(); }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}


	/**
	 * A method of a `@:rtti` class is reflected on by NAME - report-only. Held by TWO independent
	 * gates (verified: ablating either alone leaves this green, ablating both flips it) - the
	 * projection's `renameUnsafe` marking of every member of a directly-`@:rtti` type, and the
	 * transitive-rtti gate now extended to the Method category.
	 */
	public function testFixSkipsMethodInRttiClass(): Void {
		final src: String = 'package pkg;\n@:rtti\nclass C {\n\tprivate function __load():Void {}\n\tpublic function f() { __load(); }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
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
	 * A leading ACRONYM run lowercases whole EXCEPT its last character, which heads the next
	 * word: `URLPath` -> `urlPath`. The pre-arm normalizer only lowered the first letter and
	 * emitted `uRLPath`.
	 */
	public function testFixLowercasesLeadingAcronymLocal(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar URLPath = 1;\n\t\ttrace(URLPath);\n\t}\n}';
		assertFixCanonical(src, 'urlPath', 'uRLPath');
	}

	/** The acronym run is delimited by the first LOWERCASE letter, wherever it falls: `HTTPServer` -> `httpServer`. */
	public function testFixLowercasesAcronymRunBeforeWord(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar HTTPServer = 1;\n\t\ttrace(HTTPServer);\n\t}\n}';
		assertFixCanonical(src, 'httpServer', 'hTTPServer');
	}

	/**
	 * An all-uppercase word with NO lowercase letter after it is not an acronym run - the
	 * whole-segment arm still lowercases it (`HEIGHT` -> `height`). Pins behaviour the
	 * acronym arm must not disturb.
	 */
	public function testFixLowercasesAllCapsWordWhole(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar HEIGHT = 1;\n\t\ttrace(HEIGHT);\n\t}\n}';
		assertFixCanonical(src, 'height', 'HEIGHT');
	}

	/**
	 * The acronym arm is LEADING-only and needs a run of two or more: `MyURLPath` opens with a
	 * one-letter run, so only the final first-character lowering applies and the INTERIOR
	 * acronym is left alone. (The bare one-letter run is pinned by `testFixRenamesLocal`.)
	 */
	public function testFixLeavesInteriorAcronymAlone(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar MyURLPath = 1;\n\t\ttrace(MyURLPath);\n\t}\n}';
		assertFixCanonical(src, 'myURLPath', 'MyURLPath');
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

	/** The correction for a normalizer artifact is the whole name lowercased. */
	public function testNormalizerArtifactLocalLowercased(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar hEIGHT = 1;\n\t\ttrace(hEIGHT);\n\t}\n}';
		assertFixCanonical(src, 'height', 'hEIGHT');
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
	 * A private field whose corrected name the constructor PARAMETER already holds is the param
	 * idiom: the field write would become a self-assignment, so the write is qualified through
	 * `this.` instead of the rename being refused.
	 */
	public function testFixQualifiesParamCapturedFieldRename(): Void {
		final src: String =
			'package pkg;\nclass C {\n\tprivate final __position:Int;\n\tpublic function new(_position:Int) {\n\t\t__position = _position;\n\t}\n}';
		assertFixCanonicalWithIndex(src, 'this._position = _position', '__position');
	}

	/**
	 * A capture by a LOCAL is a naming mistake, not the param idiom - qualifying it would emit
	 * correct but confusing code, so the rename stays refused. Pins `Rename.qualifyCaptured`'s
	 * boundary through the `naming` path.
	 */
	public function testFixRefusesLocalCapturedFieldRename(): Void {
		final src: String =
			'package pkg;\nclass C {\n\tprivate final __position:Int = 0;\n\tpublic function f(position:Int):Int {\n\t\tfinal _position:Int = position;\n\t\treturn __position + _position;\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A STATIC member can never be named through `this.`, so the qualification arm must not be
	 * reached for one. Pins the check's own static gate, ahead of the expensive occurrence
	 * resolution - without it the capture repair emits `this.run()` for a static method.
	 */
	public function testFixRefusesStaticMemberCapture(): Void {
		final src: String =
			'package pkg;\nclass C {\n\tprivate static function __run():Void {}\n\tpublic function f(run:Int):Void {\n\t\ttrace(run);\n\t\t__run();\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}


	/**
	 * A member of a Haxe `abstract` cannot be named through `this.` (there `this` is the
	 * underlying value), so the collision must stay a refusal - the qualified rewrite would not
	 * compile. Pins the check's own arm through the shared reachability predicate.
	 */
	public function testFixRefusesAbstractMemberCapture(): Void {
		final src: String =
			'package pkg;\nabstract A(Int) {\n\tprivate function __run():Int return this + 1;\n\tpublic function f(run:Int):Int return __run() + run;\n}';
		assertFixSkipped([{ file: 'pkg/A.hx', source: src }], 'pkg/A.hx', src);
	}

	/**
	 * The private-field normalizer shares the camel word-splitting policy: a leading acronym run
	 * lowercases all but its last character, so the fix cannot manufacture the very
	 * lowercase-head-over-caps-tail shape the artifact arm exists to remove.
	 */
	public function testFixLowercasesLeadingAcronymPrivateField(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var URLPath:Int = 0;\n\tpublic function f():Int return URLPath;\n}';
		assertFixCanonicalWithIndex(src, '_urlPath', '_uRLPath');
	}

	/** An all-caps private field lowercases whole, not first-letter-only: `HEIGHT` -> `_height`, never `_hEIGHT`. */
	public function testFixLowercasesAllCapsPrivateField(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var HEIGHT:Int = 0;\n\tpublic function f():Int return HEIGHT;\n}';
		assertFixCanonicalWithIndex(src, '_height', '_hEIGHT');
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
	 * The MIRROR of the param idiom: a normalizer-artifact LOCAL corrected to `width` would capture
	 * the bare reads of the INHERITED `width`. Those reads are qualified through `this.` and the
	 * rename proceeds, instead of the collision refusing it forever.
	 */
	public function testFixQualifiesInheritedMemberCapturedByLocalRename(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tpublic var width:Int = 0;\n}';
		final cSrc: String = 'package pkg;\nclass C extends Base {\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertLocalRenamed(
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc, 'trace(this.width + width)',
			'wIDTH'
		);
	}

	/**
	 * The same repair when the captured member is the enclosing type's OWN instance field - no
	 * supertype walk needed, the declaration sits in the file being fixed.
	 */
	public function testFixQualifiesOwnMemberCapturedByLocalRename(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic var width:Int = 0;\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'trace(this.width + width)', 'wIDTH');
	}

	/**
	 * A captured STATIC member has no `this.` spelling, so the local rename stays refused - the
	 * mirror of `testFixRefusesStaticMemberCapture` on the member-rename side.
	 */
	public function testFixRefusesLocalRenameCapturingStaticMember(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic static var width:Int = 0;\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * An unresolvable supertype leaves the captured name unproven - qualifying it would be a guess,
	 * so the rename is refused (fail-closed).
	 */
	public function testFixRefusesLocalRenameCapturingUnprovableMember(): Void {
		final src: String = 'package pkg;\nclass C extends Missing {\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}


	/** Assert the naming autofix emits edits for `targetFile` that never overlap one another. */
	private function assertFixEditsDisjoint(files: Array<{ file: String, source: String }>, targetFile: String, targetSrc: String): Void {
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == targetFile);
		Assert.isTrue(vs.length >= 2);
		final edits: Array<{ span: Span, text: String }> = check.fix(targetSrc, vs, new HaxeQueryPlugin(), index);
		for (i in 0...edits.length) for (j in i + 1...edits.length) {
			final a: Span = edits[i].span;
			final b: Span = edits[j].span;
			Assert.isFalse(a.from < b.to && b.from < a.to, 'edits $i and $j overlap');
		}
	}

	/**
	 * The captured occurrence must be one that READ the member: a PARAMETER of the same name
	 * shadowed it, so the occurrence read the param, and `this.width` would rebind it to the field -
	 * valid, type-correct, a different program. Member existence alone is not the proof.
	 */
	public function testFixRefusesLocalRenameCapturingParamShadowedMember(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic var width:Int = 7;\n\tpublic function f(width:Int):Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A `#if`-guarded own `static` member still decides: the SymbolIndex sees a guarded declaration,
	 * so an own-member scan that stopped at the type body's direct children would read this as "no
	 * own declaration", let the inherited instance `width` answer, and emit a `this.` the guarded
	 * build rejects.
	 */
	public function testFixRefusesLocalRenameCapturingConditionalGuardedStatic(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tpublic var width:Int = 0;\n}';
		final cSrc: String = 'package pkg;\nclass C extends Base {\n\t#if debug\n\tpublic static var width:Int = 0;\n\t#end\n'
			+ '\tpublic function f():Void {\n\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc);
	}

	/**
	 * The supertype proof must follow the IMPORT, not the simple name: `C extends b.Base` inherits
	 * nothing, and an unrelated `a.Base` declaring `width` must not supply the proof - the emitted
	 * `this.width` would not compile.
	 */
	public function testFixRefusesLocalRenameCapturingAmbiguouslyNamedSupertypeMember(): Void {
		final aSrc: String = 'package a;\nclass Base {\n\tpublic var width:Int = 0;\n}';
		final bSrc: String = 'package b;\nclass Base {\n\tpublic var depth:Int = 0;\n}';
		final cSrc: String = 'package pkg;\nimport b.Base;\nclass C extends Base {\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([
			{ file: 'a/Base.hx', source: aSrc },
			{ file: 'b/Base.hx', source: bSrc },
			{ file: 'pkg/C.hx', source: cSrc }
		], 'pkg/C.hx', cSrc);
	}

	/**
	 * Two flagged declarations wanting the SAME token: the local's qualification rewrites a bare
	 * `width` that the private field's own rename also owns. Overlapping edits have no defined
	 * winner, so one of the two must defer rather than silently clobber the other.
	 */
	public function testFixEmitsDisjointEditsForCollidingRenames(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f():Void {\n\t\tfinal wIDTH:Int = 1;\n'
			+ '\t\ttrace(width + wIDTH);\n\t}\n\tprivate var width:Int = 0;\n}';
		assertFixEditsDisjoint([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * The repair under a NON-ZERO rename delta - `_width` is one character longer than `width`, so
	 * the qualified rewrite's offsets only map back when the per-occurrence length change is
	 * accumulated rather than assumed zero.
	 */
	public function testFixQualifiesCaptureUnderNonZeroRenameDelta(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tpublic var width:Int = 0;\n}';
		final cSrc: String = 'package pkg;\nclass C extends Base {\n\tpublic function f():Void {\n'
			+ '\t\tfinal _width:Int = 1;\n\t\ttrace(width + _width);\n\t}\n}';
		assertLocalRenamed(
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc, 'trace(this.width + width)',
			'_width'
		);
	}


	/**
	 * A local `function` statement is a declaration the policy governs like any other local
	 * binding: `snake_case` violates the camelCase local rule and the autofix corrects it.
	 */
	public function testLocalFunctionNameFlaggedAndRenamed(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function f() {\n\t\tfunction draw_grid() {\n\t\t\ttrace(1);\n\t\t}\n'
			+ '\t\tdraw_grid();\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf("'draw_grid'") >= 0);
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'function drawGrid()', 'draw_grid');
	}

	/** A conformant local function name is no finding. */
	public function testCamelCaseLocalFunctionNameAccepted(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function f() {\n\t\tfunction drawGrid() {\n\t\t\ttrace(1);\n\t\t}\n'
			+ '\t\tdrawGrid();\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}


	/**
	 * A sibling local function already holding the corrected name is a collision: the scope a local
	 * function binds into is the enclosing body, so the two share it.
	 */
	public function testLocalFunctionCollidingWithSiblingSkipped(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function f() {\n'
			+ '\t\tfunction drawGrid(n:Int) {\n\t\t\tif (n > 0) drawGrid(n - 1);\n\t\t}\n'
			+ '\t\tfunction draw_grid() {\n\t\t\ttrace(1);\n\t\t}\n\t\tdraw_grid();\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A distinctive comment mention in the ENCLOSING body renames along with the local function: the
	 * binding's lexical container is the body it binds into, not the declaration's own span.
	 */
	public function testLocalFunctionCommentMentionRenamesAlong(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function f() {\n'
			+ '\t\t// draw_grid paints the pitch.\n\t\tfunction draw_grid() {\n\t\t\ttrace(1);\n\t\t}\n\t\tdraw_grid();\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, '// drawGrid paints the pitch.', 'draw_grid');
	}

	/**
	 * A read resolved BEFORE the local function's declaration belongs to the member it shadows, so the
	 * rename is refused rather than rewriting a call the compiler binds elsewhere.
	 */
	public function testLocalFunctionWithOccurrenceBeforeDeclarationSkipped(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tprivate function draw_grid() {\n\t\ttrace(1);\n\t}\n\n'
			+ '\tpublic function f() {\n\t\tdraw_grid();\n\t\tfunction draw_grid() {\n\t\t\ttrace(2);\n\t\t}\n\t\tdraw_grid();\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * This check's OWN autofix shares `collidesInScope` with the underscore strip, so it sees the
	 * inline-helper scope union too: a parameter of one local `inline function` no longer collides
	 * with a SIBLING helper's same-named parameter, and `some_n` corrects to `someN` beside a
	 * helper that already binds `someN`. Before the union the two parameters shared the enclosing
	 * METHOD's span and the rename was refused.
	 */
	public function testInlineHelperParameterRenamesBesideSiblingHoldingTheName(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function f() {\n'
			+ '\t\tinline function a(some_n:Int) {\n\t\t\ttrace(some_n);\n\t\t}\n'
			+ '\t\tinline function b(someN:String) {\n\t\t\ttrace(someN);\n\t\t}\n\t\ta(1);\n\t\tb("x");\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.isTrue(vs[0].message.indexOf("'some_n'") >= 0);
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'inline function a(someN:Int)', 'some_n');
	}

}
