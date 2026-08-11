package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnnecessarySwitch;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The `unnecessary-switch` check: a switch whose only arm is an unconditional catch-all.
 *
 * Every refusal fixture is a MINIMAL PAIR of the firing one — it differs by exactly the feature
 * its gate names, so it can only pass because of that gate. The whole fix was additionally
 * verified against the Haxe compiler outside this suite: a program holding every shape below
 * printed byte-identical output before and after `--fix`.
 */
class UnnecessarySwitchCheckTest extends Test {

	private static inline final MESSAGE: String =
		'this switch has a single unconditional catch-all arm — it decides nothing; use the arm\'s body directly';

	public function testWildcardArmFlagged(): Void {
		final vs: Array<Violation> = violations(stmt('case _: t();'));
		Assert.equals(1, vs.length);
		Assert.equals('unnecessary-switch', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(MESSAGE, vs[0].message);
	}

	/** A `default:` arm is the same catch-all in the other spelling. */
	public function testDefaultArmFlagged(): Void {
		Assert.equals(1, violations(stmt('default: t();')).length);
	}

	/**
	 * The statement fix leaves a BLOCK rather than bare statements — self-terminating, legal as a
	 * brace-less body, and scope-preserving. `unnecessary-block` unwraps it where that is provable.
	 */
	public function testFixSplicesBlock(): Void {
		final out: String = applyFixOnce(stmt('case _: t();'));
		Assert.isFalse(out.contains('switch'), 'the switch is gone');
		Assert.stringContains('{', out);
		Assert.stringContains('t();', out);
	}

	/** Nothing is left for a second pass to find. */
	public function testFixIsIdempotent(): Void {
		Assert.equals(0, violations(applyFixOnce(stmt('case _: t();'))).length);
	}

	/** A guard RUNS and may reject, so the arm is not unconditional. */
	public function testGuardedArmRefused(): Void {
		Assert.equals(0, violations(stmt('case _ if (v > 0): t();')).length);
	}

	/** A binder is a different rewrite — it would have to introduce `final q = v;`. */
	public function testBinderArmRefused(): Void {
		Assert.equals(0, violations(stmt('case q: t();')).length);
	}

	/** Two arms decide something. */
	public function testTwoArmsRefused(): Void {
		Assert.equals(0, violations(stmt('case 1: u();\n\t\t\tcase _: t();')).length);
	}

	/** A conditional-compilation region among the arms holds arms this scan cannot enumerate. */
	public function testConditionalArmsRefused(): Void {
		Assert.equals(0, violations(stmt('#if js\n\t\t\tcase 1: u();\n\t\t\t#end\n\t\t\tcase _: t();')).length);
	}

	/** The subject's call RUNS — dropping the switch would drop it. */
	public function testImpureSubjectRefused(): Void {
		final src: String = 'class C {\n\tfunction f(): Void {\n\t\tswitch next() {\n\t\t\tcase _: t();\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A plain field read is droppable — the shape the whole rule was written for. */
	public function testFieldSubjectFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(e: Dynamic): Void {\n\t\tswitch e.action {\n\t\t\tcase _: t();\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/** A property read is a `get_p()` CALL, qualified or not — both spellings refuse. */
	public function testGetterSubjectRefused(): Void {
		final qualified: String = property('this.p');
		final bare: String = property('p');
		Assert.equals(0, violations(qualified).length, 'this.p is a getter call');
		Assert.equals(0, violations(bare).length, 'bare p is the same getter call');
	}

	/** A collection literal allocates but observes nothing — droppable, though never hoistable. */
	public function testCollectionLiteralSubjectFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(a: Int, b: Int): Void {\n\t\tswitch [a, b] {\n\t\t\tcase _: t();\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/** A comment in the region the unwrap disturbs would be discarded by it. */
	public function testCommentRefused(): Void {
		Assert.equals(0, violations(stmt('// why\n\t\t\tcase _: t();')).length);
	}

	/** An expression arm yields its VALUE, without the arm's own terminator. */
	public function testExpressionValueSpliced(): Void {
		final out: String = applyFixOnce(expr('final y: Int = switch v {\n\t\t\tcase _: 42;\n\t\t};'));
		// The canonical writer runs on DEFAULT options here, not the project's `hxformat.json`,
		// so the annotation comes back without its space.
		Assert.stringContains('final y:Int = 42;', out);
	}

	/**
	 * The switch's brace WAS the `return`'s terminator, so the spliced value owes one — `return 42`
	 * without it is `Missing ;` to the Haxe compiler.
	 */
	public function testReturnValueGainsTerminator(): Void {
		final src: String = 'class C {\n\tfunction f(v: Int): Int {\n\t\treturn switch v {\n\t\t\tcase _: 42;\n\t\t}\n\t}\n}';
		Assert.stringContains('return 42;', applyFixOnce(src));
	}

	/** Inside a call the statement closes itself, so no terminator is owed — `t(42;)` would not parse. */
	public function testNestedValueOwesNoTerminator(): Void {
		final src: String = 'class C {\n\tfunction f(v: Int): Void {\n\t\tt(switch v {\n\t\t\tcase _: 42;\n\t\t});\n\t}\n}';
		Assert.stringContains('t(42);', applyFixOnce(src));
	}

	/** A multi-statement expression arm would need a block-expression wrapper — a rewrite, not an unwrap. */
	public function testMultiStatementExpressionArmRefused(): Void {
		Assert.equals(0, violations(expr('final y: Int = switch v {\n\t\t\tcase _: u();\n\t\t\t\t42;\n\t\t};')).length);
	}

	/** An empty arm has no block worth leaving. */
	public function testEmptyArmDeleted(): Void {
		final src: String = stmt('case _:');
		Assert.equals(1, violations(src).length);
		Assert.isFalse(applyFixOnce(src).contains('switch'), 'the switch is gone');
	}

	/** Deleting the brace-less body of an `if` would leave the `if` with none. */
	public function testEmptyArmInBracelessBodyRefused(): Void {
		final src: String = 'class C {\n\tfunction f(c: Bool, v: Int): Void {\n\t\tif (c) switch v {\n\t\t\tcase _:\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A brace-less body is fine for a NON-empty arm: the block the fix leaves is a legal body. */
	public function testBracelessBodyFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(c: Bool, v: Int): Void {\n\t\tif (c) switch v {\n\t\t\tcase _:\n\t\t\t\tt();\n'
			+ '\t\t\t\tu();\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.stringContains('if (c) {', applyFixOnce(src));
	}

	public function testRegisteredAsBuiltin(): Void {
		Assert.notNull(Linter.byId('unnecessary-switch'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unnecessary-switch'));
	}

	/** A statement switch over an `Int` parameter, holding `branches`. */
	private function stmt(branches: String): String {
		return 'class C {\n\tfunction f(v: Int): Void {\n\t\tswitch v {\n\t\t\t$branches\n\t\t}\n\t}\n}';
	}

	/** A function body holding `body` verbatim — for the expression-position shapes. */
	private function expr(body: String): String {
		return 'class C {\n\tfunction f(v: Int): Void {\n\t\t$body\n\t}\n}';
	}

	/** A class with a side-effecting property, switching on `subject`. */
	private function property(subject: String): String {
		return 'class C {\n\tpublic var p(get, never): Int;\n\n\tfunction get_p(): Int {\n\t\tu();\n\t\treturn 1;\n\t}\n\n'
			+ '\tfunction f(): Void {\n\t\tswitch $subject {\n\t\t\tcase _: t();\n\t\t}\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new UnnecessarySwitch().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Run the fix and re-emit through the canonical writer, the way `lint --fix` does. */
	private function applyFixOnce(src: String): String {
		final check: UnnecessarySwitch = new UnnecessarySwitch();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		return switch RefactorSupport.canonicalize(src, edits, true, plugin) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
