package unit.check.common.loops;

import anyparse.check.Check;
import anyparse.check.common.loops.ElementLoopRewrite;
import anyparse.check.common.loops.PreferKeyValueLoop;
import anyparse.check.common.loops.PreferValueLoop;
import anyparse.query.CanonicalEdit;

using StringTools;

/**
 * Both element-loop rules over a PATH receiver (`tree.children`, `this.items`): a path whose last member provably
 * resolves to `Array` is rewritten like a bare collection, every gate holding for each segment of the path; one that
 * resolves to something else is silent, and one whose body re-binds a segment is not reported.
 */
class PathReceiverElementLoopTest extends Test {

	/** The types the fixtures read their paths through. */
	private static inline final SUPPORT: String = '\n\nclass Node {\n\tpublic var kind:String;\n\n\tpublic var label:String;\n\n'
		+ '\tpublic var children:Array<Node> = [];\n\n\tpublic function new() {}\n}\n\n'
		+ 'class Sink {\n\tpublic function new() {}\n\n\tpublic function use(a:Node):Void {}\n}';

	@:pin('control')
	@:killer('M-ELEMENT-LOOP-PATH-MATCH')
	@:killer('M-SINGULAR-CHILDREN')
	public function testParameterPathKeyValueLoopFixed(): Void {
		// the shape of a module-header walk: `i` is read bare too, so the key stays and `child` takes the element
		final src: String = 'class C {\n\tfunction f(tree:Node):Int {\n\t\tvar at:Int = -1;\n\t\tfor (i in 0...tree.children.length) if ('
			+ 'tree.children[i].kind == "x") {\n\t\t\tat = i;\n\t\t}\n\t\treturn at;\n\t}\n}$SUPPORT';
		final vs: Array<Violation> = CheckFixture.violations(new PreferKeyValueLoop(), src);
		Assert.equals(1, vs.length);
		Assert.equals('this indexed loop can be for (i => child in tree.children)', vs[0].message);
		final fixed: String = fixedText(new PreferKeyValueLoop(), src);
		Assert.isTrue(fixed.indexOf('for (i => child in tree.children) if (child.kind == "x")') >= 0, fixed);
		Assert.equals(-1, fixed.indexOf('tree.children[i]'));
	}

	@:pin('control')
	@:killer('M-ELEMENT-LOOP-SELF-OWNER')
	public function testSelfPathValueLoopFixed(): Void {
		final src: String = owned('for (i in 0...this.items.length) sink.use(this.items[i]);');
		Assert.equals(1, CheckFixture.violations(new PreferValueLoop(), src).length);
		Assert.isTrue(fixedText(new PreferValueLoop(), src).indexOf('for (item in this.items) sink.use(item);') >= 0);
	}

	@:pin('control')
	@:killer('M-ELEMENT-LOOP-PATH-PREFIX-REBIND')
	public function testReboundSegmentNotFlagged(): Void {
		final root: String = 'class C {\n\tfunction f(tree:Node, other:Node):Void {\n\t\tfor (i in 0...tree.children.length) {\n'
			+ '\t\t\ttrace(tree.children[i]);\n\t\t\ttree = other;\n\t\t}\n\t}\n}$SUPPORT';
		assertSilent(root);
		assertSilent(owned('for (i in 0...this.items.length) {\n\t\t\ttrace(this.items[i]);\n\t\t\tthis.items = [];\n\t\t}'));
		assertSilent(
			owned('for (i in 0...this.tree.children.length) {\n\t\t\ttrace(this.tree.children[i]);\n\t\t\tthis.tree = null;\n\t\t}')
		);
	}

	@:pin('control')
	@:killer('M-ELEMENT-LOOP-SELF-ALIAS')
	public function testSelfPathReadBareInTheBodyNotFlagged(): Void {
		// `items` is `this.items` spelled another way, so a push through it grows the iterated array
		assertSilent(owned('for (i in 0...this.items.length) {\n\t\t\ttrace(this.items[i]);\n\t\t\titems.push(null);\n\t\t}'));
	}

	@:pin('control')
	@:killer('M-ELEMENT-LOOP-PATH-TYPE')
	public function testStringPathNotFlagged(): Void {
		assertSilent(
			'class C {\n\tfunction f(tree:Node):Void {\n\t\tfor (i in 0...tree.label.length) trace(tree.label[i]);\n\t}\n}$SUPPORT'
		);
	}

	@:pin('control')
	@:killer('M-ELEMENT-LOOP-PATH-REACH')
	public function testBodyGrowingThePathIsReportOnly(): Void {
		final loop: String = 'for (i in 0...tree.children.length) grow(tree.children[i]);';
		final growing: String = owned(loop, '\n\n\tfunction grow(n:Node):Void {\n\t\ttree.children.push(n);\n\t}');
		final check: PreferValueLoop = new PreferValueLoop();
		final vs: Array<Violation> = CheckFixture.violations(check, growing);
		Assert.equals(1, vs.length);
		Assert.equals(
			0, CheckFixture.fixOf(check, growing, vs, QueryTestHelpers.projectPlugin([{ file: 'C.hx', source: growing }])).length
		);
		Assert.isTrue((vs[0].declineReason ?? '').startsWith(ElementLoopRewrite.SELF_CALL_DECLINE));
		final idle: String = owned(loop, '\n\n\tfunction grow(n:Node):Void {}');
		Assert.isTrue(fixedText(new PreferValueLoop(), idle).indexOf('for (child in tree.children) grow(child);') >= 0);
	}

