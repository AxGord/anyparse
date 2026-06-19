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
import anyparse.query.format.LintFormat;
import anyparse.check.DeadCode;
import anyparse.check.SelfAssignment;

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
		Assert.equals(37, Linter.builtins().length);

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

	/**
	 * A trailing `// noqa` on an unused-import line silences the finding;
	 * `Linter.run` (which applies suppression) returns it cleared.
	 */
	public function testNoqaSuppressesSameLine(): Void {
		final src: String = 'package pkg;\nimport a.b.Used;\nimport a.b.Unused; // noqa\nclass C {\n\tvar x:Used;\n}';
		final vs: Array<Violation> = Linter.run([{ file: 'pkg/C.hx', source: src }], plugin(), [new UnusedImport()]);
		Assert.equals(0, vs.length);
	}

	/**
	 * `// noqa: <rule>` silences only the named rule on its line: it clears
	 * `unused-import`, but the same directive naming a different rule leaves
	 * the import flagged.
	 */
	public function testNoqaNamedRule(): Void {
		final cleared: String = 'package pkg;\nimport a.b.Unused; // noqa: unused-import\nclass C {}';
		final a: Array<Violation> = Linter.run([{ file: 'pkg/A.hx', source: cleared }], plugin(), [new UnusedImport()]);
		Assert.equals(0, a.length);

		final wrong: String = 'package pkg;\nimport a.b.Unused; // noqa: duplicate-import\nclass C {}';
		final b: Array<Violation> = Linter.run([{ file: 'pkg/B.hx', source: wrong }], plugin(), [new UnusedImport()]);
		Assert.equals(1, b.length);
		Assert.equals('unused-import', b[0].rule);
	}

	/**
	 * A `CHECKSTYLE:OFF` / `CHECKSTYLE:ON` pair silences every finding in the
	 * enclosed region; a finding past `ON` survives.
	 */
	public function testCheckstyleRegion(): Void {
		final src: String = 'package pkg;\n// CHECKSTYLE:OFF\nimport a.b.Unused1;\n// CHECKSTYLE:ON\nimport a.b.Unused2;\nclass C {}';
		final vs: Array<Violation> = Linter.run([{ file: 'pkg/C.hx', source: src }], plugin(), [new UnusedImport()]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('a.b.Unused2'));
	}

	/**
	 * A `noqa` occurring inside a string literal is not a comment and does not
	 * suppress — the string-aware comment scan ignores it.
	 */
	public function testNoqaInStringNotSuppressed(): Void {
		final src: String = 'package pkg;\nclass C {\n\tfunction f() {\n\t\tvar u = "noqa";\n\t}\n}';
		final vs: Array<Violation> = Linter.run([{ file: 'pkg/C.hx', source: src }], plugin(), [new UnusedLocal()]);
		Assert.equals(1, vs.length);
		Assert.equals('unused-local', vs[0].rule);
	}

	/**
	 * `LintFormat.json` emits one record per violation that round-trips
	 * through `haxe.Json.parse` with resolved line/severity/rule.
	 */
	public function testJsonFormat(): Void {
		final src: String = 'package pkg;\nimport a.b.Unused;\nclass C {}';
		final file: String = 'pkg/C.hx';
		final vs: Array<Violation> = new UnusedImport().run([{ file: file, source: src }], plugin());
		Assert.equals(1, vs.length);
		final sourceOf: Map<String, String> = [file => src];
		final parsed: Array<Dynamic> = haxe.Json.parse(LintFormat.json(vs, sourceOf));
		Assert.equals(1, parsed.length);
		final rec: Dynamic = parsed[0];
		Assert.equals(file, rec.file);
		Assert.equals(2, Std.int(rec.line));
		Assert.equals('warning', rec.severity);
		Assert.equals('unused-import', rec.rule);
	}

	/**
	 * `LintFormat.checkstyle` groups findings under a `<file>` element with a
	 * `source="apq.<rule>"` error carrying the resolved line and severity.
	 */
	public function testCheckstyleFormat(): Void {
		final src: String = 'package pkg;\nimport a.b.Unused;\nclass C {}';
		final file: String = 'pkg/C.hx';
		final vs: Array<Violation> = new UnusedImport().run([{ file: file, source: src }], plugin());
		final xml: String = LintFormat.checkstyle(vs, [file => src]);
		Assert.isTrue(xml.contains('<checkstyle'));
		Assert.isTrue(xml.contains('source="apq.unused-import"'));
		Assert.isTrue(xml.contains('severity="warning"'));
		Assert.isTrue(xml.contains('line="2"'));
	}

	/**
	 * XML-special characters in a message are escaped in checkstyle output,
	 * and a null-span violation renders line/column zero.
	 */
	public function testCheckstyleEscapesMessage(): Void {
		final v: Violation = {
			file: 'F.hx',
			span: null,
			rule: 'demo',
			severity: Severity.Warning,
			message: 'a < b & "c"'
		};
		final xml: String = LintFormat.checkstyle([v], ['F.hx' => '']);
		Assert.isTrue(xml.contains('message="a &lt; b &amp; &quot;c&quot;"'));
		Assert.isTrue(xml.contains('line="0"'));
	}

	public function testDropContainedEdits(): Void {
		// `inner` is contained in `outer`; `disjoint` overlaps neither. The
		// container survives, the contained edit is dropped.
		final inner: { span: Span, text: String } = { span: new Span(20, 30), text: '' };
		final outer: { span: Span, text: String } = { span: new Span(10, 50), text: '' };
		final disjoint: { span: Span, text: String } = { span: new Span(60, 70), text: '' };
		final kept: Array<{ span: Span, text: String }> = RefactorSupport.dropContainedEdits([inner, outer, disjoint]);
		final froms: Array<Int> = [for (e in kept) e.span.from];
		Assert.equals(2, kept.length);
		Assert.isTrue(froms.contains(10));
		Assert.isTrue(froms.contains(60));
		Assert.isFalse(froms.contains(20));
	}

	public function testCrossCheckOverlapKeepsOuterDeletion(): Void {
		// A dead run that contains a self-assignment line: `dead-code` and
		// `self-assignment` emit nested deletions. Batching them blindly would corrupt
		// the splice; dropping the contained edit keeps only the outer dead-run delete.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\treturn;\n\t\tvar x = 0;\n\t\tx = x;\n\t}\n}';
		final files = [{ file: 'C.hx', source: src }];
		final edits: Array<{ span: Span, text: String }> = [];
		for (e in new DeadCode().fix(src, new DeadCode().run(files, plugin()), plugin())) edits.push(e);
		for (e in new SelfAssignment().fix(src, new SelfAssignment().run(files, plugin()), plugin())) edits.push(e);
		switch RefactorSupport.canonicalize(src, RefactorSupport.dropContainedEdits(edits), true, plugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('x = x') == -1);
				Assert.isTrue(text.indexOf('var x') == -1);
				Assert.isTrue(text.indexOf('return') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/**
	 * A `using` whose extension method is actually called (`s.trim()` for
	 * `StringTools`) is in use — no finding, where the old check always reported
	 * an `Info`.
	 */
	public function testUsingStringToolsExtensionUsed(): Void {
		final src: String = 'package pkg;\nusing StringTools;\nclass C {\n\tfunction f(s:String):String return s.trim();\n}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: src }], plugin());
		Assert.equals(0, vs.length);
	}

	/**
	 * A `using` referenced via its bound name (`StringTools.fastCodeAt`, a static
	 * call) is in use — the same word-boundary test as a plain import.
	 */
	public function testUsingUsedViaTypeName(): Void {
		final src: String = 'package pkg;\nusing StringTools;\nclass C {\n\tfunction f(s:String):Int return StringTools.fastCodeAt(s, 0);\n}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: src }], plugin());
		Assert.equals(0, vs.length);
	}

	/**
	 * A `using` of a known stdlib module whose bound name is absent and none of
	 * whose extension methods are called is verified-unused → `Warning` (not the
	 * old unverifiable `Info`). `s.toUpperCase()` is a `String` method, not a
	 * `Lambda` one, so it does not keep the `using` alive.
	 */
	public function testUsingLambdaUnusedIsWarning(): Void {
		final src: String = 'package pkg;\nusing Lambda;\nclass C {\n\tfunction f(s:String):String return s.toUpperCase();\n}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: src }], plugin());
		Assert.equals(1, vs.length);
		Assert.equals('unused-import', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('Lambda'));
	}

	/**
	 * The verified-unused `using` `Warning` is auto-fixable — `fix` yields a
	 * single delete edit, like any other unused import.
	 */
	public function testUnusedUsingFixDeletes(): Void {
		final src: String = 'package pkg;\nusing Lambda;\nclass C {\n\tfunction f(s:String):String return s.toUpperCase();\n}';
		final check: UnusedImport = new UnusedImport();
		final vs: Array<Violation> = check.run([{ file: 'pkg/C.hx', source: src }], plugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin());
		Assert.equals(1, edits.length);
		Assert.equals('', edits[0].text);
	}

}
