package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnnecessaryBlock;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import utest.Assert;
import utest.Test;

/**
 * The `unnecessary-block` check: a bare `{ … }` statement block nested in another statement list is flagged
 * `Info` and unwrapped by `--fix`. A control-flow body is never a candidate. Three gates keep the rest: the
 * block must be the ONLY bare block of its container (a run of them is a sectioning device), must hold at most
 * `MAX_STATEMENTS` statements, and must bind no name already live in the frame it would unwrap into.
 */
class UnnecessaryBlockCheckTest extends Test {

	public function testBareBlockFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('{\n\t\t\ttrace(1);\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('unnecessary-block', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** The block is an `if` body — its parent is the `if`, not a block container. */
	public function testIfBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (c) {\n\t\t\ttrace(1);\n\t\t}')).length);
	}

	/** A block that declares a local is a real scope and is left alone. */
	public function testBlockWithLocalFlagged(): Void {
		// The block's `x` is bound nowhere else in the function, so unwrapping it cannot rebind a read.
		Assert.equals(1, violations(wrap('{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testFixUnwraps(): Void {
		final fixed: String = fixedSource(wrap('{\n\t\t\ttrace(1);\n\t\t}'));
		Assert.isTrue(fixed.indexOf('trace(1);') >= 0);
		Assert.equals(-1, fixed.indexOf('{\n\t\t\t'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unnecessary-block'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unnecessary-block'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** A block declaring a local function is a real scope (unwrapping would hoist it) — left alone. */
	public function testBlockWithLocalFunctionFlagged(): Void {
		Assert.equals(1, violations(wrap('{\n\t\t\tfunction h():Void {}\n\t\t\th();\n\t\t}')).length);
	}

	/** A `case` arm body is a statement list; a bare block there (an AS3-conversion artifact) is flagged. */
	public function testCaseBranchBlockFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('switch s {\n\t\t\tcase "/": {\n\t\t\t\ttrace(1);\n\t\t\t}\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('unnecessary-block', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** A `default` arm body is a statement list too. */
	public function testDefaultBranchBlockFlagged(): Void {
		Assert.equals(
			1, violations(wrap('switch s {\n\t\t\tcase 1: trace(9);\n\t\t\tdefault: {\n\t\t\t\ttrace(2);\n\t\t\t}\n\t\t}')).length
		);
	}

	/** A case GUARD is not a block, so listing the branch as a container stays exact. */
	public function testGuardedCaseBranchBlockFlagged(): Void {
		Assert.equals(1, violations(wrap('switch s {\n\t\t\tcase x if (g): {\n\t\t\t\ttrace(1);\n\t\t\t}\n\t\t}')).length);
	}

	/** A case-arm block that declares a local is a real scope — left alone. */
	public function testCaseBranchBlockWithLocalFlagged(): Void {
		Assert.equals(1, violations(wrap('switch s {\n\t\t\tcase "/": {\n\t\t\t\tvar y = 1;\n\t\t\t\ttrace(y);\n\t\t\t}\n\t\t}')).length);
	}

	public function testCaseBranchBlockUnwraps(): Void {
		final fixed: String = fixedSource(wrap('switch s {\n\t\t\tcase "/": {\n\t\t\t\ttrace(1);\n\t\t\t}\n\t\t}'));
		Assert.isTrue(fixed.indexOf('trace(1);') >= 0);
		Assert.equals(-1, fixed.indexOf('case "/": {'));
	}

	/** A local of the same name declared BEFORE the block: unwrapping would rebind every read after it. */
	public function testBlockWithCollidingEarlierLocalNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var x = 0;\n\t\t{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}\n\t\ttrace(x);')).length);
	}

	/** A local of the same name declared AFTER the block collides just as much — the frame is not ordered. */
	public function testBlockWithCollidingLaterLocalNotFlagged(): Void {
		Assert.equals(0, violations(wrap('{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}\n\t\tvar x = 2;\n\t\ttrace(x);')).length);
	}

	/** The enclosing function's parameters are in the frame the block would unwrap into. */
	public function testBlockWithCollidingParamNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(x:Int):Void {\n\t\t{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * Two sibling blocks binding one name: each is a scope, so neither is in the other's frame and the scope
	 * gate clears both — only the twin gate stops them redeclaring the name side by side.
	 */
	public function testSecondBareBlockDisablesBoth(): Void {
		Assert.equals(
			0, violations(wrap('{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}\n\t\t{\n\t\t\tvar y = 2;\n\t\t\ttrace(y);\n\t\t}')).length
		);
	}

	/** A twin of only ONE of three candidates leaves the third — the gate is per name, not per container. */
	public function testOverWeightBlockNotFlagged(): Void {
		final body: String =
			'{\n\t\t\tvar x = 1;\n\t\t\ttrace(1);\n\t\t\ttrace(2);\n\t\t\ttrace(3);\n\t\t\ttrace(4);\n\t\t\ttrace(x);\n\t\t}';
		Assert.equals(0, violations(wrap(body)).length);
	}

	/**
	 * `inline function` is its own grammar kind (`LocalInlineFnStmt`), absent from `RefShape.functionKinds` —
	 * the hole the old binding-free gate had, since that is the form this codebase's style prescribes for a
	 * local helper.
	 */
	public function testBlockWithCollidingInlineLocalFunctionNotFlagged(): Void {
		final body: String = 'inline function h():Void {}\n\t\th();\n\t\t{\n\t\t\tinline function h():Void {}\n\t\t\th();\n\t\t}';
		Assert.equals(0, violations(wrap(body)).length);
	}

	/** A local declared in ANOTHER `#if` branch of the same block still counts — the refusal is the safe side. */
	public function testBlockWithCollidingCondBranchLocalNotFlagged(): Void {
		final body: String = '#if js\n\t\tvar x = 0;\n\t\t#end\n\t\t{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}';
		Assert.equals(0, violations(wrap(body)).length);
	}

	/** The unwrapped local lands beside the statement that followed the block, one indent to the left. */
	public function testFixUnwrapsBlockWithLocal(): Void {
		// Canonicalised, because the raw splice keeps the inner statements' original indentation —
		// re-indenting is the pipeline's job, and asserting on the run PROVES the braces are gone.
		final fixed: String = fixedCanonical(wrap('{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}\n\t\ttrace(2);'));
		Assert.isTrue(fixed.indexOf('\t\tvar x = 1;\n\t\ttrace(x);\n\t\ttrace(2);') >= 0, 'unexpected: $fixed');
	}

	/** One statement under the weight limit still passes — the gate is a threshold, not a ban on several statements. */
	public function testAtWeightLimitFlagged(): Void {
		final body: String = '{\n\t\t\tvar x = 1;\n\t\t\ttrace(1);\n\t\t\ttrace(2);\n\t\t\ttrace(3);\n\t\t\ttrace(x);\n\t\t}';
		Assert.equals(1, violations(wrap(body)).length);
	}

	/** A sibling block in a DIFFERENT container leaves this one alone — the lone gate is per statement list. */
	public function testBareBlockInAnotherContainerIrrelevant(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}\n\t}\n'
			+ '\n\tfunction g():Void {\n\t\t{\n\t\t\tvar y = 2;\n\t\t\ttrace(y);\n\t\t}\n\t}\n}';
		Assert.equals(2, violations(src).length);
	}

	/**
	 * A bare block inside a `#if` region: the branch is a statement list of its own, so the braces buy nothing
	 * there either — the case the plain tree hid, since the block's parent is then the `Conditional` node.
	 */
	public function testBlockInsideCondRegionFlagged(): Void {
		final body: String = '#if js\n\t\t{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}\n\t\t#end';
		Assert.equals(1, violations(wrap(body)).length);
	}

	/** Each branch of a region is its own container, so a bare block in each is flagged on its own. */
	public function testBlockInEachCondBranchFlagged(): Void {
		final body: String = '#if js\n\t\t{\n\t\t\ttrace(1);\n\t\t}\n\t\t#else\n\t\t{\n\t\t\ttrace(2);\n\t\t}\n\t\t#end';
		Assert.equals(2, violations(wrap(body)).length);
	}

	/**
	 * A `#if` branch is not a Haxe scope, so a block unwrapped there lands in the ENCLOSING block's frame — a
	 * local of the same name outside the region collides just as it would without the region.
	 */
	public function testBlockInsideCondRegionWithCollidingOuterLocalNotFlagged(): Void {
		final body: String = 'var x = 0;\n\t\t#if js\n\t\t{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}\n\t\t#end\n\t\ttrace(x);';
		Assert.equals(0, violations(wrap(body)).length);
	}

	/** The unwrapped statements stay inside the region — the directives are not part of the block's span. */
	public function testFixUnwrapsBlockInsideCondRegion(): Void {
		final fixed: String = fixedCanonical(wrap('#if js\n\t\t{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}\n\t\t#end\n\t\ttrace(2);'));
		Assert.isTrue(fixed.indexOf('#if js\n\t\tvar x = 1;\n\t\ttrace(x);\n\t\t#end\n\t\ttrace(2);') >= 0, 'unexpected: $fixed');
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new UnnecessaryBlock().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		return CheckFixture.fixedSource(new UnnecessaryBlock(), src);
	}

	/** Run + fix + canonicalise (whole-file reformat) `src`, returning the emitted text. */
	private function fixedCanonical(src: String): String {
		final check: UnnecessaryBlock = new UnnecessaryBlock();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		return switch CanonicalEdit.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
				src;
		};
	}

}
