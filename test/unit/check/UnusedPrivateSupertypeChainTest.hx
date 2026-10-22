package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.UnusedPrivate;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `unused-private`'s autofix on a private method of an `extends` class, with no compiler facts: the resolution scope
 * answers whether the chain can still reach the member (`MemberLookup.supertypeMemberProof`) — the client's
 * `Form.onFormRemovedFromStage` over `Box -> openfl Sprite -> …` is the shape — and the deletion purity of a dead
 * final whose initializer is a `String` method (client `StringUtil.CHARSET_UPPER`).
 */
class UnusedPrivateSupertypeChainTest extends Test {

	private static inline final SUBCLASS: String = 'class C extends Base {\n\tprivate function impl():Int {\n\t\treturn 1;\n\t}\n}';

	/** Every link resolved, none declaring the name, none under a build macro: the method implements nothing and goes. */
	@:pin('control')
	@:killer('M-UNUSED-PRIVATE-CHAIN-NOT-RESOLVED')
	public function testFixDeletesTheMethodWhenTheChainProvesNothingDeclaresIt(): Void {
		Assert.equals(1, chainFix('class Base extends Root {\n\tpublic function new() {}\n}', 'class Root {}').edits.length);
	}

	/**
	 * The member is kept when an ancestor is under a build macro or leaves the scope, and the decline names which. (One
	 * that DECLARES the name is not reported at all — `run` asks the same question first.)
	 */
	@:pin('control')
	@:killer('M-UNUSED-PRIVATE-CHAIN-BUILD-IGNORED')
	public function testFixKeepsTheMethodTheChainMayReach(): Void {
		final autoBuilt: FixRun = chainFix('@:autoBuild(M.b()) class Base extends Root {}', 'class Root {}');
		Assert.equals(0, autoBuilt.edits.length);
		Assert.isTrue(declineOf(autoBuilt).indexOf('`Base` is under a build macro') != -1, declineOf(autoBuilt));
		Assert.equals(0, chainFix('class Base extends Root {}', '@:build(M.b()) class Root {}').edits.length);
		final missing: FixRun = chainFix('class Base extends Missing {}', 'class Root {}');
		Assert.equals(0, missing.edits.length);
		Assert.isTrue(declineOf(missing).indexOf('outside the resolution scope') != -1, declineOf(missing));
	}

	/** A `String` method on a `String` final is pure, so the dead constant goes; a nullable receiver or another method do not. */
	@:pin('control')
	@:killer('M-PURE-STRING-METHOD-OFF')
	public function testFixDeletesADeadFinalOfAPureStringMethod(): Void {
		final src: String = 'class C {\n\tprivate static final A:String = \'abc\';\n\tprivate static final B:String = A.toUpperCase();\n\n'
			+ '\tpublic static function f():String {\n\t\treturn A;\n\t}\n}';
		Assert.equals(1, CheckFixture.edits(new UnusedPrivate(), src).length);
		Assert.equals(0, CheckFixture.edits(new UnusedPrivate(), src.replace('A:String', 'A:Null<String>')).length);
		Assert.equals(0, CheckFixture.edits(new UnusedPrivate(), src.replace('A.toUpperCase()', 'A.mutate()')).length);
	}

	/** `--fix` over `SUBCLASS`, with `Base.hx` and `Root.hx` in the report scope — its one finding and the edits. */
	private function chainFix(base: String, root: String): FixRun {
		final run: FixRun = CheckFixture.fixRun(new UnusedPrivate(), [
			{ file: 'C.hx', source: SUBCLASS },
			{ file: 'Base.hx', source: base },
			{ file: 'Root.hx', source: root }
		]);
		Assert.equals(1, run.violations.length);
		return run;
	}

	/** The decline note on `run`'s one finding, or an empty string. */
	private function declineOf(run: FixRun): String {
		final v: Null<Violation> = run.violations[0];
		return v?.declineReason ?? '';
	}

}
