package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

/**
 * `unused-import` and DOT-QUALIFIED occurrences: a Haxe import binds a SIMPLE
 * name, while a dotted path (`haxe.macro.Context.currentPos()`) resolves from
 * its ROOT — the tail segments never go through an import. The reference scan
 * must therefore not count an occurrence whose preceding non-whitespace char
 * is a qualification `.`, or a file whose only mentions of the bound name are
 * fully-qualified keeps a dead import forever.
 *
 * The trap the tail test must survive is the range / rest operator: in
 * `for (i in 0...Limit.MAX)` the name IS dot-preceded, but the dot belongs to
 * `...` — treating it as qualification would delete a needed import and break
 * the build. Only a SINGLE dot qualifies.
 */
class LintUnusedImportDottedSliceTest extends Test {

	/**
	 * The reported symptom: every occurrence of the bound name is the tail of a
	 * fully-qualified path, so the import is dead and deletable.
	 */
	public function testFullyQualifiedTailDoesNotKeepImport(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Ctx;\n\nclass C {\n\tpublic function f(): Int return a.b.Ctx.currentPos();\n}';
		final vs: Array<Violation> = run(use);

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('unused import'));
	}

	/** A bare (unqualified) use is what the import is FOR — never flagged. */
	public function testBareUseKeepsImport(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Ctx;\n\nclass C {\n\tpublic function f(c: Ctx): Void {}\n}';

		Assert.equals(0, run(use).length);
	}

	/**
	 * The `...` trap: the name is dot-preceded, but the dot is the tail of the
	 * range operator, not a qualifier — the occurrence is a real bare reference
	 * and the import must survive.
	 */
	public function testRangeOperatorTailIsNotQualification(): Void {
		final use: String =
			'package pkg;\n\nimport a.b.Limit;\n\nclass C {\n\tpublic function f(): Void {\n\t\tfor (i in 0...Limit.MAX) trace(i);\n\t}\n}';

		Assert.equals(0, run(use).length);
	}

	/** The rest-argument spread spells the same three dots and must read the same way. */
	public function testRestSpreadTailIsNotQualification(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Limit;\n\nclass C {\n\tpublic function f(): Void {\n\t\tg(...Limit.all());\n\t}\n}';

		Assert.equals(0, run(use).length);
	}

	/**
	 * A line comment ending in a sentence period puts a `.` directly before the
	 * next line's first token. It qualifies NOTHING — reading it as a qualifier
	 * deletes an import the build needs (found on a real tree, where the call
	 * below sat under a `// … before the process dies.` comment).
	 */
	public function testCommentPeriodIsNotQualification(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Limit;\n\nclass C {\n\tpublic function f(): Void {\n\t\t// Flush the queue first.\n'
			+ '\t\tLimit.drain();\n\t}\n}';

		Assert.equals(0, run(use).length);
	}

	/**
	 * A `//` inside a STRING is not a comment: the qualifier dot after it still
	 * qualifies, so the import stays reported. Pins that the mask comes from the
	 * lexical scan, not a same-line `//` search.
	 */
	public function testSlashesInsideStringDoNotMaskTheQualifier(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Ctx;\n\nclass C {\n\tpublic function f(): Int {\n'
			+ '\t\tfinal u: String = \'http://x\';\n\t\treturn a.b.Ctx.currentPos() + u.length;\n\t}\n}';
		final vs: Array<Violation> = run(use);

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/**
	 * A qualifier dot separated from its name by a newline / indentation still
	 * qualifies — the dot ends the line, the name opens the next, and only the
	 * backward whitespace walk connects them.
	 */
	public function testWhitespaceBetweenDotAndNameStillQualifies(): Void {
		final use: String =
			'package pkg;\n\nimport a.b.Ctx;\n\nclass C {\n\tpublic function f(): Int return a.b.\n\t\tCtx.currentPos();\n}';
		final vs: Array<Violation> = run(use);

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/** Safe navigation is a field access: `o?.Ctx` reads a field, not the imported type. */
	public function testSafeNavFieldAccessIsNotAUse(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Ctx;\n\nclass C {\n\tpublic function f(o: Dynamic): Dynamic return o?.Ctx;\n}';
		final vs: Array<Violation> = run(use);

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/** A field access inside string interpolation is a field access too. */
	public function testInterpolatedFieldAccessIsNotAUse(): Void {
		final use: String =
			'package pkg;\n\nimport a.b.Ctx;\n\nclass C {\n\tpublic function f(o: Dynamic): String return \'$${o.Ctx}\';\n}';
		final vs: Array<Violation> = run(use);

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/** The ROOT of a path is not dot-preceded — `Mod.VALUE` is exactly what the import provides. */
	public function testPathRootStillCountsAsUse(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Mod;\n\nclass C {\n\tpublic var x: Int = Mod.VALUE;\n}';

		Assert.equals(0, run(use).length);
	}

	/** A SECONDARY type of an in-set module keeps the module import only when referenced bare. */
	public function testSecondaryTypeQualifiedTailDoesNotKeepImport(): Void {
		final mod: String = 'package a.b;\n\ntypedef ModExtra = {\n\tvar id: Int;\n}\n\nclass Mod {}';
		final use: String = 'package pkg;\n\nimport a.b.Mod;\n\nclass C {\n\tpublic var x: a.b.Mod.ModExtra;\n}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], new HaxeQueryPlugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/**
	 * The `using` arm asks the same question of its bound name, and its member scan
	 * asks it a second time: `a.b.Limit.MAX` reaches the type through no import at
	 * all, so neither the bound name NOR the `.MAX` occurrence is a use the `using`
	 * enables. With `a.b.Limit` in the lint set its members are known, which makes
	 * this a verified `unused using` — without the receiver exclusion in
	 * `methodCalledInSource` the same `.MAX` would read as an extension call and
	 * silence the finding entirely.
	 */
	public function testUsingBoundNameQualifiedTailIsNotAUse(): Void {
		final use: String = 'package pkg;\n\nusing a.b.Limit;\n\nclass C {\n\tpublic var x: Int = a.b.Limit.MAX;\n}';
		final vs: Array<Violation> = run(use);

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('unused using'));
	}

	/** The static-wildcard arm too: a member reached as `Type.MEMBER` never came through the wildcard. */
	public function testWildcardMemberQualifiedTailDoesNotKeepImport(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Limit.*;\n\nclass C {\n\tpublic var x: Int = a.b.Limit.MAX;\n}';
		final vs: Array<Violation> = run(use);

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('unused wildcard import'));
	}

	/** Run the check over `use` plus the fixed support modules it may import. */
	private static function run(use: String): Array<Violation> {
		final ctx: String = 'package a.b;\n\nclass Ctx {\n\tpublic static function currentPos(): Int return 0;\n}';
		final limit: String = 'package a.b;\n\nclass Limit {\n\tpublic static final MAX: Int = 10;\n}';
		final mod: String = 'package a.b;\n\nclass Mod {\n\tpublic static final VALUE: Int = 1;\n}';
		return new UnusedImport().run([
			{ file: 'a/b/Ctx.hx', source: ctx },
			{ file: 'a/b/Limit.hx', source: limit },
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], new HaxeQueryPlugin());
	}

}
