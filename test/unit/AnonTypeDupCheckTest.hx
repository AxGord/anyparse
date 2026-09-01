package unit;

import anyparse.check.AnonTypeDup;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `anon-type-dup` check: an anonymous structure TYPE written out three or
 * more times across the lint scope is flagged `Info` once, at its
 * scope-earliest occurrence. Report-only — the typedef's NAME is intent a human
 * supplies — and OFF by default, like every new rule.
 *
 * The load-bearing property is that the grouping key is STRUCTURAL: two field
 * orders are the SAME Haxe type and must group, while two different field TYPES
 * under the same names must NOT — the second is only expressible because the
 * query tree now carries anon field types.
 */
class AnonTypeDupCheckTest extends Test {

	private static inline final SHAPE: String = 'class C { var a:{ xml:Xml, text:String }; }';

	public function testThreeOccurrencesFlaggedOnce(): Void {
		final vs: Array<Violation> = violations([SHAPE, SHAPE, SHAPE]);
		Assert.equals(1, vs.length);
		Assert.equals('anon-type-dup', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('a0.hx', vs[0].file);
		Assert.isTrue(vs[0].message.contains('written 3 times across 3 files'), vs[0].message);
	}

	public function testTwoOccurrencesBelowThreshold(): Void {
		Assert.equals(0, violations([SHAPE, SHAPE]).length);
	}

	/**
	 * The discriminating case for the whole slice: same field NAMES, different
	 * field TYPES. Before the anon field types reached the query tree these six
	 * occurrences were one group of six; they must be two groups of three.
	 */
	public function testDifferentFieldTypesDoNotGroup(): Void {
		final other: String = 'class C { var a:{ xml:Int, text:Int }; }';
		final vs: Array<Violation> = violations([SHAPE, SHAPE, other, other]);
		Assert.equals(0, vs.length, 'two occurrences each — neither group reaches the threshold');

		final six: Array<Violation> = violations([SHAPE, SHAPE, SHAPE, other, other, other]);
		Assert.equals(2, six.length, 'two DISTINCT shapes, each flagged once');
		Assert.isTrue(six[0].message.contains('{ xml:Xml, text:String }'), six[0].message);
		Assert.isTrue(six[1].message.contains('{ xml:Int, text:Int }'), six[1].message);
	}

	/** Field ORDER is not part of a Haxe structural type, so the two spellings are one group. */
	public function testFieldOrderIsNormalised(): Void {
		final reordered: String = 'class C { var a:{ text:String, xml:Xml }; }';
		final vs: Array<Violation> = violations([SHAPE, reordered, SHAPE]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('written 3 times'), vs[0].message);
		// The message quotes the ANCHOR's own source spelling; normalisation is what
		// GROUPED the reordered occurrence with it, not what the report prints.
		Assert.isTrue(vs[0].message.contains('{ xml:Xml, text:String }'), vs[0].message);
	}

	/** Optionality IS part of the type — `?x:Int` and `x:Int` are different structures. */
	public function testOptionalFieldIsPartOfTheKey(): Void {
		final optional: String = 'class C { var a:{ ?xml:Xml, text:String }; }';
		Assert.equals(0, violations([SHAPE, SHAPE, optional]).length);
		final vs: Array<Violation> = violations([optional, optional, optional]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('{ ?xml:Xml, text:String }'), vs[0].message);
	}

	/** A `typedef`'s own body is the naming TARGET, never one of the duplicates. */
	public function testTypedefBodyIsNotAnOccurrence(): Void {
		final decl: String = 'typedef T = { xml:Xml, text:String }';
		Assert.equals(0, violations([decl, decl, decl]).length);
		Assert.equals(0, violations([decl, SHAPE, SHAPE]).length, 'the two inline uses are still only two');
		Assert.equals(1, violations([decl, SHAPE, SHAPE, SHAPE]).length);
	}

	/** A single-field structure is below `minFields` — naming it would flood the report. */
	public function testSingleFieldStructureIgnored(): Void {
		final one: String = 'class C { var a:{ xml:Xml }; }';
		Assert.equals(0, violations([one, one, one]).length);
	}

	/**
	 * A structure carrying a member this rule cannot key structurally — a
	 * `> Base` extension, a class-notation `var` field — is skipped whole rather
	 * than keyed approximately, which would group two different types.
	 */
	public function testUnkeyableMembersSkipTheWholeStructure(): Void {
		final extend: String = 'typedef T = { > Base, xml:Xml, text:String }\nclass C { var a:{ > Base, xml:Xml, text:String }; }';
		Assert.equals(0, violations([extend, extend, extend]).length);
		final varForm: String = 'class C { var a:{ var xml:Xml; var text:String; }; }';
		Assert.equals(0, violations([varForm, varForm, varForm]).length);
	}

	/** Nested structures are reduced by the same function, so an inner shape difference splits the group. */
	public function testNestedStructureIsPartOfTheKey(): Void {
		final inner: String = 'class C { var a:{ p:{ q:Int }, r:Bool }; }';
		final innerB: String = 'class C { var a:{ p:{ q:String }, r:Bool }; }';
		Assert.equals(0, violations([inner, inner, innerB]).length);
		final vs: Array<Violation> = violations([inner, inner, inner]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('{ p:{ q:Int }, r:Bool }'), vs[0].message);
	}

	/** A parameterised field type is rendered head-and-arguments, so two argument lists split. */
	public function testTypeArgumentsArePartOfTheKey(): Void {
		final ab: String = 'class C { var a:{ m:Map<A, B>, n:Int }; }';
		final ba: String = 'class C { var a:{ m:Map<B, A>, n:Int }; }';
		Assert.equals(0, violations([ab, ab, ba]).length);
		final vs: Array<Violation> = violations([ab, ab, ab]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('{ m:Map<A, B>, n:Int }'), vs[0].message);
	}

	/**
	 * Grouping is CROSS-FILE by design: a shape spread over a package is exactly
	 * the one worth naming. The flip side, stated as a test so nobody reads a
	 * single-file zero as a gate refusing: three occurrences in ONE file report,
	 * and the same shape linted one file at a time reports nothing.
	 */
	public function testScopeDecidesTheCount(): Void {
		final threeInOne: String =
			'class C { var a:{ xml:Xml, text:String }; var b:{ xml:Xml, text:String }; var c:{ xml:Xml, text:String }; }';
		final vs: Array<Violation> = violations([threeInOne]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('written 3 times in this file'), vs[0].message);
		Assert.equals(0, violations([SHAPE]).length, 'one occurrence per file, linted alone, is not a duplicate');
	}

	public function testRegisteredInBuiltinsAndOffByDefault(): Void {
		Assert.equals(177, Linter.builtins().length);
		Assert.notNull(Linter.byId('anon-type-dup'));
		final files: Array<{ file: String, source: String }> = [for (i in 0...3) { file: 'a$i.hx', source: SHAPE }];
		final config: LintConfig = LintConfig.parse('{}');
		final off: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> config, true);
		Assert.equals(0, off.filter(v -> v.rule == 'anon-type-dup').length, 'a new rule is OFF until a project opts in');
		final on: LintConfig = LintConfig.parse('{"rules": {"anon-type-dup": {"enabled": true}}}');
		final reported: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> on, true);
		Assert.equals(1, reported.filter(v -> v.rule == 'anon-type-dup').length, 'and ON once the project opts in');
	}

	/**
	 * The message quotes SOURCE, so a nested generic reads as written. The
	 * structural key flattens it (`Array`, `Array`, `InteractiveObject`), which
	 * would spell the nonexistent `Array<Array, InteractiveObject>` if the report
	 * rendered the key.
	 */
	public function testNestedGenericIsQuotedFromSource(): Void {
		final nested: String = 'class C { var a:{\n\tactions:Array<Array<Obj>>,\n\tobject:Obj\n}; }';
		final vs: Array<Violation> = violations([nested, nested, nested]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('{ actions:Array<Array<Obj>>, object:Obj }'), vs[0].message);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations(['class Bad { function f() { ']).length);
	}

	/** No autofix — the typedef's name is a human's choice. */
	public function testNoFixEdits(): Void {
		final vs: Array<Violation> = violations([SHAPE, SHAPE, SHAPE]);
		Assert.equals(0, new AnonTypeDup().fix(SHAPE, vs, new HaxeQueryPlugin()).length);
	}

	private function violations(sources: Array<String>): Array<Violation> {
		return new AnonTypeDup().run([for (i in 0...sources.length) { file: 'a$i.hx', source: sources[i] }], new HaxeQueryPlugin());
	}

}
