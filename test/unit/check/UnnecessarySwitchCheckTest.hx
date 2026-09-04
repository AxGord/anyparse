package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnnecessarySwitch;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

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

	/**
	 * A PARAMETER of the property's name SHADOWS it, so the subject is that parameter — a plain
	 * read, not a `get_p()` call. Minimal pair of `testGetterSubjectRefused`'s bare spelling: the
	 * only difference is that the name is bound.
	 */
	public function testParameterShadowingGetterNameFlagged(): Void {
		final out: String = unwrapped(shadowedProperty('f(p: Int)', 'switch p {\n\t\t\tcase _: t();\n\t\t}'));
		Assert.stringContains(
			'function f(p:Int):Void {\n\t\t{\n\t\t\tt();', out, 'the parameter survives, the switch around its read does not'
		);
	}

	/** A LOCAL shadows the property the same way a parameter does. */
	public function testLocalShadowingGetterNameFlagged(): Void {
		final body: String = 'var p: Int = 0;\n\t\tswitch p {\n\t\t\tcase _: t();\n\t\t}';
		Assert.stringContains(
			'var p:Int = 0;\n\t\t{\n\t\t\tt();', unwrapped(shadowedProperty('f()', body)), 'the local survives, the switch does not'
		);
	}

	/** A `for` iterator binds the name inside the loop, where the subject reads it. */
	public function testForBinderShadowingGetterNameFlagged(): Void {
		final body: String = 'for (p in xs) switch p {\n\t\t\tcase _: t();\n\t\t}';
		Assert.stringContains(
			'for (p in xs) {\n\t\t\tt();', unwrapped(shadowedProperty('f(xs: Array<Int>)', body)), 'the loop survives, the switch does not'
		);
	}

	/** A catch clause binds the exception inside its own body, where the subject reads it. */
	public function testCatchBinderShadowingGetterNameFlagged(): Void {
		final body: String = 'try u() catch (p: String) switch p {\n\t\t\tcase _: t();\n\t\t}';
		Assert.stringContains(
			'catch (p:String)\n\t\t\tt();', unwrapped(shadowedProperty('f()', body)), 'the catch binder survives, the switch does not'
		);
	}

	/** A local `function` binds its name into the enclosing body; a bare read of it is a closure read. */
	public function testLocalFunctionShadowingGetterNameFlagged(): Void {
		final body: String = 'function p(): Int return 2;\n\t\tswitch p {\n\t\t\tcase _: t();\n\t\t}';
		Assert.stringContains(
			'function p():Int\n\t\t\treturn 2;\n\t\t{\n\t\t\tt();', unwrapped(shadowedProperty('f()', body)),
			'the local function survives, the switch does not'
		);
	}

	/**
	 * Haxe hoists a local `function` no more than a local `var`. Minimal pair of the test above —
	 * the two statements, swapped.
	 */
	public function testReadBeforeShadowingLocalFunctionRefused(): Void {
		final body: String = 'switch p {\n\t\t\tcase _: t();\n\t\t}\n\t\tfunction p(): Int return 2;';
		Assert.equals(0, violations(shadowedProperty('f()', body)).length);
	}

	/**
	 * A `for` HEADER is outside the scope its own iterator binds into, so the subject there reads
	 * the property. Nothing in this check re-derives that — it is `Refs.headerFloor`'s answer, and
	 * this is the fixture that fails if the floor stops applying: without it the subject resolves
	 * to the iterator, which IS a value declaration whose node encloses the read, and the getter
	 * call is deleted.
	 */
	public function testReadInForHeaderRefused(): Void {
		final body: String = 'for (p in switch p {\n\t\t\tcase _: xs;\n\t\t}) t();';
		Assert.equals(0, violations(shadowedProperty('f(xs: Array<Int>)', body)).length, 'the header read is not the iterator');
	}

	/**
	 * A declaration under a TRANSPARENT wrapper escapes into the enclosing block, but its parent is
	 * the wrapper — an admitted over-refusal, kept rather than closed by a list of non-scoping
	 * kinds. See `TypeResolver.bindsToValueDeclaration`.
	 */
	public function testShadowUnderTransparentWrapperRefused(): Void {
		final body: String = 'untyped var p = 1;\n\t\tswitch p {\n\t\t\tcase _: t();\n\t\t}';
		Assert.equals(0, violations(shadowedProperty('f()', body)).length);
	}

	/**
	 * Haxe does not hoist a local, so a read BEFORE the declaration is still the property. Minimal
	 * pair of `testLocalShadowingGetterNameFlagged` — the two statements, swapped.
	 */
	public function testReadBeforeShadowingLocalRefused(): Void {
		Assert.equals(0, violations(shadowedProperty('f()', 'switch p {\n\t\t\tcase _: t();\n\t\t}\n\t\tvar p: Int = 0;')).length);
	}

	/** A declaration's own initializer still sees the enclosing binding — here, the property. */
	public function testReadInsideShadowingInitializerRefused(): Void {
		Assert.equals(0, violations(shadowedProperty('f()', 'final p: Int = switch p {\n\t\t\tcase _: 42;\n\t\t};')).length);
	}

	/**
	 * The plain tree folds every `#if` branch into ONE node with no boundary between them, so a
	 * declaration in the sibling branch is not proof of anything at this read.
	 */
	public function testShadowInSiblingConditionalBranchRefused(): Void {
		final body: String = '#if js\n\t\tvar p: Int = 0;\n\t\t#else\n\t\tswitch p {\n\t\t\tcase _: t();\n\t\t}\n\t\t#end';
		Assert.equals(0, violations(shadowedProperty('f()', body)).length);
	}

	/** A declaration written as a brace-less body is scoped to that body, not to the block after it. */
	public function testShadowInBracelessBodyRefused(): Void {
		final body: String = 'if (c) var p: Int = 0;\n\t\tswitch p {\n\t\t\tcase _: t();\n\t\t}';
		Assert.equals(0, violations(shadowedProperty('f(c: Bool)', body)).length);
	}

	/** An `untyped { … }` block scopes its declarations, though the resolver models no frame for it. */
	public function testShadowInUntypedBlockRefused(): Void {
		final body: String = 'untyped {\n\t\t\tvar p: Int = 0;\n\t\t}\n\t\tswitch p {\n\t\t\tcase _: t();\n\t\t}';
		Assert.equals(0, violations(shadowedProperty('f()', body)).length);
	}

	/** A `for` iterator dies at the loop's end, so a read after it is the property again. */
	public function testReadAfterForBinderRefused(): Void {
		final body: String = 'for (p in xs) t();\n\t\tswitch p {\n\t\t\tcase _: t();\n\t\t}';
		Assert.equals(0, violations(shadowedProperty('f(xs: Array<Int>)', body)).length);
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

	/**
	 * A class with a side-effecting property `p`, whose method — spelled by `signature`, so a
	 * fixture can bind `p` as a PARAMETER — holds `body` verbatim.
	 */
	private function shadowedProperty(signature: String, body: String): String {
		return 'class C {\n\tpublic var p(get, never): Int;\n\n\tfunction get_p(): Int {\n\t\tu();\n\t\treturn 1;\n\t}\n\n'
			+ '\tfunction $signature: Void {\n\t\t$body\n\t}\n}';
	}

	/**
	 * The fixed text of `src`, having asserted that it reports exactly ONE finding. Every caller
	 * then asserts one STRING spanning both halves of the rewrite — the binding the fix must
	 * leave alone next to the arm body it unwrapped — so no assertion can be satisfied by an
	 * untransformed input.
	 */
	private function unwrapped(src: String): String {
		Assert.equals(1, violations(src).length);
		return applyFixOnce(src);
	}

	private function violations(src: String): Array<Violation> {
		return new UnnecessarySwitch().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Run the fix and re-emit through the canonical writer, the way `lint --fix` does. */
	private function applyFixOnce(src: String): String {
		final check: UnnecessarySwitch = new UnnecessarySwitch();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		return switch CanonicalEdit.canonicalize(src, edits, true, plugin) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
