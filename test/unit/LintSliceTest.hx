package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.format.Text;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;

using StringTools;

import anyparse.check.UnusedLocal;
import anyparse.check.DuplicateImport;

/**
 * The analysis/check layer — the generic `Linter` framework and its first
 * check `unused-import`. Each test drives an IN-MEMORY `(file, source)`
 * fixture through a real `HaxeQueryPlugin` (no disk), asserting the
 * `Violation`s a check produces: an import referenced in a value or type
 * position is left alone, an unreferenced one is a `Warning`, an alias is
 * resolved to its bound name, and the two unverifiable forms (wildcard /
 * `using`) are `Info` advisories. Also covers the framework plumbing
 * (registry lookup, default vs explicit check set), the skip-parse
 * tolerance inherited from `SymbolIndex`, and the grouped reporter.
 */
class LintSliceTest extends Test {

	/**
	 * A type-position reference (`var x:Used`) keeps an import; an import
	 * referenced nowhere is flagged `Warning` at its own source line.
	 */
	public function testUsedVsUnused(): Void {
		final src: String = 'package pkg;\nimport a.b.Used;\nimport a.b.Unused;\nclass C {\n\tvar x:Used;\n}';
		final files = [{ file: 'pkg/C.hx', source: src }];
		final vs: Array<Violation> = new UnusedImport().run(files, plugin());

		Assert.equals(1, vs.length);
		final v: Violation = vs[0];
		Assert.equals('unused-import', v.rule);
		Assert.equals(Severity.Warning, v.severity);
		Assert.isTrue(v.message.contains('a.b.Unused'));
		Assert.equals('pkg/C.hx', v.file);

		final span: Null<Span> = v.span;
		Assert.notNull(span);
		if (span != null) {
			final pos: Position = span.lineCol(src);
			Assert.equals(3, pos.line);
		}
	}

	/** A value reference (`Foo.bar()`) counts as usage; the sibling unused import is flagged. */
	public function testValueReferenceCounts(): Void {
		final src: String = 'package pkg;\nimport a.b.Foo;\nimport a.b.Bar;\nclass C {\n\tfunction f() { Foo.bar(); }\n}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: src }], plugin());

		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('a.b.Bar'));
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/**
	 * An alias is checked by its bound name: a used alias is left alone, an
	 * unused alias is flagged (the message carries the alias — the grammar
	 * does not expose the original path for `import ... as`).
	 */
	public function testAlias(): Void {
		final src: String = 'package pkg;\nimport a.b.Long as Short;\nimport a.b.Other as Gone;\nclass C {\n\tvar x:Short;\n}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: src }], plugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('Gone'));
	}

	/** A wildcard import cannot be verified — reported as an `Info` advisory, not warned. */
	public function testWildcardInfo(): Void {
		final src: String = 'package pkg;\nimport a.b.*;\nclass C {}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: src }], plugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('wildcard'));
	}

	/** A `using` import is applied implicitly as extension calls — an `Info` advisory, not a warning. */
	public function testUsingInfo(): Void {
		final src: String = 'package pkg;\nusing a.b.Helper;\nclass C {}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: src }], plugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('using'));
	}

	/**
	 * The `Linter` registry resolves checks by id, exposes the built-in
	 * set, and `run` with no explicit check set equals running the
	 * built-ins.
	 */
	public function testLinterFrameworkAndRegistry(): Void {
		Assert.notNull(Linter.byId('unused-import'));
		Assert.notNull(Linter.byId('duplicate-import'));
		Assert.isNull(Linter.byId('does-not-exist'));
		Assert.equals(7, Linter.builtins().length);

		final files = [{ file: 'pkg/C.hx', source: 'package pkg;\nimport a.b.Unused;\nclass C {}' }];
		final viaDefault: Array<Violation> = Linter.run(files, plugin());
		Assert.equals(1, viaDefault.length);
		Assert.equals('unused-import', viaDefault[0].rule);

		final viaSubset: Array<Violation> = Linter.run(files, plugin(), [new UnusedImport()]);
		Assert.equals(1, viaSubset.length);
	}

