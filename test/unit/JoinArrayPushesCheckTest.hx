package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.JoinArrayPushes;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `join-array-pushes` check: an empty-array binding followed by a run of `a.push(e);`
 * statements is an array literal written the long way. Path A folds a run in the SAME statement
 * list; Path B folds a constructor run into an INSTANCE FIELD's declaration initializer, which
 * crosses the prologue and therefore carries the purity / context-freedom / reachability gates.
 */
class JoinArrayPushesCheckTest extends Test {

	// --- Path A: a fresh local declaration, nothing moves ---

	public function testLocalDeclarationRunFlagged(): Void {
		assertSoleFinding(violations(fn('final a:Array<Int> = [];\n\t\ta.push(1);\n\t\ta.push(2);\n\t\treturn a;')));
	}

	public function testLocalDeclarationRunFixed(): Void {
		Assert.equals(
			fn('final a:Array<Int> = [1, 2];\n\t\treturn a;'),
			applyFix(fn('final a:Array<Int> = [];\n\t\ta.push(1);\n\t\ta.push(2);\n\t\treturn a;'))
		);
	}

	/**
	 * GATE: an ASSIGNMENT to an existing name is not a binding. The assignment RUNS, and folding
	 * moves every element ahead of it — an element reading the name indirectly would see the
	 * pre-assignment value, and a property target would see one setter call instead of two.
	 */
	public function testAssignmentFormNotFlagged(): Void {
		Assert.equals(0, violations(field('_a = [];\n\t\t_a.push(1);\n\t\t_a.push(2);\n\t\tuse(_a);')).length);
	}

	/**
	 * GATE: the binding's annotation must name an ARRAY. A user `abstract` over `Array<T>` may
	 * declare a `push` that PREPENDS, in which case two pushes are not the literal of those two
	 * elements in that order.
	 */
	public function testAbstractTypedReceiverNotFlagged(): Void {
		Assert.equals(0, violations(fn('final s:Stack<Int> = [];\n\t\ts.push(1);\n\t\ts.push(2);\n\t\treturn s;')).length);
	}

	/** An UNANNOTATED `= []` infers the array type from the literal and needs no proof. */
	public function testUnannotatedDeclarationFolded(): Void {
		Assert.equals(fn('final a = [1, 2];\n\t\treturn a;'), applyFix(fn('final a = [];\n\t\ta.push(1);\n\t\ta.push(2);\n\t\treturn a;')));
	}

	/** GATE: a trailing comment on the LAST push would re-attach to the surviving declaration. */
	public function testTrailingCommentOnLastPushNotFlagged(): Void {
		Assert.equals(0, violations(fn('final a:Array<Int> = [];\n\t\ta.push(1); // keep this note\n\t\treturn a;')).length);
	}

	/** A `#if` region projects as ONE statement of its own kind, so it breaks the run at its head. */
	public function testConditionalRegionBreaksTheRun(): Void {
		Assert.equals(
			0, violations(fn('final a:Array<Int> = [];\n\t\t#if js\n\t\ta.push(1);\n\t\t#end\n\t\ta.push(2);\n\t\treturn a;')).length
		);
	}

