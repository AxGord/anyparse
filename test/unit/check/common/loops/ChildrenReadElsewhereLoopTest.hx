package unit.check.common.loops;

import anyparse.check.Check;
import anyparse.check.common.loops.PreferKeyValueLoop;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;

using StringTools;

/** What the key-value rule made of one loop: how many edits its fix wrote, and why it wrote none. */
private typedef LoopOutcome = { edits: Int, reason: String }

/**
 * An indexed loop over a path receiver (`tree.children`) is rewritten when the loop body neither changes nor aliases
 * the array, even though another file reads the same member through a static extension (`n.children.foreach(…)`).
 */
class ChildrenReadElsewhereLoopTest extends Test {

	private static inline final NODE: String = 'class Node {\n\tpublic var kind:String;\n\n\tpublic var children:Array<Node> = [];\n\n'
		+ '\tpublic function new() {}\n}';
	private static inline final LOOP: String = 'class C {\n\tfunction f(tree:Node):Int {\n\t\tvar at:Int = -1;\n\t\tfor (i in 0...tree.children.length) if ('
		+ 'tree.children[i].kind == "x") {\n\t\t\tat = i;\n\t\t}\n\t\treturn at;\n\t}\n}\n\n$NODE';
	private static inline final READER: String = 'using Lambda;\n\nclass Reader {\n\tpublic static function all(n:Node):Bool {\n'
		+ '\t\treturn n.children.foreach(c -> c.kind == "y");\n\t}\n}';

	/** A module that keeps a node's `children` under another name, and grows what it kept. */
	private static inline final KEEPER: String = 'class Keeper {\n\tpublic static var kept:Array<Node> = [];\n\n'
		+ '\tpublic static function keep(n:Node):Void {\n\t\tkept = n.children;\n\t}\n\n'
		+ '\tpublic static function grow():Void {\n\t\tkept.push(new Node());\n\t}\n}';

	/** `LOOP` with a body that also grows an array handed to the function: one the body did not build. */
	private static final WRITING: String = LOOP.replace('f(tree:Node)', 'f(tree:Node, other:Array<Node>)')
		.replace('at = i;', 'at = i;\n\t\t\tother[0] = null;');

	@:pin('control')
	@:killer('M-READING-EXTENSION-KEPT')
	public function testAStaticExtensionReadElsewhereDoesNotWithholdTheFix(): Void {
		final check: PreferKeyValueLoop = new PreferKeyValueLoop();
		final vs: Array<Violation> = CheckFixture.violations(check, WRITING);
		Assert.equals(1, vs.length);
		final plugin: CachingGrammarPlugin = QueryTestHelpers.projectPlugin([{
			file: 'C.hx', source: WRITING
		}, { file: 'Reader.hx', source: READER }]);
		final edits: Array<FixEdit> = CheckFixture.fixOf(check, WRITING, vs, plugin);
		Assert.isTrue(edits.length > 0, vs[0].declineReason ?? 'no decline reason');
		final fixed: String = switch CanonicalEdit.canonicalize(WRITING, edits, true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): 'fix canonicalize Err: $message';
		};
		Assert.isTrue(fixed.indexOf('for (i => child in tree.children) if (child.kind == "x")') >= 0, fixed);
	}

	@:pin('control')
	@:killer('M-READING-EXTENSION-NEEDS-USING')
	public function testAnExtensionWithNoUsingOfItsModuleStaysAnEscape(): Void {
		final reader: String = READER.replace('using Lambda;\n\n', '');
		Assert.equals(0, fixEdits([{ file: 'Reader.hx', source: reader }]));
	}

	@:pin('control')
	@:killer('M-READING-EXTENSION-CONFLICT')
	public function testAnotherUsingSupplyingTheNameStaysAnEscape(): Void {
		final ext: String = 'class Keep {\n\tpublic static function foreach<T>(a:Array<T>, f:T->Bool):Bool {\n\t\tstash = a;\n'
			+ '\t\treturn true;\n\t}\n\n\tpublic static var stash:Array<Dynamic>;\n}';
		final reader: String = READER.replace('using Lambda;', 'using Lambda;\nusing Keep;');
		Assert.equals(0, fixEdits([{ file: 'Reader.hx', source: reader }, { file: 'Keep.hx', source: ext }]));
	}

	@:pin('control')
	@:killer('M-READING-EXTENSION-SHADOW')
	public function testAProjectTypeDisplacingTheModuleStaysAnEscape(): Void {
		final own: String = 'class Lambda {\n\tpublic static function exists(a:Array<Node>):Bool return false;\n}';
		Assert.equals(0, fixEdits([{ file: 'Reader.hx', source: READER }, { file: 'Lambda.hx', source: own }]));
	}

	@:pin('control')
	@:killer('M-READING-EXTENSION-UNLISTED')
	public function testAnExtensionTheGrammarDoesNotListStaysAnEscape(): Void {
		final reader: String = READER.replace('foreach', 'keepAll');
		Assert.equals(0, fixEdits([{ file: 'Reader.hx', source: reader }]));
	}

	@:pin('control')
	@:killer('M-SHARED-MEMBER-REGION-ASKED')
	public function testASharedArrayMemberIsRewrittenWhenTheBodyChangesNoArray(): Void {
		final got: LoopOutcome = outcome(LOOP, [{ file: 'Keeper.hx', source: KEEPER }]);
		Assert.isTrue(got.edits > 0, got.reason);
	}

	@:pin('control')
	@:killer('M-SHARED-MEMBER-REGION-CULPRIT')
	public function testASharedArrayMemberStaysWhenTheBodyGrowsAnArrayItDidNotBuild(): Void {
		// nothing shares the member: `other` is no alias of it, and the loop is rewritten
		Assert.isTrue(outcome(WRITING, []).edits > 0);
		final got: LoopOutcome = outcome(WRITING, [{ file: 'Keeper.hx', source: KEEPER }]);
		Assert.equals(0, got.edits);
		Assert.isTrue(got.reason.indexOf('may change it') >= 0, got.reason);
	}

	@:pin('control')
	@:killer('M-SHARED-MEMBER-REGION-REACH')
	public function testASharedArrayMemberStaysWhenTheBodyCallsCodeThatGrowsAnArray(): Void {
		final loop: String = LOOP.replace('at = i;', 'at = i;\n\t\t\tKeeper.grow();');
		final got: LoopOutcome = outcome(loop, [{ file: 'Keeper.hx', source: KEEPER }]);
		Assert.equals(0, got.edits);
		Assert.isTrue(got.reason.indexOf('may change it') >= 0, got.reason);
	}

	/**
	 * How many edits the key-value rule's fix makes over the loop whose body grows an array it did not build, in a project
	 * holding it and `others`: none where one of them shares the member.
	 */
	private function fixEdits(others: Array<{ file: String, source: String }>): Int {
		return outcome(WRITING, others).edits;
	}

	/** How many edits the key-value rule's fix makes over `loop`, in a project holding it and `others`, and why it made none. */
	private function outcome(loop: String, others: Array<{ file: String, source: String }>): LoopOutcome {
		final check: PreferKeyValueLoop = new PreferKeyValueLoop();
		final vs: Array<Violation> = CheckFixture.violations(check, loop);
		Assert.equals(1, vs.length);
		final plugin: CachingGrammarPlugin = QueryTestHelpers.projectPlugin([{ file: 'C.hx', source: loop }].concat(others));
		final edits: Int = CheckFixture.fixOf(check, loop, vs, plugin).length;
		return { edits: edits, reason: vs[0].declineReason ?? '' };
	}

}
