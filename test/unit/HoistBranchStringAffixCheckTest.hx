package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.HoistBranchStringAffix;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `hoist-branch-string-affix` check: a statement-position conditional-compilation region whose
 * every branch is one `return <string>;` and whose branch strings share text at the same edge is
 * flagged `Info`, and `fix` rewrites it into ONE `return` whose head and tail are written once
 * around the region moved into expression position.
 */
class HoistBranchStringAffixCheckTest extends Test {

	/** The motivating shape (anonymized from `crashdumper.SystemData.summary`): three branches, shared head AND tail. */
	private static inline final REGION: String = 'class C {\n\tpublic function f():String {\n'
		+ '\t\t#if flash\n\t\treturn \'Data$${sep()}{$${sep()}  A: $$a$${sep()}}\';\n'
		+ '\t\t#elseif mobile\n\t\treturn \'Data$${sep()}{$${sep()}  B: $$b$${sep()}}\';\n'
		+ '\t\t#else\n\t\treturn \'Data$${sep()}{$${sep()}  C: $$c$${sep()}}\';\n' + '\t\t#end\n\t}\n}\n';

	/** Two branches sharing only a head — the tail differs, so only one side is hoisted. */
	private static inline final PREFIX_ONLY: String = 'class C {\n\tpublic function f():String {\n'
		+ '\t\t#if a\n\t\treturn \'Hello, $$x!\';\n\t\t#else\n\t\treturn \'Hello, $$y?\';\n\t\t#end\n\t}\n}\n';

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('hoist-branch-string-affix');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'hoist-branch-string-affix is opt-in');
	}

	public function testSharedEdgesFlagged(): Void {
		final vs: Array<Violation> = violations(REGION);
		Assert.equals(1, vs.length);
		Assert.equals('hoist-branch-string-affix', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'every branch of this conditional-compilation region returns a string with the same edges - write the shared text once '
			+ 'outside the region',
			vs[0].message
		);
	}

	/** The rebuilt `return` writes the head and the tail once, with the region moved into expression position. */
	public function testFixHoistsHeadAndTail(): Void {
		final es: Array<{ span: Span, text: String }> = edits(REGION);
		Assert.equals(1, es.length);
		Assert.equals(
			'return \'Data$${sep()}{$${sep()}  \' + #if flash \'A: $$a\' #elseif mobile \'B: $$b\' #else \'C: $$c\' #end + \'$${sep()}}\';',
			es[0].text
		);
	}

	/** The emitted region is a first-class `ConditionalExpr`, so the fixed file re-parses and canonicalizes. */
	public function testFixedSourceCanonicalizes(): Void {
		final fixed: String = applyFixOnce(REGION);
		Assert.isTrue(fixed.indexOf('#if flash') != -1, 'the region survives: $fixed');
		Assert.isTrue(fixed.indexOf('return \'Data') != -1, 'the head is written once: $fixed');
		Assert.equals(1, occurrences(fixed, 'Data'), 'the head text appears once, not once per branch: $fixed');
	}

	/** A side whose shared text does not pay for its own `\'…\' + ` syntax is left alone. */
	public function testHeadOnlyWhenTailDoesNotPay(): Void {
		final es: Array<{ span: Span, text: String }> = edits(PREFIX_ONLY);
		Assert.equals(1, es.length);
		Assert.equals('return \'Hello, \' + #if a \'$$x!\' #else \'$$y?\' #end;', es[0].text);
	}

	/** The cut may fall INSIDE a literal segment when that segment holds no escape and no interpolation sigil. */
	public function testCutInsideAPlainLiteralSegment(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapRegion(
			'return \'connection-alpha\';', 'return \'connection-beta\';'
		));
		Assert.equals(1, es.length);
		Assert.equals('return \'connection-\' + #if a \'alpha\' #else \'beta\' #end;', es[0].text);
	}

	/** A literal segment holding a backslash escape is never cut inside — a safe miss, not a mangled escape. */
	public function testEscapeBearingSegmentNotCut(): Void {
		Assert.equals(0, violations(wrapRegion('return \'ab\\nQtail\';', 'return \'ab\\\\Rtail\';')).length);
	}

	/** Hoisting must SHORTEN the source: two branches sharing five characters do not pay for the quotes and the `+`. */
	public function testTooShortToPayNotFlagged(): Void {
		Assert.equals(0, violations(wrapRegion('return \'code-alpha\';', 'return \'code-beta\';')).length);
	}

	/** Without a final `#else` some build has no `return` at all, so the region cannot move into the value slot. */
	public function testNoElseBranchNotFlagged(): Void {
		final src: String = 'class C {\n\tpublic function f():String {\n'
			+ '\t\t#if a\n\t\treturn \'Hello, $$x!\';\n\t\t#elseif b\n\t\treturn \'Hello, $$y!\';\n\t\t#end\n\t}\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/** A branch holding more than the `return` could bind a local the hoisted text reads — refused, not guessed. */
	public function testMultiStatementBranchNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapRegion('final t = \'x\';\n\t\treturn \'Hello, $$t!\';', 'return \'Hello, y!\';')).length
		);
	}

	/** Branches sharing nothing at either edge have nothing to hoist. */
	public function testNoSharedEdgeNotFlagged(): Void {
		Assert.equals(0, violations(wrapRegion('return \'alpha\';', 'return \'omega\';')).length);
	}

	/** A branch value that is itself a `+` chain keeps its own operators; only the outer edges move. */
	public function testConcatenationChainBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrapRegion(
			'return \'Hello, \' + \'$$x and more\';', 'return \'Hello, \' + \'$$y and less\';'
		));
		Assert.equals(1, es.length);
		Assert.equals(
			'return \'Hello,\' + #if a \' \' + \'$$x and more\' #else \' \' + \'$$y and less\' #end;', es[0].text
		);
	}

	/** A comment in a region the rebuild drops is a safe miss. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapRegion('return /* why */ \'Hello, $$x!\';', 'return \'Hello, $$y?\';')).length
		);
	}

	/** A double-quoted branch string carries no segment children, so there is no modelled cut point. */
	public function testDoubleQuotedBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrapRegion('return "Hello, alpha";', 'return "Hello, omega";')).length);
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	/** A two-branch `#if a / #else` region around `first` and `second`, inside a minimal parseable class. */
	private static inline function wrapRegion(first: String, second: String): String {
		return 'class C {\n\tpublic function f():String {\n\t\t#if a\n\t\t$first\n\t\t#else\n\t\t$second\n\t\t#end\n\t}\n}\n';
	}

	/** How many times `needle` occurs in `text` — the head-written-once assertion. */
	private static function occurrences(text: String, needle: String): Int {
		var count: Int = 0;
		var at: Int = text.indexOf(needle);
		while (at != -1) {
			count++;
			at = text.indexOf(needle, at + needle.length);
		}
		return count;
	}

	private function violations(src: String): Array<Violation> {
		return new HoistBranchStringAffix().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: HoistBranchStringAffix = new HoistBranchStringAffix();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
