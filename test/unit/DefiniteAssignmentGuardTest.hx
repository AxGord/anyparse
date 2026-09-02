package unit;

import anyparse.check.DefiniteAssignmentGuard;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * `DefiniteAssignmentGuard` — the compiler-free half of `lint --fix`'s revert net.
 *
 * The hole it closes, measured on the T445 fixture with S54's closure guard removed and one
 * deleting fix run three ways: `--no-oracle` wrote the corrupting edit, a config with no
 * `compilerOracle` wrote it, and only the oracle arm reverted. Two of those three arms are
 * the project's own documented edit loop and every project that never configured a compiler.
 *
 * Each fixture below is a source plus the ONE edit a deleting fix would emit on it, so the
 * subject is exactly what `Cli.collectFileLintEdits` asks the guard.
 */
class DefiniteAssignmentGuardTest extends Test {

	/** The T445 shape: after the edit the only write to `found` is under an unguarded `if`. */
	private static inline final GUARDED_CLOSURE: String = 'class C { static function scan(t: String): Bool { var found = false;'
		+ ' map(t, run -> { if (t == null) found = true; return run; }); return found; } }';

	public function testAGuardedClosureWriteIsNotDefiniteAssignment(): Void {
		// Compiled on Haxe 4.3.7: `Local variable found used without being initialized`.
		final refusal: Null<String> = refuse(GUARDED_CLOSURE, ' = false', '');
		Assert.notNull(refusal);
		Assert.stringContains('`found`', refusal ?? '');
		Assert.stringContains('assign', refusal ?? '');
	}

	public function testAnUnconditionalClosureWriteIsDefiniteAssignment(): Void {
		// The measurement that killed this guard's first design. A closure write is NOT excluded
		// from definite assignment in Haxe: with the `if` removed, the identical deletion
		// COMPILES on 4.3.7, so refusing it would decline a correct fix. The compiler treats a
		// lambda body as ordinary code at its position; the asymmetry is `if`, not the closure.
		final src: String = 'class C { static function scan(t: String): Bool { var found = false;'
			+ ' map(t, run -> { found = true; return run; }); return found; } }';
		Assert.isNull(refuse(src, ' = false', ''));
	}

	public function testAnIfWithNoElseOutsideAClosureIsNotDefiniteEither(): Void {
		// Same judgement with no closure in sight — the construct is what decides.
		final src: String =
			'class C { static function scan(t: String): Bool { var found = false; if (t == null) found = true; return found; } }';
		Assert.notNull(refuse(src, ' = false', ''));
	}

	public function testBothArmsOfAnIfAssign(): Void {
		final src: String = 'class C { static function scan(t: String): Bool { var found = false;'
			+ ' if (t == null) found = true else found = false; return found; } }';
		Assert.isNull(refuse(src, 'var found = false;', 'var found;'));
	}

	public function testAnExitingArmLetsItsSiblingCarry(): Void {
		// `if (c) x = 1 else return false;` compiles: the else contributes no path. A plain
		// intersection of the two arms would refuse it, which is why the merge reads exits.
		final src: String = 'class C { static function scan(t: String): Bool { var found = false;'
			+ ' if (t == null) found = true else return false; return found; } }';
		Assert.isNull(refuse(src, 'var found = false;', 'var found;'));
	}

	public function testNoRemainingWriteAtAllIsAFinding(): Void {
		final src: String = 'class C { static function scan(t: String): Bool { var found = false; trace(t); return found; } }';
		Assert.notNull(refuse(src, ' = false', ''));
	}

	public function testAPlainlyAnnotatedDeclarationIsUninitialized(): Void {
		// The shape `explicit-local-type` leaves behind: a written type is not an initializer.
		// Compiled on Haxe 4.3.7: `Local variable found used without being initialized`.
		final src: String = 'class C { static function scan(t: String): Bool { var found: Bool = false;'
			+ ' map(t, run -> { if (t == null) found = true; return run; }); return found; } }';
		Assert.notNull(refuse(src, ' = false', ''));
	}

	public function testAContinuationDeclaratorIsCoveredLikeAnyOther(): Void {
		final src: String = 'class C { static function scan(t: String): Bool { var k = 1, found = false;'
			+ ' map(t, run -> { if (t == null) found = true; return run + k; }); return found; } }';
		Assert.notNull(refuse(src, ' = false', ''));
	}

