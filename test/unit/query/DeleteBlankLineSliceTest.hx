package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.RemoveElement;
import anyparse.query.RemoveMember;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A deletion gives back ONE separator, not none.
 *
 * The deletion span covers the removed declaration's whole line, so a
 * declaration written between two blank lines — which is every member of a
 * writer-canonical type, since the writer blank-separates members — left BOTH
 * of its blank lines behind and the file gained a doubled run where it had a
 * single one. Nothing catches it: the writer re-emits the run verbatim up to
 * its cap of two, so `fmt --list` stays clean, and no check reads blank lines.
 * It compounds through `lint --fix`, which deletes across a whole scope in one
 * run.
 *
 * It is CONFIG-CONDITIONAL, which is why it survived so long: the run only
 * survives under a writer config that permits two consecutive blank lines
 * (`emptyLines.maxAnywhereInFile: 2`, which is this project's own setting). Under
 * the compiled defaults, and under the TM tree's `maxAnywhereInFile: 1`, the writer
 * collapses the run and the broken span is invisible. Every test here therefore
 * threads `KEEPS_TWO_BLANKS` explicitly rather than relying on whatever config the
 * runner happens to discover.
 *
 * The rule these tests pin: the removed region gives back one blank line when
 * it is flanked by one on BOTH sides, and none otherwise. The one-sided case is
 * the dangerous one — consuming there would glue the survivor below into the
 * group above, which the blank line existed to separate.
 */
class DeleteBlankLineSliceTest extends Test {

	/**
	 * This project's own `emptyLines` block, verbatim. Every test threads it, because the
	 * compiled defaults differ from it in two ways that each make a fixture lie.
	 * `maxAnywhereInFile` defaults below 2, so the writer collapses the doubled run and
	 * hides the defect entirely — the TM tree sets 1 and is immune for that reason. And
	 * `classEmptyLines.beginType` / `endType` default to 0, so a type body opens flush
	 * against its first member, and the first / last member cases would then measure a
	 * blank line the writer never emits. A PARTIAL config is no safer than none: the keys
	 * it omits still fall back.
	 */
	private static inline final KEEPS_TWO_BLANKS: String = '{"emptyLines": {"maxAnywhereInFile": 2, "afterBlocks": "remove",'
		+ ' "afterLeftCurly": "keep", "beforeRightCurly": "keep", "classEmptyLines": {"beginType": 1, "endType": 1}}}';

	/**
	 * A cap high enough that the give-back is OBSERVABLE. The project sets
	 * `maxAnywhereInFile: 2`, which clamps both the correct result and the broken one to two
	 * blanks and makes a pre-doubled fixture prove nothing; at 5 the broken run reads 4 and
	 * the correct one 3. `classEmptyLines` is 0 here only to keep the writer from adding
	 * edges the fixture did not ask for — it does NOT stop the writer capping the type-body
	 * edge itself, which is why the first / last member cases cannot use this and say so.
	 */
	private static inline final WRITER_STAYS_OUT: String = '{"emptyLines": {"maxAnywhereInFile": 5, "afterBlocks": "remove",'
		+ ' "afterLeftCurly": "keep", "beforeRightCurly": "keep", "classEmptyLines": {"beginType": 0, "endType": 0}}}';

	/** Flanked both sides: the pair of blanks becomes one. */
	public function testFlankedBothSidesGivesBackOneBlank(): Void {
		final text: String = okMember(
			'class C {\n\n\tpublic function a():Void {}\n\n\tpublic function b():Void {}\n\n\tpublic function c():Void {}\n\n}\n', 'C', 'b'
		);
		Assert.equals(1, blanksBetween(text, 'function a', 'function c'), text);
	}

	/**
	 * Flanked on ONE side only: nothing is consumed. The blank below `b` separates
	 * `c` from the group `a` / `b` belong to; taking it would move `c` INTO that
	 * group, which is a change the deletion was never asked to make.
	 */
	public function testFlankedOneSideKeepsTheBlank(): Void {
		final source: String = 'class C {\n\n\tpublic function f():Void {\n\t\ta();\n\t\tb();\n\n\t\tc();\n\t}\n\n}\n';
		final text: String = okElement(source, 5, 3);
		Assert.equals(1, blanksBetween(text, 'a()', 'c()'), text);
		Assert.isTrue(text.indexOf('b()') == -1, text);
	}

	/**
	 * The MIRROR of the case above: the blank is ABOVE the removed statement, not below.
	 * It exercises the forward scan rejecting rather than the backward one, and the two
	 * scans are separate code — a fix that got one right could still get the other wrong.
	 */
	public function testFlankedOneSideAboveKeepsTheBlank(): Void {
		final source: String = 'class C {\n\n\tpublic function f():Void {\n\t\ta();\n\n\t\tb();\n\t\tc();\n\t}\n\n}\n';
		final text: String = okElement(source, 6, 3);
		Assert.equals(1, blanksBetween(text, 'a()', 'c()'), text);
		Assert.isTrue(text.indexOf('b()') == -1, text);
	}

	/** Flanked by neither: the statements close up with no blank invented. */
	public function testFlankedNeitherSideStaysPacked(): Void {
		final source: String = 'class C {\n\n\tpublic function f():Void {\n\t\ta();\n\t\tb();\n\t\tc();\n\t}\n\n}\n';
		final text: String = okElement(source, 5, 3);
		Assert.equals(0, blanksBetween(text, 'a()', 'c()'), text);
		Assert.isTrue(text.indexOf('b()') == -1, text);
	}

	/** A statement between two blank lines follows the same rule as a member. */
	public function testFlankedStatementGivesBackOneBlank(): Void {
		final source: String = 'class C {\n\n\tpublic function f():Void {\n\t\ta();\n\n\t\tb();\n\n\t\tc();\n\t}\n\n}\n';
		final text: String = okElement(source, 6, 3);
		Assert.equals(1, blanksBetween(text, 'a()', 'c()'), text);
	}

	/**
	 * FIRST member of the type body. This pins the OUTCOME, not the span: the writer caps
	 * the gap under `{` at one blank whatever the cut did — measured, a hand-built two-blank
	 * opening comes back as one under every config reachable here — so the assertion holds
	 * against the fix, against the defect and against an over-consuming fix alike. It is here
	 * because the position is worth a regression guard, and named so nobody mistakes it for
	 * span coverage; that lives in the flanked-both / one / neither tests.
	 */
	public function testFirstMemberLeavesOneBlankUnderTheBrace(): Void {
		final text: String = okMember('class C {\n\n\tpublic function a():Void {}\n\n\tpublic function b():Void {}\n\n}\n', 'C', 'a');
		Assert.equals(1, blanksBetween(text, 'class C', 'function b'), text);
		Assert.isTrue(text.indexOf('function a') == -1, text);
	}

	/**
	 * LAST member, against the closing brace — the same OUTCOME guard as the first-member
	 * case above, and insensitive to the span for the same reason.
	 */
	public function testLastMemberLeavesOneBlankAboveTheBrace(): Void {
		final text: String = okMember('class C {\n\n\tpublic function a():Void {}\n\n\tpublic function b():Void {}\n\n}\n', 'C', 'b');
		Assert.equals(1, blanksBetween(text, 'function a', '}'), text);
		Assert.isTrue(text.indexOf('function b') == -1, text);
	}

	/**
	 * The removed region STARTS at the doc block, so the blank that decides is the one
	 * above the DOC, not the one above the declaration — there is no blank there at all.
	 * A test that measured from the declaration would pass on a broken fix.
	 */
	public function testDocdMemberMeasuresTheBlankAboveTheDoc(): Void {
		final text: String = okMember(
			'class C {\n\n\tpublic function a():Void {}\n\n\t/** Doc of b. */\n\tpublic function b():Void {}\n\n'
			+ '\tpublic function c():Void {}\n\n}\n',
			'C', 'b'
		);
		Assert.equals(1, blanksBetween(text, 'function a', 'function c'), text);
		Assert.isTrue(text.indexOf('Doc of b') == -1, text);
	}

	/** An emptied `#if` region is removed as one node and obeys the same rule. */
	public function testEmptiedConditionalRegionGivesBackOneBlank(): Void {
		final text: String = okMember(
			'class C {\n\n\tpublic function a():Void {}\n\n\t#if mobile\n\tpublic function b():Void {}\n\t#else\n'
			+ '\tpublic function b():Int return 1;\n\t#end\n\n\tpublic function c():Void {}\n\n}\n',
			'C', 'b'
		);
		Assert.equals(1, blanksBetween(text, 'function a', 'function c'), text);
		Assert.isTrue(text.indexOf('#if') == -1, text);
	}

	/**
	 * THREE adjacent members in ONE call. Each target gives back its own separator, so
	 * the run must close to a single blank — not to none (over-consumed, the survivors
	 * glued together) and not to a doubled one (the defect, once per deletion).
	 */
	public function testAdjacentTargetsInOneCallGiveBackOneBlankTotal(): Void {
		final source: String = 'class C {\n\n\tpublic function keep():Void {}\n\n\tpublic function d1():Void {}\n\n'
			+ '\tpublic function d2():Void {}\n\n\tpublic function d3():Void {}\n\n\tpublic function tail():Void {}\n\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final targets: Array<{ node: QueryNode, parent: Null<QueryNode> }> = [];
		RefactorSupport.eachMemberHost(tree, host -> for (child in host.children) if (
			child.name == 'd1' || child.name == 'd2' || child.name == 'd3'
		)
			targets.push({ node: child, parent: host }));
		Assert.equals(3, targets.length);
		switch RefactorSupport.deleteNodes(source, targets, true, plugin, true, KEEPS_TWO_BLANKS) {
			case Ok(text):
				Assert.equals(1, blanksBetween(text, 'function keep', 'function tail'), text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A run that was ALREADY doubled before the deletion stays doubled. Collapsing it
	 * is a different edit and not this one's to make; giving back one separator out of
	 * a doubled pair still leaves a doubled pair once the writer caps the run.
	 */
	public function testPreDoubledRunStaysDoubled(): Void {
		final text: String = okMember(
			'class C {\n\n\tpublic function a():Void {}\n\n\n\tpublic function b():Void {}\n\n\n\tpublic function c():Void {}\n\n}\n', 'C',
			'b', WRITER_STAYS_OUT
		);
		Assert.equals(3, blanksBetween(text, 'function a', 'function c'), text);
	}

	/** The number of blank lines between the line holding `before` and the line holding `after`. */
	private function blanksBetween(text: String, before: String, after: String): Int {
		final lines: Array<String> = text.split('\n');
		var start: Int = -1;
		var end: Int = -1;
		for (i in 0...lines.length) {
			if (start < 0 && lines[i].indexOf(before) >= 0)
				start = i;
			else if (start >= 0 && lines[i].indexOf(after) >= 0) {
				end = i;
				break;
			}
		}
		if (start < 0 || end < 0) return -1;
		var count: Int = 0;
		for (i in start + 1...end) if (lines[i].trim() == '') count++;
		return count;
	}

	/** `removeMember` with the writer canonicalisation on, or a test failure and an empty string. */
	private function okMember(source: String, typeName: String, memberName: String, ?opts: String): String {
		switch RemoveMember.removeMember(source, typeName, memberName, true, new HaxeQueryPlugin(), true, opts ?? KEEPS_TWO_BLANKS) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	/** `removeElement` at a cursor, or a test failure and an empty string. */
	private function okElement(source: String, line: Int, col: Int): String {
		switch RemoveElement.removeElement(source, line, col, true, new HaxeQueryPlugin(), true, KEEPS_TWO_BLANKS) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

}
