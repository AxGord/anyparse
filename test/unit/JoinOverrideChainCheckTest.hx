package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.JoinOverrideChain;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.check.Check;

using StringTools;

/**
 * The `join-override-chain` check: a local declaration followed by TWO OR MORE consecutive
 * statement-position `switch`es that each conditionally overwrite it is flagged `Info`, and `fix`
 * collapses the whole run into one declaration whose initializer nests them LAST construct
 * outermost. The multi-statement axis of the assignment-collapse family: the merge reorders the
 * subjects and may skip an earlier construct entirely, so every subject and every arm value must
 * be pure, the target must not be read inside the run, and every construct must leave a
 * non-writing path (an EMPTY `case _:`) for the previous state to survive on.
 */
class JoinOverrideChainCheckTest extends Test {

	/** Two consecutive partial-writer switches over one declared local — the motivating shape. */
	private static inline final CHAIN: String = 'class C {\n\tfunction f(a:E, b:E) {\n' + '\t\tvar x:String = null;\n'
		+ '\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase 2: x = \'q\';\n\t\t\tcase _:\n\t\t}\n'
		+ '\t\tswitch b.k {\n\t\t\tcase 3: x = \'r\';\n\t\t\tcase _:\n\t\t}\n' + '\t}\n}\n';

	/** The same chain written INSIDE a `macro …` quotation, where the switches are AST the macro builds. */
	private static inline final QUOTED: String = 'class C {\n\tfunction f(a:E, b:E) {\n\t\tfinal e = macro {\n'
		+ '\t\t\tvar x:String = null;\n' + '\t\t\tswitch a.k {\n\t\t\t\tcase 1: x = \'p\';\n\t\t\t\tcase _:\n\t\t\t}\n'
		+ '\t\t\tswitch b.k {\n\t\t\t\tcase 3: x = \'r\';\n\t\t\t\tcase _:\n\t\t\t}\n\t\t};\n' + '\t}\n}\n';

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('join-override-chain');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'join-override-chain is opt-in');
	}

	public function testChainFlagged(): Void {
		final vs: Array<Violation> = violations(CHAIN);
		Assert.equals(1, vs.length);
		Assert.equals('join-override-chain', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'this declaration and the chain of conditional overwrites after it can be one nested switch-expression assignment',
			vs[0].message
		);
	}

	/** The nesting runs LAST construct outermost, and the declaration's own initializer is the innermost fallback. */
	public function testFixNestsLastConstructOutermost(): Void {
		final es: Array<{ span: Span, text: String }> = edits(CHAIN);
		Assert.equals(1, es.length);
		Assert.equals(
			'final x:String = switch b.k { case 3: \'r\'; case _: switch a.k { case 1: \'p\'; case 2: \'q\'; case _: null; }; };',
			es[0].text
		);
	}

	/** The collapsed source parses, and re-running the check over it reports nothing more. */
	public function testFixOutputIsStable(): Void {
		final fixed: String = applyFixOnce(CHAIN);
		Assert.isTrue(fixed.indexOf('final x:String = switch b.k {') >= 0, fixed);
		Assert.equals(0, violations(fixed).length);
	}

	/** ONE construct is the single-construct rules' business (`prefer-switch-expression-assignment`), not a chain. */
	public function testSingleSwitchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase _:\n\t\t}')).length);
	}

	/** A later write keeps the declaration `var` — the collapse does not make the local final. */
	public function testLaterWriteKeepsVarKeyword(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('${CHAIN.substr(0, CHAIN.length - 5)}\t\tif (x == null) x = \'z\';\n\t}\n}\n');
		Assert.equals(1, es.length);
		Assert.isTrue(es[0].text.startsWith('var x:String = switch b.k {'), es[0].text);
	}

	/** The merge evaluates the LAST subject first, so an impure subject anywhere disqualifies the run. */
	public function testImpureSubjectNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase _:\n\t\t}\n\t\tswitch pick() {\n'
				+ '\t\t\tcase 3: x = \'r\';\n\t\t\tcase _:\n\t\t}'
			)).length
		);
	}

	/** An earlier arm value may be SKIPPED after the merge, so an impure one disqualifies the run. */
	public function testImpureArmValueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase 1: x = make();\n\t\t\tcase _:\n\t\t}\n\t\tswitch b.k {\n'
				+ '\t\t\tcase 3: x = \'r\';\n\t\t\tcase _:\n\t\t}'
			)).length
		);
	}

	/** An impure initializer would move from "always" to "only on the innermost fallback path". */
	public function testImpureInitializerNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = make();\n\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase _:\n\t\t}\n\t\tswitch b.k {\n'
				+ '\t\t\tcase 3: x = \'r\';\n\t\t\tcase _:\n\t\t}'
			)).length
		);
	}

	/** A read of the target inside the run becomes a self-reference in its own initializer. */
	public function testReadInsideRunNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase _:\n\t\t}\n\t\tswitch b.k {\n'
				+ '\t\t\tcase 3: x = x;\n\t\t\tcase _:\n\t\t}'
			)).length
		);
	}

	/** A construct that writes on EVERY path leaves nothing for the previous state to survive on. */
	public function testTotalSwitchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase _:\n\t\t}\n\t\tswitch b.k {\n'
				+ '\t\t\tcase 3: x = \'r\';\n\t\t\tcase _: x = \'s\';\n\t\t}'
			)).length
		);
	}

	/** A missing `case _:` leaves the fallback path unspelled, so nothing can borrow the previous state. */
	public function testNoDefaultArmNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase _:\n\t\t}\n\t\tswitch b.k {\n'
				+ '\t\t\tcase 3: x = \'r\';\n\t\t}'
			)).length
		);
	}

	/** Any statement between two constructs breaks the run — the merge only reorders what it swallows. */
	public function testInterveningStatementNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase _:\n\t\t}\n\t\ttrace(1);\n'
				+ '\t\tswitch b.k {\n\t\t\tcase 3: x = \'r\';\n\t\t\tcase _:\n\t\t}'
			)).length
		);
	}

	/** A second construct writing a DIFFERENT local leaves a one-construct run, which is not a chain. */
	public function testDifferentTargetNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase _:\n\t\t}\n\t\tswitch b.k {\n'
				+ '\t\t\tcase 3: y = \'r\';\n\t\t\tcase _:\n\t\t}'
			)).length
		);
	}

	/** A comment inside a region the collapse drops would be lost. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = null;\n\t\t// why\n\t\tswitch a.k {\n\t\t\tcase 1: x = \'p\';\n\t\t\tcase _:\n\t\t}\n\t\tswitch b.k {\n'
				+ '\t\t\tcase 3: x = \'r\';\n\t\t\tcase _:\n\t\t}'
			)).length
		);
	}

	/** A bare `$name` interpolation is a plain read, so an arm value holding one still collapses. */
	public function testInterpolatedArmValueFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap(
			'var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase E(i): x = \'$$i\';\n\t\t\tcase _:\n\t\t}\n\t\tswitch b.k {\n'
			+ '\t\t\tcase E(i): x = \'$$i\';\n\t\t\tcase _:\n\t\t}'
		));
		Assert.equals(1, es.length);
		Assert.equals(
			'final x:String = switch b.k { case E(i): \'$$i\'; case _: switch a.k { case E(i): \'$$i\'; case _: null; }; };', es[0].text
		);
	}

	/** An interpolated BLOCK is an arbitrary expression, not a plain read. */
	public function testInterpolatedBlockArmValueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'var x:String = null;\n\t\tswitch a.k {\n\t\t\tcase E(i): x = \'$${go(i)}\';\n\t\t\tcase _:\n\t\t}\n\t\tswitch b.k {\n'
				+ '\t\t\tcase 3: x = \'r\';\n\t\t\tcase _:\n\t\t}'
			)).length
		);
	}

	/** Collapsing a chain inside a REIFICATION subtree changes the AST the macro emits. */
	public function testMacroQuotationNotFlagged(): Void {
		Assert.equals(0, linted(QUOTED).length);
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f(a:E, b:E) {\n\t\t$body\n\t}\n}\n';
	}

	private function violations(src: String): Array<Violation> {
		return new JoinOverrideChain().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The same findings THROUGH THE LINTER — the altitude the central reification gate lives at. */
	private function linted(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new JoinOverrideChain()]);
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: JoinOverrideChain = new JoinOverrideChain();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