	@:pin('control')
	@:killer('M-SINGULAR-CHILDREN')
	public function testChildrenSingular(): Void {
		Assert.equals('child', ElementLoopRewrite.singularOf('children'));
		Assert.equals('subChild', ElementLoopRewrite.singularOf('subChildren'));
	}

	@:pin('control')
	@:killer('M-ELEMENT-LOOP-ROOT-ASSIGNED')
	public function testRootAssignedInItsScopeIsReportOnly(): Void {
		// a closure made before the loop can re-bind the parameter while the body runs, so any assignment in its scope refuses
		final src: String = 'class C {\n\tfunction f(tree:Node, other:Node):Void {\n\t\tfinal swap:() -> Void = () -> tree = other;\n'
			+ '\t\tfor (i in 0...tree.children.length) {\n\t\t\tswap();\n\t\t\ttrace(tree.children[i]);\n\t\t}\n\t}\n}$SUPPORT';
		final check: PreferValueLoop = new PreferValueLoop();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length);
		Assert.equals(0, CheckFixture.fixOf(check, src, vs, QueryTestHelpers.projectPlugin([{ file: 'C.hx', source: src }])).length);
		Assert.isTrue((vs[0].declineReason ?? '').indexOf('`tree` is assigned in its scope') >= 0);
	}

	@:pin('control')
	@:killer('M-ELEMENT-LOOP-REBIND')
	public function testFieldRootReboundThroughSelfNotFlagged(): Void {
		// `this.tree = …` re-binds the root the header spelled bare, so neither the value nor the key-value form may iterate it
		final rebind: String = '\n\t\t\tthis.tree = new Node();';
		assertSilent(owned('for (i in 0...tree.children.length) {\n\t\t\ttrace(tree.children[i]);$rebind\n\t\t}'));
		final decl: String = 'for (i in 0...tree.children.length) {\n\t\t\tfinal c = tree.children[i];';
		assertSilent(owned('$decl$rebind\n\t\t\tsink.use(c);\n\t\t}'));
		Assert.equals(
			1, CheckFixture.violations(new PreferKeyValueLoop(), owned('$decl\n\t\t\tsink.use(c);\n\t\t\ttrace(i);\n\t\t}')).length
		);
	}

	@:pin('control')
	@:killer('M-ELEMENT-LOOP-SELF-OWNER')
	@:killer('M-ELEMENT-LOOP-PATH-REACH')
	public function testSelfPathInAnAbstractTypedByItsUnderlyingType(): Void {
		// inside `abstract Wrap(Holder)` `this` is the `Holder`, so its members answer the path and the reach gate
		final loop: String = 'for (i in 0...this.items.length) {\n\t\t\ttrace(this.items[i]);';
		final pure: String = wrapped('$loop\n\t\t}');
		Assert.isTrue(
			fixedText(new PreferValueLoop(), pure).indexOf('for (item in this.items) {') >= 0, fixedText(new PreferValueLoop(), pure)
		);
		final growing: String = wrapped('$loop\n\t\t\tthis.grow();\n\t\t}');
		final check: PreferValueLoop = new PreferValueLoop();
		final vs: Array<Violation> = CheckFixture.violations(check, growing);
		Assert.equals(1, vs.length);
		Assert.equals(
			0, CheckFixture.fixOf(check, growing, vs, QueryTestHelpers.projectPlugin([{ file: 'C.hx', source: growing }])).length
		);
	}

	/** `body` in a method of `abstract Wrap(Holder)`, whose `Holder.grow` pushes onto `items`. */
	private function wrapped(body: String): String {
		return 'class Holder {\n\tpublic var items:Array<Int> = [];\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function grow():Void {\n\t\titems.push(1);\n\t}\n}\n\nabstract Wrap(Holder) {\n\tpublic function new(h:Holder)\n'
			+ '\t\tthis = h;\n\n\tpublic function f():Void {\n\t\t$body\n\t}\n}';
	}

	/**
	 * `body` in a method of a class owning `items`, `tree` and `sink` as fields, `members` appended to it, with the
	 * support types declared.
	 */
	private function owned(body: String, members: String = ''): String {
		return 'class C {\n\tfinal items:Array<Node> = [];\n\n\tvar tree:Node = new Node();\n\n\tfinal sink:Sink = new Sink();\n\n'
			+ '\tfunction f():Void {\n\t\t$body\n\t}$members\n}$SUPPORT';
	}

	/** Neither element-loop rule reports `src`. */
	private function assertSilent(src: String): Void {
		Assert.equals(0, CheckFixture.violations(new PreferValueLoop(), src).length);
		Assert.equals(0, CheckFixture.violations(new PreferKeyValueLoop(), src).length);
	}

	/** `src` after `check`'s fix over its findings, canonicalised, as a one-file project's `lint --fix` writes it. */
	private function fixedText(check: Check, src: String): String {
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		final edits: Array<FixEdit> = CheckFixture.fixOf(check, src, vs, QueryTestHelpers.projectPlugin([{ file: 'C.hx', source: src }]));
		return switch CanonicalEdit.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): 'fix canonicalize Err: $message';
		};
	}

}