	public function testALeadingDeclaratorIsNotInitializedByItsContinuation(): Void {
		// The one shape where `NullFlow.declInit` and this guard's `hasInitializer` disagree: it
		// reads the LAST child, and for `var found, k = 1;` that is the `VarMore` continuation,
		// so it reports an initializer `found` does not have. Compiled on Haxe 4.3.7:
		// `Local variable found used without being initialized`.
		final src: String = 'class C { static function scan(t: String): Bool { var found = false, k = 1;'
			+ ' map(t, run -> { if (t == null) found = true; return run + k; }); return found; } }';
		Assert.notNull(refuse(src, ' = false', ''));
	}

	public function testAReadInsideTheClosureIsOnlyAWarningSoItIsNotRefused(): Void {
		// Measured: the same guarded write read from INSIDE the closure is
		// `Warning: (WVarInit) Local variable found might be used before being initialized` and
		// COMPILES. The oracle arm would keep that edit, so this one must too.
		final src: String = 'class C { static function scan(t: String): Bool { var found = false;'
			+ ' map(t, run -> { if (t == null) found = true; return found ? run : t; }); return true; } }';
		Assert.isNull(refuse(src, ' = false', ''));
	}

	public function testALoopBodyWriteIsWalkedAsASequenceAndLosesTheFinding(): Void {
		// A DELIBERATE miss, pinned so it stays deliberate. `while (c) { x = 1; break; }` is
		// rejected by the compiler, and this guard walks a loop as a plain sequence — optimistic,
		// so it can only lose a finding, never invent one. Modelling loops would buy findings at
		// the price of refusing correct fixes, which is the direction that costs the user.
		final src: String = 'class C { static function scan(t: String): Bool { var found = false;'
			+ ' while (t != null) { found = true; break; } return found; } }';
		Assert.isNull(refuse(src, ' = false', ''));
	}

	public function testAPreExistingUnassignedReadIsNotChargedToTheFix(): Void {
		// The answer is differential. `found` is already unassigned here and the edit is
		// somewhere else entirely; charging the fix with a state it inherited would refuse every
		// fix in the file for as long as the file stays that way.
		final src: String = 'class C { static function scan(t: String): Bool { var found; var k = 1;'
			+ ' map(t, run -> { if (t == null) found = true; return run + k; }); return found; } }';
		Assert.isNull(refuse(src, ' = 1', ''));
	}

	public function testANameBoundTwiceInTheUnitIsLeftAlone(): Void {
		// A name-keyed walk cannot tell two bindings apart, and the direction that costs a
		// correct fix is the refusing one.
		final src: String = 'class C { static function scan(t: String): Bool { var found = false;'
			+ ' if (t == null) { var found; return found; } map(t, run -> { if (t == null) found = true; return run; }); return found; } }';
		Assert.isNull(refuse(src, ' = false', ''));
	}

	public function testAWriteThroughAFieldAccessIsNotAWriteToTheLocal(): Void {
		// `found.flag = true` writes a FIELD, so it must not read as the assignment that makes
		// the local definite.
		final src: String = 'class C { static function scan(t: String): Bool { var found = new Box();'
			+ ' map(t, run -> { if (t == null) found = new Box(); return run; }); found.flag = true; return found.flag; } }';
		Assert.notNull(refuse(src, ' = new Box()', ''));
	}

	public function testAnUneditedSourceIsNeverRefused(): Void {
		Assert.isNull(DefiniteAssignmentGuard.unassignedRead(GUARDED_CLOSURE, [], new HaxeQueryPlugin()));
	}

	public function testAnEditReachingNoAssignmentIsNotRefused(): Void {
		// An edit that touches neither a declaration nor a write cannot turn a green unit red.
		Assert.isNull(refuse(GUARDED_CLOSURE, 'return run;', 'return t;'));
	}

	public function testUnparseableInputIsNotTheGuardsToReport(): Void {
		final broken: String = 'class C { static function scan(): Bool { var found = false; return found;';
		Assert.isNull(refuse(broken, ' = false', ''));
	}

	/** The guard's answer for `source` with `fragment` replaced by `replacement`, as one edit. */
	private function refuse(source: String, fragment: String, replacement: String): Null<String> {
		final at: Int = source.indexOf(fragment);
		if (at >= 0) return DefiniteAssignmentGuard.unassignedRead(source, [
			{
				span: new Span(at, at + fragment.length),
				text: replacement
			}
		], new HaxeQueryPlugin());
		Assert.fail('fixture does not contain "$fragment"');
		return null;
	}

}
