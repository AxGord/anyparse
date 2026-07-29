package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.ShortenTypeRef;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.runtime.Span;

/**
 * The `shorten-type-ref` check: a DOTTED type reference in a local `var` / `final` annotation
 * the file itself spells differently. Covers the `pack.SubType` HYBRID repair (to the short
 * name with the import present, to the module-qualified path without it), plain
 * over-qualification, the shadowed path left alone, the index proof degrading a run to
 * report-only, the per-type-parameter proof, the `#if` and multi-declarator refusals, and
 * idempotency.
 */
class ShortenTypeRefCheckTest extends Test {

	// --- ARM 1: the pack.SubType hybrid ---

	public function testHybridRepairedToTheImportedShortName(): Void {
		final src: String = consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub');
		Assert.equals('\t\tfinal v:Sub = g();', annotationLine(applyFix(src)));
	}

	public function testHybridIsFixableNotReportOnly(): Void {
		final vs: Array<Violation> = violations(consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub'));
		Assert.equals(1, vs.length);
		Assert.equals('shorten-type-ref', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('report-only') == -1, 'proven, got: ${vs[0].message}');
	}

	public function testViolationSpanIsTheAnnotationOnly(): Void {
		final src: String = consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub');
		final vs: Array<Violation> = violations(src);
		Assert.equals('pkg.deep.Sub', src.substring(vs[0].span.from, vs[0].span.to));
	}

	/**
	 * The whole point of the rule: with the import GONE the hybrid no longer resolves, so the
	 * repair is the module-qualified path — never the short name (nothing binds it here) and
	 * never a fresh import.
	 */
	public function testHybridWithoutTheImportBecomesModuleQualified(): Void {
		final out: String = applyFix(consumer('', 'pkg.deep.Sub'));
		Assert.equals('\t\tfinal v:pkg.deep.Mod.Sub = g();', annotationLine(out));
		Assert.equals(0, occurrences(out, 'import '), 'the rule never adds an import');
	}

	// --- ARM 2: plain over-qualification ---

	public function testImportedMainTypeShortens(): Void {
		Assert.equals('\t\tfinal v:Foo = g();', annotationLine(applyFix(consumer('import pkg.deep.Foo;\n\n', 'pkg.deep.Foo'))));
	}

	public function testSamePackageMainTypeShortens(): Void {
		final src: String = 'package pkg.deep;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tfinal v:pkg.deep.Foo = g();\n\t}\n\n}\n';
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/deep/C.hx', source: src }];
		Assert.equals('\t\tfinal v:Foo = g();', annotationLine(applyFixWith(src, scopedPlugin(report), report)));
	}

	public function testShadowedShortNameKeepsTheQualifiedPath(): Void {
		// A bare `Foo` here means `other.Foo`; shortening would silently rebind the annotation.
		Assert.equals(0, violations(consumer('import other.Foo;\n\n', 'pkg.deep.Foo')).length);
	}

	public function testAlreadyShortAnnotationIsNotFlagged(): Void {
		Assert.equals(0, violations(consumer('import pkg.deep.Foo;\n\n', 'Foo')).length);
	}

	// --- the index proof ---

	public function testWithoutAResolutionIndexTheRunIsReportOnly(): Void {
		final src: String = consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub');
		final check: ShortenTypeRef = new ShortenTypeRef();
		// A bare plugin carries no resolution scope, so nothing PROVES which declaration
		// `pkg.deep.Sub` names — the finding stands, the rewrite does not.
		final vs: Array<Violation> = check.run([{ file: 'app/C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length, 'an unproven finding yields no edit');
	}

	// --- type parameters ---

	public function testTypeParameterShortens(): Void {
		Assert.equals(
			'\t\tfinal v:Array<Sub> = g();', annotationLine(applyFix(consumer('import pkg.deep.Mod.Sub;\n\n', 'Array<pkg.deep.Sub>')))
		);
	}

	/**
	 * One unproven component makes the WHOLE annotation report-only — `Sub` is indexed and
	 * `Foo` is not, so the annotation is never half-rewritten. The sibling test above, whose
	 * only changed run is the proven `Sub`, is what discriminates this from a blanket refusal.
	 */
	public function testOneUnprovenComponentBlocksTheWholeAnnotation(): Void {
		final src: String = consumer('import pkg.deep.Mod.Sub;\nimport pkg.deep.Foo;\n\n', 'Map<pkg.deep.Sub, pkg.deep.Foo>');
		final report: Array<{ file: String, source: String }> = [{ file: 'app/C.hx', source: src }];
		final check: ShortenTypeRef = new ShortenTypeRef();
		// Only `pkg/deep/Mod.hx` joins the scope, so `pkg.deep.Foo` resolves to no declaration.
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {report: report, library: new LibrarySources([{ file: 'pkg/deep/Mod.hx', source: MOD_SOURCE }]) }
		});
		final vs: Array<Violation> = check.run(report, scoped);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
		Assert.equals(0, check.fix(src, vs, scoped).length);
	}

	// --- refusals ---

	public function testConditionalRegionIsSkipped(): Void {
		final src: String =
			'package app;\n\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tpublic function f():Void {\n\t\t#if debug\n\t\tfinal v:pkg.deep.Sub = g();\n\t\t#end\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	public function testMultiDeclaratorStatementIsRefused(): Void {
		// The grammar projects `var a:T, b = null;` as ONE node; the annotation slice would span
		// both declarators, so a depth-0 comma refuses the whole region.
		final src: String =
			'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tvar a:pkg.deep.Foo, b = null;\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	public function testAnnotationWithoutAnInitializerShortens(): Void {
		final src: String =
			'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tvar v:pkg.deep.Foo;\n\t}\n\n}\n';
		Assert.isTrue(applyFix(src).indexOf('var v:Foo;') != -1, 'shortened, got: ${applyFix(src)}');
	}

	public function testUnannotatedLocalIsNotFlagged(): Void {
		final src: String =
			'package app;\n\nimport pkg.deep.Foo;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tfinal v = g();\n\t}\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	// --- idempotency ---

	public function testFixIsIdempotent(): Void {
		final once: String = applyFix(consumer('import pkg.deep.Mod.Sub;\n\n', 'pkg.deep.Sub'));
		Assert.equals(0, violations(once).length, 'the rewritten source is already canonical');
		Assert.equals(once, applyFix(once));
	}

	public function testQualifiedRepairIsIdempotent(): Void {
		final once: String = applyFix(consumer('', 'pkg.deep.Sub'));
		Assert.equals(0, violations(once).length);
		Assert.equals(once, applyFix(once));
	}

	// --- registration ---

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('shorten-type-ref'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('shorten-type-ref'));
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new ShortenTypeRef() is DefaultOff);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new ShortenTypeRef().run([{ file: 'C.hx', source: 'class Bad { function f() { final v:' }], new HaxeQueryPlugin()).length
		);
	}