	/**
	 * A type referenced only deep inside a nested generic / anonymous-struct
	 * type (`Array<{ h: Array<Foo> }>`) must NOT be flagged — the raw scan
	 * sees it where the AST type-projection did not. Regression for a
	 * `lint --fix` that deleted a needed import and broke the build.
	 */
	public function testDeepNestedTypeUsageNotFlagged(): Void {
		final src: String = 'package pkg;\nimport a.b.Foo;\nclass C {\n\tfunction f(xs:Array<{h:Array<Foo>}>):Void {}\n}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'f.hx', source: src }], plugin());
		Assert.equals(0, vs.length);
	}

	/** A name appearing only in a comment counts as used — the conservative bias (no false positive). */
	public function testCommentMentionIsConservativelyUsed(): Void {
		final src: String = 'package pkg;\nimport a.b.Foo;\n// Foo is referenced here only\nclass C {}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'f.hx', source: src }], plugin());
		Assert.equals(0, vs.length);
	}

	/** An unparseable file is excluded; the check does not throw (skip-parse tolerance). */
	public function testSkipParseExcluded(): Void {
		final files = [
			{ file: 'pkg/Good.hx', source: 'package pkg;\nimport a.b.Unused;\nclass Good {}' },
			{ file: 'pkg/Bad.hx', source: 'package pkg;\nclass Bad { function f() { ' },
		];
		final vs: Array<Violation> = new UnusedImport().run(files, plugin());
		Assert.equals(1, vs.length);
		Assert.equals('pkg/Good.hx', vs[0].file);
	}

	/** The grouped reporter emits a file header and an indented `[severity] message (rule)` line. */
	public function testRenderViolations(): Void {
		final src: String = 'package pkg;\nimport a.b.Unused;\nclass C {}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: src }], plugin());
		final out: String = Text.renderViolations('pkg/C.hx', src, vs, false);

		Assert.isTrue(out.contains('pkg/C.hx:'));
		Assert.isTrue(out.contains('[warning]'));
		Assert.isTrue(out.contains('(unused-import)'));
	}