	/** A declaration and run written entirely INSIDE a `#if` are not a statement list this check walks. */
	public function testDeclarationAndRunInsideConditionalNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('#if js\n\t\tfinal b:Array<Int> = [];\n\t\tb.push(1);\n\t\ttrace(b);\n\t\t#end\n\t\treturn xs;')).length
		);
	}

	/** A single push is still a literal written the long way. */
	public function testSinglePushFlagged(): Void {
		Assert.equals(1, violations(fn('final a:Array<Int> = [];\n\t\ta.push(1);\n\t\treturn a;')).length);
	}

	/**
	 * Nothing moves on Path A, so an element with an EFFECT is fine: `new T()` and `f()` still run
	 * in that order, in that place. The same elements are refused on Path B, where they would
	 * cross the constructor prologue.
	 */
	public function testImpureElementsFoldOnPathA(): Void {
		Assert.equals(
			fn('final a:Array<Int> = [new T(), f()];\n\t\treturn a;'),
			applyFix(fn('final a:Array<Int> = [];\n\t\ta.push(new T());\n\t\ta.push(f());\n\t\treturn a;'))
		);
	}

	/** The run is MAXIMAL: it ends at the first statement that is not a push on the same name. */
	public function testRunStopsAtForeignStatement(): Void {
		Assert.equals(
			fn('final a:Array<Int> = [1];\n\t\ttrace(a);\n\t\ta.push(2);\n\t\treturn a;'),
			applyFix(fn('final a:Array<Int> = [];\n\t\ta.push(1);\n\t\ttrace(a);\n\t\ta.push(2);\n\t\treturn a;'))
		);
	}

	// --- Path A negatives ---

	/** GATE: no comment in the folded region — the pushes are deleted, so the note would be lost. */
	public function testCommentInsideRunNotFlagged(): Void {
		Assert.equals(0, violations(fn('final a:Array<Int> = [];\n\t\ta.push(1);\n\t\t// note\n\t\ta.push(2);\n\t\treturn a;')).length);
	}

	/** GATE: strict adjacency — a foreign statement between the binding and the push breaks the run. */
	public function testNonAdjacentPushNotFlagged(): Void {
		Assert.equals(0, violations(fn('final a:Array<Int> = [];\n\t\ttrace(0);\n\t\ta.push(1);\n\t\treturn a;')).length);
	}

	/** GATE: no self-reference — the element would read the array being built. */
	public function testSelfReferencingElementNotFlagged(): Void {
		Assert.equals(0, violations(fn('final a:Array<Int> = [];\n\t\ta.push(a.length);\n\t\treturn a;')).length);
	}

	/** GATE: the same, spelled as a `$a` string interpolation — a read the tree hides in a leaf kind. */
	public function testInterpolatedSelfReferenceNotFlagged(): Void {
		Assert.equals(0, violations(fn("final a:Array<String> = [];\n\t\ta.push('$a');\n\t\treturn a;")).length);
	}

	/** GATE: the array must be read after the run, else it feeds no one (`unused-local`'s territory). */
	public function testUnreadArrayNotFlagged(): Void {
		Assert.equals(0, violations(fn('final a:Array<Int> = [];\n\t\ta.push(1);\n\t\treturn xs;')).length);
	}

	/** A non-empty literal is already the shape this rule produces; `new Array()` is `prefer-array-literal`'s. */
	public function testNonEmptyInitializerNotFlagged(): Void {
		Assert.equals(0, violations(fn('final a:Array<Int> = [0];\n\t\ta.push(1);\n\t\treturn a;')).length);
		Assert.equals(0, violations(fn('final a:Array<Int> = new Array();\n\t\ta.push(1);\n\t\treturn a;')).length);
	}

	/** A push on a DIFFERENT name is not part of the run. */
	public function testForeignReceiverNotFolded(): Void {
		Assert.equals(0, violations(fn('final a:Array<Int> = [];\n\t\tb.push(1);\n\t\treturn a;')).length);
	}

	// --- Path B: the field declaration, across the constructor prologue ---

	/**
	 * The `TextOptions` site the rule was written for: a `final` field initialised `[]`, a
	 * constructor that calls `super()`, and a run of object-literal pushes after it.
	 */
	public function testMotivatingFieldSiteFlagged(): Void {
		assertSoleFinding(violations(motivating()));
	}

	public function testMotivatingFieldSiteFixed(): Void {
		Assert.equals(motivatingFolded(), applyFix(motivating()));
	}

	/** A `this.`-qualified receiver names the same field and folds identically. */
	public function testQualifiedReceiverFolded(): Void {
		Assert.equals(
			ctor('private final _d:Array<Int> = [1, 2];', 'super();\n\t\tuse(_d);'),
			applyFix(ctor('private final _d:Array<Int> = [];', 'super();\n\t\tthis._d.push(1);\n\t\tthis._d.push(2);\n\t\tuse(_d);'))
		);
	}

	/** A non-`override` member reading the field is no hazard — only a virtual call from the base is. */
	public function testPlainMemberReaderStillFolded(): Void {
		final src: String = ctor('private final _d:Array<Int> = [];', 'super();\n\t\t_d.push(1);');
		Assert.equals(1, violations(withMember(src, 'public function read():Array<Int> {\n\t\treturn _d;\n\t}')).length);
	}

	/** A run mixing both receiver spellings is ONE run: they name the same field. */
	public function testMixedReceiverSpellingsFolded(): Void {
		Assert.equals(
			ctor('private final _d:Array<Int> = [1, 2];', 'super();\n\t\tuse(_d);'),
			applyFix(ctor('private final _d:Array<Int> = [];', 'super();\n\t\tthis._d.push(1);\n\t\t_d.push(2);\n\t\tuse(_d);'))
		);
	}

	/**
	 * A field declared BELOW the constructor still folds when something genuinely reads it — the
	 * read-after gate excludes only the declaration itself, it does not refuse the position.
	 */
	public function testFieldDeclaredAfterConstructorStillFolded(): Void {
		final src: String = 'class C extends B {\n\tpublic function new(n:Int) {\n\t\tsuper();\n\t\t_d.push(1);\n\t}\n'
			+ '\tprivate final _d:Array<Int> = [];\n}';
		Assert.equals(1, violations(withMember(src, 'public function read():Array<Int> {\n\t\treturn _d;\n\t}')).length);
	}

	// --- Path B negatives ---

	/**
	 * GATE: the prologue must run NOTHING. A plain `log();` before the run — a method reading the
	 * field's `length` — observes an empty array today and a filled one after the fold, and purity
	 * says nothing about it.
	 */
	public function testPrologueCallNotFolded(): Void {
		final src: String = ctor('private final _d:Array<Int> = [];', 'super();\n\t\tlog();\n\t\t_d.push(1);\n\t\tuse(_d);');
		Assert.equals(0, violations(withMember(src, 'private function log():Void {\n\t\ttrace(_d.length);\n\t}')).length);
	}

	/**
	 * GATE: the read-after scan excludes the field's OWN declaration, so a field declared BELOW the
	 * constructor and read by nothing else no longer satisfies it with itself.
	 */
	public function testFieldDeclaredAfterConstructorUnreadNotFolded(): Void {
		Assert.equals(
			0,
			violations(
				'class C extends B {\n\tpublic function new(n:Int) {\n\t\tsuper();\n\t\t_d.push(1);\n\t}\n'
				+ '\tprivate final _d:Array<Int> = [];\n}'
			).length
		);
	}

	/**
	 * GATE: the array-type proof covers the FIELD too. Path B is where the fold is most
	 * consequential, and an `abstract Stack<T>(Array<T>)` whose `push` PREPENDS would fold to a
	 * literal in the wrong order — and it compiles, so no oracle catches it.
	 */
	public function testAbstractTypedFieldNotFolded(): Void {
		Assert.equals(
			0, violations(ctor('private final _s:Stack<Int> = [];', 'super();\n\t\t_s.push(1);\n\t\t_s.push(2);\n\t\tuse(_s);')).length
		);
	}

	/**
	 * GATE: an annotation the reader cannot attribute to the declared name is `Unreadable`, not
	 * absent — `pkg.stack` puts a standalone `stack` in the TYPE's own tail, and reading that as
	 * "unannotated" would hand the array proof to a binding that never earned it.
	 */
	public function testUnreadableAnnotationNotFlagged(): Void {
		Assert.equals(0, violations(fn('final stack:pkg.stack = [];\n\t\tstack.push(1);\n\t\treturn stack;')).length);
	}

	/** GATE: purity — a `new T()` element would ALLOCATE before the base constructor runs. */
	public function testNewElementNotFoldedIntoField(): Void {
		Assert.equals(0, violations(ctor('private final _d:Array<T> = [];', 'super();\n\t\t_d.push(new T());\n\t\tuse(_d);')).length);
	}

	/** GATE: purity — a call element would RUN before the base constructor. */
	public function testCallElementNotFoldedIntoField(): Void {
		Assert.equals(
			0, violations(ctor('private final _d:Array<Int> = [];', 'super();\n\t\t_d.push(Helper.make());\n\t\tuse(_d);')).length
		);
	}

	/** GATE: context-freedom — a constructor PARAMETER does not exist at declaration-init time. */
	public function testParameterElementNotFoldedIntoField(): Void {
		Assert.equals(0, violations(ctor('private final _d:Array<Int> = [];', 'super();\n\t\t_d.push(n);\n\t\tuse(_d);')).length);
	}

	/** GATE: reachability — a run behind an early `return` is conditional; the prologue is not. */
	public function testRunBehindEarlyReturnNotFolded(): Void {
		Assert.equals(
			0,
			violations(ctor('private final _d:Array<Int> = [];', 'super();\n\t\tif (n == 0) return;\n\t\t_d.push(1);\n\t\tuse(_d);')).length
		);
	}

	/** GATE: the declaration initializer must be the field's ONLY assignment. */
	public function testSecondWriteToFieldNotFolded(): Void {
		final src: String = ctor('private var _d:Array<Int> = [];', 'super();\n\t\t_d.push(1);\n\t\tuse(_d);');
		Assert.equals(0, violations(withMember(src, 'public function reset():Void {\n\t\t_d = [];\n\t}')).length);
	}

	/** GATE: top level only — a push nested in an `if` runs conditionally. */
	public function testPushInsideIfNotFolded(): Void {
		Assert.equals(
			0,
			violations(ctor('private final _d:Array<Int> = [];', 'super();\n\t\tif (n == 0) {\n\t\t\t_d.push(1);\n\t\t}\n\t\tuse(_d);'))
				.length
		);
	}

	/** GATE: no earlier observation — the field is already read before the run. */
	public function testFieldReadBeforeRunNotFolded(): Void {
		Assert.equals(
			0, violations(ctor('private final _d:Array<Int> = [];', 'super();\n\t\tuse(_d);\n\t\t_d.push(1);\n\t\tuse(_d);')).length
		);
	}

	/** GATE: under `super(...)`, an `override` member reading the field can be reached virtually from the base. */
	public function testOverrideReaderUnderSuperNotFolded(): Void {
		final src: String = ctor('private final _d:Array<Int> = [];', 'super();\n\t\t_d.push(1);');
		Assert.equals(0, violations(withMember(src, 'override public function init():Void {\n\t\tuse(_d);\n\t}')).length);
	}

	/** GATE: the field must be read somewhere after the run. */
	public function testUnreadFieldNotFolded(): Void {
		Assert.equals(0, violations(ctor('private final _d:Array<Int> = [];', 'super();\n\t\t_d.push(1);')).length);
	}

	/** A STATIC field's initializer runs with the type, not the instance — out of scope. */
	public function testStaticFieldNotFolded(): Void {
		Assert.equals(0, violations(ctor('private static final _d:Array<Int> = [];', 'super();\n\t\t_d.push(1);\n\t\tuse(_d);')).length);
	}

	/** A field with no declaration initializer belongs to `field-init-at-declaration`, not here. */
	public function testUninitialisedFieldNotFolded(): Void {
		Assert.equals(0, violations(ctor('private var _d:Array<Int>;', 'super();\n\t\t_d.push(1);\n\t\tuse(_d);')).length);
	}

	// --- framework ---

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('join-array-pushes'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('join-array-pushes'));
	}

	/** The `TextOptions` shape: a field-assigning prologue statement, `super()`, then object-literal pushes. */
	private inline function motivating(): String {
		return ctor(
			'private final _d:Array<D<Int>> = [];',
			"type = n;\n\t\tsuper();\n\t\t_d.push({ text: '8', data: 8 });\n\t\t_d.push({ text: '9', data: 9 });\n\t\tuse(_d);"
		);
	}

	private inline function motivatingFolded(): String {
		return ctor(
			"private final _d:Array<D<Int>> = [{ text: '8', data: 8 }, { text: '9', data: 9 }];", 'type = n;\n\t\tsuper();\n\t\tuse(_d);'
		);
	}

	// --- fixtures ---

	/** A method body around `stmts`, with an `xs` parameter for the never-read fixture to return. */
	private inline function fn(stmts: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>):Array<Int> {\n\t\t$stmts\n\t}\n}';
	}

	/** A class with an `_a` field and a method body around `stmts` — the assignment form's host. */
	private inline function field(stmts: String): String {
		return 'class C {\n\tvar _a:Array<Int>;\n\tfunction f():Void {\n\t\t$stmts\n\t}\n}';
	}

	/** A subclass with the field `member` and a constructor body `stmts` — Path B's host. */
	private inline function ctor(member: String, stmts: String): String {
		return 'class C extends B {\n\t$member\n\tpublic function new(n:Int) {\n\t\t$stmts\n\t}\n}';
	}

	/** `source` with one more member spliced in before the closing brace of the class. */
	private inline function withMember(source: String, member: String): String {
		return '${source.substring(0, source.length - 1)}\t$member\n}';
	}

	/** Assert `vs` is exactly this rule's one `Info` finding — the three checks every positive opens with. */
	private function assertSoleFinding(vs: Array<Violation>): Void {
		Assert.equals(1, vs.length);
		Assert.equals('join-array-pushes', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	private function violations(source: String): Array<Violation> {
		return new JoinArrayPushes().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new JoinArrayPushes(), source);
	}

}