	// --- helpers -------------------------------------------------------------------

	/** The library module carrying a MAIN type `Mod` and a SECONDARY type `Sub` — the hybrid's subject. */
	private static inline final MOD_SOURCE: String = 'package pkg.deep;\n\nclass Mod {}\n\ntypedef Sub = Int;\n';

	/** A second library module whose main type `Foo` is the plain over-qualification subject. */
	private static inline final FOO_SOURCE: String = 'package pkg.deep;\n\nclass Foo {}\n';

	/** A same-simple-name type in ANOTHER package — the shadow that keeps a qualified path qualified. */
	private static inline final OTHER_FOO_SOURCE: String = 'package other;\n\nclass Foo {}\n';

	/** A consumer in `package app;` carrying `imports` verbatim and one local annotated `annotation`. */
	private function consumer(imports: String, annotation: String): String {
		return 'package app;\n\n${imports}class C {\n\n\tpublic function f():Void {\n\t\tfinal v:$annotation = g();\n\t}\n\n}\n';
	}

	/** The declaration line of the local named `v`, for an exact whole-line assertion. */
	private function annotationLine(source: String): String {
		for (line in source.split('\n')) {
			final trimmed: String = StringTools.trim(line);
			if (trimmed.indexOf('final v') == 0 || trimmed.indexOf('var v') == 0) return line;
		}
		return source;
	}

	private function scopedPlugin(report: Array<{ file: String, source: String }>): CachingGrammarPlugin {
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				library: new LibrarySources([
					{ file: 'pkg/deep/Mod.hx', source: MOD_SOURCE },
					{ file: 'pkg/deep/Foo.hx', source: FOO_SOURCE },
					{ file: 'other/Foo.hx', source: OTHER_FOO_SOURCE }
				])
			}
		});
		return scoped;
	}

	private function violations(src: String): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'app/C.hx', source: src }];
		return new ShortenTypeRef().run(report, scopedPlugin(report));
	}

	private function applyFix(src: String): String {
		final report: Array<{ file: String, source: String }> = [{ file: 'app/C.hx', source: src }];
		return applyFixWith(src, scopedPlugin(report), report);
	}

	private function applyFixWith(src: String, plugin: CachingGrammarPlugin, report: Array<{ file: String, source: String }>): String {
		final check: ShortenTypeRef = new ShortenTypeRef();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run(report, plugin), plugin);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	private function occurrences(haystack: String, needle: String): Int {
		var count: Int = 0;
		var i: Int = haystack.indexOf(needle);
		while (i >= 0) {
			count++;
			i = haystack.indexOf(needle, i + needle.length);
		}
		return count;
	}

}
