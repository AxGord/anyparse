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
import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;

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
		Assert.equals(64, Linter.builtins().length);
	}

	public function testSkipParseNoCrash(): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'Bad.hx', source: 'class Bad { function f() { ' }];
		Assert.equals(0, new Naming().run(files, new HaxeQueryPlugin()).length);
	}

	private function violations(src: String, ?policy: NamingPolicy): Array<Violation> {
		final support: HaxeNamingSupport = new HaxeNamingSupport();
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(src);
		return Naming.violationsFor('C.hx', support.project(tree), policy ?? HaxeNamingSupport.defaults());
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
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('myLocal') >= 0);
				Assert.isTrue(text.indexOf('MyLocal') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testFixRenamesParam(): Void {
		final src: String = 'class C {\n\tpublic function f(BadParam:Int) {\n\t\treturn BadParam;\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('badParam') >= 0);
				Assert.isTrue(text.indexOf('BadParam') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
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
		final files = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin(), index);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('_shape') >= 0);
				Assert.isTrue(text.indexOf('var shape') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
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

}
