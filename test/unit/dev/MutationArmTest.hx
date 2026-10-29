package unit.dev;

import dev.MutationArm;
import utest.Assert;
import utest.Test;

/**
 * `dev mutation-arm`'s reading of the registry and the generated pins: each arm's cut as a `hxq patch` payload (a
 * multi-pair cut is ONE payload; a forced value is spliced after the body brace the member's own braces locate), the
 * expectations its pins make, and how the render rows are dealt into batches.
 */
@:nullSafety(Strict)
final class MutationArmTest extends Test {

	private static inline final REGISTRY: String = '{"arms": ['
		+ '{"name": "M-ONE", "type": "a.B", "method": "f", "find": "x", "replace": "y"},'
		+ '{"name": "M-PAIRS", "type": "a.B", "method": "g", "kind": "FinalMember", "find": ["p", "q"], "replace": ["P", "Q"]},'
		+ '{"name": "M-CUT", "type": "a.B", "method": "h", "find": "gone"},'
		+ '{"name": "M-ODD", "type": "a.B", "method": "h", "find": ["p", "q"], "replace": ["P"]},'
		+ '{"name": "M-FORCE", "type": "a.C", "method": "k", "force": "true"}' + ']}';

	public function testEveryArmIsReadInRegistryOrder(): Void {
		Assert.same(['M-ONE', 'M-PAIRS', 'M-CUT', 'M-ODD', 'M-FORCE'], MutationArm.armNames(REGISTRY));
	}

	public function testACutIsOnePayloadWhoseSectionsAlternate(): Void {
		final cuts: Map<String, ArmCut> = MutationArm.cuts(REGISTRY, ['M-ONE', 'M-PAIRS', 'M-CUT', 'M-FORCE'], 'arms.json');
		Assert.same(Find('a.B', 'f', 'FnMember', 'x\n====\ny\n'), cuts['M-ONE'], 'a method unless the record names a kind');
		Assert.same(Find('a.B', 'g', 'FinalMember', 'p\n====\nP\n====\nq\n====\nQ\n'), cuts['M-PAIRS']);
		Assert.same(Find('a.B', 'h', 'FnMember', 'gone\n====\n\n'), cuts['M-CUT'], 'no replace deletes the fragment');
		Assert.same(Force('a.C', 'k', 'FnMember', 'true'), cuts['M-FORCE']);
	}

	public function testAnArmThatCannotBeRenderedSaysWhy(): Void {
		final cuts: Map<String, ArmCut> = MutationArm.cuts(REGISTRY, ['M-ODD', 'M-NONE'], 'arms.json');
		Assert.same(
			Unrenderable('"M-ODD" declares 2 find fragment(s) against 1 replace(s) - a multi-pair cut pairs them up'), cuts['M-ODD']
		);
		Assert.same(Unrenderable('no arm named "M-NONE" in arms.json'), cuts['M-NONE']);
	}

	public function testAForcedReturnGoesAfterTheBodyBrace(): Void {
		final member: String = 'public function f(a: Int): Bool {\n\treturn a > 0;\n}\n';
		final header: Null<String> = MutationArm.forceHeader(member);
		Assert.equals('public function f(a: Int): Bool {\n', header);
		Assert.equals('h {\n====\nh {\n\treturn false;\n', MutationArm.forcePayload('h {\n', 'false'));
	}

	public function testTheBodyBraceIsTheLastOneOpeningAtDepthZero(): Void {
		Assert.equals(
			'function f(): Null<{ a: Int }> {\n', MutationArm.forceHeader('function f(): Null<{ a: Int }> {\n\treturn null;\n}'),
			'a brace of the return type is not the body'
		);
		Assert.equals(
			'function f(): Void {\n',
			MutationArm.forceHeader('function f(): Void {\n\t// a } in a comment\n\tvar s = "}" + \'{\' + ~/[}]/.source; /* } */\n}\n'),
			'braces in a comment, a string, a char and a regex are not code'
		);
	}

	public function testAMemberWhoseBodyCannotBeFoundIsRefused(): Void {
		Assert.isNull(MutationArm.forceHeader('function f(): Int { return 1; }'), 'the body opens mid-line');
		Assert.isNull(MutationArm.forceHeader('function f(): Int {\n\treturn 1;\n'), 'unbalanced');
		Assert.isNull(MutationArm.forceHeader('final x: Int = 1;'), 'no body at all');
	}

	public function testThePinsOfAnArmAreItsTestsAndItsClasses(): Void {
		final pins: PinTables = MutationArm.pinTables([
			'unit.b.BTest#testTwo :: control :: M-X,M-Y',
			'unit.a.ATest#testOne :: control :: M-X',
			'unit.a.ATest#testOne :: control :: M-X',
			'unit.c.CTest#testGuard :: guard :: ',
			'not a pin line'
		].join('\n'));
		Assert.equals('unit.a.ATest.testOne,unit.b.BTest.testTwo', pins.tests['M-X'], 'sorted, each once');
		Assert.equals('unit.a.ATest,unit.b.BTest', pins.classes['M-X']);
		Assert.equals('unit.b.BTest.testTwo', pins.tests['M-Y']);
		Assert.isFalse(pins.tests.exists(''), 'a pin naming no killer names no arm');
	}

	public function testTheBiggestFileIsDealtFirstInChunks(): Void {
		final rows: Array<String> = ['a\t1', 'b\t1', 'b\t2', 'b\t3', 'c\t1'];
		Assert.same([['b\t1', 'b\t2'], ['b\t3', 'c\t1'], ['a\t1']], MutationArm.deal(rows, 3, 2));
		Assert.same([rows.slice(1, 4).concat(['a\t1', 'c\t1'])], MutationArm.deal(rows, 1, 16), 'one batch takes everything');
		Assert.same([], MutationArm.deal([], 4, 16));
	}

}
