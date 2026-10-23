package unit.query;

import anyparse.query.ArgumentSlots;

/**
 * `ArgumentSlots.runs` — how a call binds its arguments, each case a shape Haxe 4.3.7 was asked (`$type` / the bound
 * values printed on `--interp`, `-js`, `-cpp`): greedy, an optional parameter an argument misfits skipped, both ways where
 * the fit is undecided, and a run that cannot compile dropped.
 */
class ArgumentSlotsTest extends Test {

	/** `f(?a:Int, ?b:String, c:Int)` called `f(1)`: the `1` binds `a` and `c` is left unbound — a compile error, no run. */
	@:pin('control')
	@:killer('M-SLOTS-FIT-SKIPS')
	public function testABindingNeverBacktracks(): Void {
		Assert.same([], runs([opt(), opt(), mandatory()], [[Fits, Misfits, Fits]]));
	}

	/** `g(?a:Int, ?b:String, ?c:Bool)` called `g(true)`: `a` and `b` are skipped, `c` takes it. */
	@:pin('control')
	@:killer('M-SLOTS-MISFIT-BINDS')
	public function testAMisfitSkipsAnOptionalParameter(): Void {
		Assert.same([[2]], runs([opt(), opt(), opt()], [[Misfits, Misfits, Fits]]));
	}

	/** An argument that fits binds where it meets: never also skipped (`k(null, 'q')` binds `null` to `a`). */
	@:pin('control')
	@:killer('M-SLOTS-FIT-SKIPS')
	public function testAFitBindsWhereItMeets(): Void {
		Assert.same([[0, 1]], runs([opt(), opt(), opt()], [[Fits, MayFit, MayFit], [Misfits, Fits, MayFit]]));
	}

	/** An undecided fit at an optional parameter is followed both ways, in that order: bound, then skipped. */
	@:pin('control')
	@:killer('M-SLOTS-MAYFIT-BINDS-ONLY')
	public function testAnUndecidedFitIsFollowedBothWays(): Void {
		Assert.same([[0], [1]], runs([opt(), opt()], [[MayFit, Fits]]));
	}

	/** A mandatory parameter is bound whatever the fit, unless it misfits: then the call cannot compile. */
	@:pin('control')
	@:killer('M-SLOTS-MANDATORY-MISFIT')
	public function testAMandatoryParameterIsNeverSkipped(): Void {
		Assert.same([[0]], runs([mandatory(), opt()], [[MayFit, MayFit]]));
		Assert.same([], runs([mandatory(), opt()], [[Misfits, Fits]]));
	}

	/** A rest parameter takes every argument left, each of its element type, and may take none. */
	@:pin('control')
	@:killer('M-SLOTS-REST-ONCE')
	public function testARestParameterTakesEveryArgumentLeft(): Void {
		Assert.same([[0, 1, 1]], runs([opt(), rest()], [[Fits, MayFit], [Misfits, Fits], [Misfits, Fits]]));
		Assert.same([[]], runs([opt(), rest()], []));
		Assert.same([], runs([rest()], [[Misfits]]));
	}

	/** More arguments than parameters can bind, or a mandatory parameter no argument reaches, is no run. */
	@:pin('control')
	@:killer('M-SLOTS-UNBOUND-MANDATORY')
	public function testTooManyArgumentsOrTooFewAreNoRun(): Void {
		Assert.same([], runs([opt()], [[Fits], [Fits]]));
		Assert.same([], runs([mandatory(), mandatory()], [[Fits, Fits]]));
	}

	/** Past `MAX_RUNS` ways the answer is none at all, never a partial list. */
	@:pin('control')
	@:killer('M-SLOTS-OVERFLOW-PARTIAL')
	public function testTooManyWaysAnswerNone(): Void {
		final params: Array<SlotParam> = [for (_ in 0...8) opt()];
		final fits: Array<Array<ArgumentFit>> = [for (_ in 0...4) [for (_ in 0...8) MayFit]];
		Assert.isNull(ArgumentSlots.runs(params, fits.length, (a, p) -> fits[a][p]));
	}

	private static function runs(params: Array<SlotParam>, fits: Array<Array<ArgumentFit>>): Null<Array<Array<Int>>> {
		return ArgumentSlots.runs(params, fits.length, (a, p) -> fits[a][p]);
	}

	private static inline function opt(): SlotParam {
		return { optional: true, rest: false };
	}

	private static inline function mandatory(): SlotParam {
		return { optional: false, rest: false };
	}

	private static inline function rest(): SlotParam {
		return { optional: false, rest: true };
	}

}