	/**
	 * The autofix yields one delete-edit per `Warning` and none for the
	 * unverifiable `Info` advisories (wildcard / `using`) — `lint --fix`
	 * only removes imports it is confident about.
	 */
	public function testFixYieldsDeleteEditsForWarningsOnly(): Void {
		final src: String = 'package pkg;\nimport a.b.Unused;\nimport a.b.*;\nclass C {}';
		final check: UnusedImport = new UnusedImport();
		final vs: Array<Violation> = check.run([{ file: 'pkg/C.hx', source: src }], plugin());
		// One Warning (Unused) + one Info (wildcard); only the Warning is fixable.
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin());
		Assert.equals(1, edits.length);
		Assert.equals('', edits[0].text);
	}

	/** Applying the fix edits removes the unused import and keeps the used one. */
	public function testFixRemovesUnusedImport(): Void {
		final src: String = 'package pkg;\nimport a.b.Used;\nimport a.b.Gone;\nclass C {\n\tvar x:Used;\n}';
		final check: UnusedImport = new UnusedImport();
		final vs: Array<Violation> = check.run([{ file: 'f.hx', source: src }], plugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin());
		switch RefactorSupport.canonicalize(src, edits, true, plugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('Gone') == -1);
				Assert.isTrue(text.indexOf('a.b.Used') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	/**
	 * A local `final` / `var` declared and never read is flagged `Warning` at
	 * its own declaration; a sibling statement that does not mention it is no
	 * use.
	 */
	public function testUnusedLocalFlagged(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal x:Int = 1;\n\t\ttrace(1);\n\t}\n}';
		final vs: Array<Violation> = new UnusedLocal().run([{ file: 'C.hx', source: src }], plugin());

		Assert.equals(1, vs.length);
		final v: Violation = vs[0];
		Assert.equals('unused-local', v.rule);
		Assert.equals(Severity.Warning, v.severity);
		Assert.isTrue(v.message.contains("'x'"));

		final span: Null<Span> = v.span;
		Assert.notNull(span);
		if (span != null) {
			final pos: Position = span.lineCol(src);
			Assert.equals(3, pos.line);
		}
	}

	/** A local that is read by a later statement is not flagged. */
	public function testUsedLocalNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal x:Int = 1;\n\t\ttrace(x);\n\t}\n}';
		final vs: Array<Violation> = new UnusedLocal().run([{ file: 'C.hx', source: src }], plugin());
		Assert.equals(0, vs.length);
	}

	/**
	 * A local used only through simple string interpolation (`'$name'`, an
	 * `Ident` the reference walker does not surface) is kept — the raw scan
	 * sees the name and refuses to flag it.
	 */
	public function testInterpolationCountsAsUse(): Void {
		final src: String = "class C {\n\tfunction f() {\n\t\tfinal name:String = \"a\";\n\t\ttrace('$name');\n\t}\n}";
		final vs: Array<Violation> = new UnusedLocal().run([{ file: 'C.hx', source: src }], plugin());
		Assert.equals(0, vs.length);
	}

	/**
	 * The scan is bounded to the declaration's enclosing scope: an unused `v`
	 * in one function is flagged even though another function has a used `v` of
	 * the same name.
	 */
	public function testScopeBoundedScan(): Void {
		final src: String = 'class C {\n\tfunction a() {\n\t\tfinal v:Int = 1;\n\t}\n\tfunction b() {\n\t\tfinal v:Int = 2;\n\t\ttrace(v);\n\t}\n}';
		final vs: Array<Violation> = new UnusedLocal().run([{ file: 'C.hx', source: src }], plugin());
		Assert.equals(1, vs.length);
	}

	/** An unused function parameter is not a local — it is left alone. */
	public function testParameterNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(p:Int) {\n\t\ttrace(1);\n\t}\n}';
		final vs: Array<Violation> = new UnusedLocal().run([{ file: 'C.hx', source: src }], plugin());
		Assert.equals(0, vs.length);
	}

	/**
	 * The autofix deletes an unused local whose initializer is side-effect-free,
	 * leaving the rest of the body intact.
	 */
	public function testFixDeletesSideEffectFreeLocal(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal x:Int = 1;\n\t\ttrace(1);\n\t}\n}';
		final check: UnusedLocal = new UnusedLocal();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin());
		switch RefactorSupport.canonicalize(src, edits, true, plugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('final x') == -1);
				Assert.isTrue(text.indexOf('trace(1)') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/**
	 * The autofix refuses to delete an unused local with a side-effecting
	 * initializer (a call) — the binding is reported but the side effect is
	 * preserved.
	 */
	public function testFixSkipsSideEffectingInit(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal x:Int = compute();\n\t\ttrace(1);\n\t}\n}';
		final check: UnusedLocal = new UnusedLocal();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin());
		Assert.equals(0, edits.length);
	}

	/** `unused-local` is registered in the default check set alongside `unused-import`. */
	public function testUnusedLocalRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unused-local'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unused-local'));
		Assert.isTrue(ids.contains('unused-import'));
	}

	/** Two identical imports: the second is flagged; distinct aliases of one module are not. */
	public function testDuplicateImportFlagged(): Void {
		final src: String = 'package pkg;\nimport a.b.Dup;\nimport a.b.Dup;\nimport c.D as X;\nimport c.D as Y;\nclass C {}';
		final vs: Array<Violation> = new DuplicateImport().run([{ file: 'pkg/C.hx', source: src }], plugin());
		Assert.equals(1, vs.length);
		Assert.equals('duplicate-import', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('a.b.Dup'));
		final span: Null<Span> = vs[0].span;
		Assert.notNull(span);
		if (span != null) Assert.equals(3, span.lineCol(src).line);
	}

	/** Same path under different kinds (import vs using) bind distinctly — not a duplicate. */
	public function testDistinctKindNotDuplicate(): Void {
		final src: String = 'package pkg;\nimport a.b.Mod;\nusing a.b.Mod;\nclass C {}';
		final vs: Array<Violation> = new DuplicateImport().run([{ file: 'pkg/C.hx', source: src }], plugin());
		Assert.equals(0, vs.length);
	}

	/** The autofix deletes the duplicate (one edit, an empty replacement). */
	public function testDuplicateImportFix(): Void {
		final src: String = 'package pkg;\nimport a.b.Dup;\nimport a.b.Dup;\nclass C {}';
		final check: DuplicateImport = new DuplicateImport();
		final vs: Array<Violation> = check.run([{ file: 'pkg/C.hx', source: src }], plugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin());
		Assert.equals(1, edits.length);
		Assert.equals('', edits[0].text);
	}

}
