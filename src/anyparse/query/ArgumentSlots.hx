package anyparse.query;

/**
 * How an argument meets the type of a parameter, as far as a typer can prove it: it unifies (`Fits`), it does not
 * (`Misfits`), or the typer cannot tell (`MayFit`).
 */
enum ArgumentFit {
	Fits;
	Misfits;
	MayFit;
}

/** A parameter as a call binds it: one a call may leave out (`?p`, `p = v`), the rest parameter. */
typedef SlotParam = {
	final optional: Bool;
	final rest: Bool;
}

/**
 * THE model of how a call binds its arguments to the parameters of the function it calls — every reader that asks which
 * parameter an argument lands on asks here. Haxe 4.3.7 binds GREEDILY, argument by argument and never backtracking
 * (`f(?a:Int, ?b:String, c:Int)` called `f(1)` is an error, not `c = 1`): an argument that unifies with the parameter it
 * meets binds it; one that does not skips that parameter when it is optional — the default applies — and meets the next;
 * a mandatory parameter it does not unify with is a compile error; a rest parameter takes every argument left, each of its
 * element type; arguments left over, or a mandatory parameter left unbound, are an error.
 *
 * What a typer cannot decide (`MayFit`) is followed both ways at an optional parameter, and a run that ends in an error is
 * dropped: the code compiles, so the binding the compiler made is among the runs answered. Haxe also refuses some skips
 * this model takes (two arguments or more skipping into a rest parameter, `e(?n:Int, ...r:String)` called `e('a', 'b')`),
 * which only drops runs the model keeps: the answer stays a superset of the compiler's.
 */
@:nullSafety(Strict)
final class ArgumentSlots {

	/** The most runs answered: a call with more ways to bind answers none. */
	public static inline final MAX_RUNS: Int = 64;

	/**
	 * Every way a call passing `count` arguments may bind them to `params`, as far as `fit` decides each argument against
	 * each parameter: per run, the parameter each argument binds, in argument order. Empty when no run compiles; null past
	 * `MAX_RUNS`.
	 */
	public static function runs(params: Array<SlotParam>, count: Int, fit: (arg:Int, param:Int) -> ArgumentFit): Null<Array<Array<Int>>> {
		final walk: SlotWalk = {
			params: params,
			count: count,
			fit: fit,
			bound: [],
			out: [],
			overflow: false
		};
		step(walk, 0, 0);
		return walk.overflow ? null : walk.out;
	}

	/** Bind argument `arg` and the ones after it, meeting parameter `param` first. */
	private static function step(walk: SlotWalk, arg: Int, param: Int): Void {
		if (walk.overflow) return;
		final params: Array<SlotParam> = walk.params;
		if (arg == walk.count) {
			// every parameter left must be one a call may leave out
			for (p in param ... params.length) if (!params[p].optional && !params[p].rest) return;
			if (walk.out.length >= MAX_RUNS) {
				walk.overflow = true;
				return;
			}
			walk.out.push(walk.bound.copy());
			return;
		}
		if (param >= params.length) return;
		final p: SlotParam = params[param];
		final fit: ArgumentFit = walk.fit(arg, param);
		if (fit != Misfits) {
			walk.bound.push(param);
			step(walk, arg + 1, p.rest ? param : param + 1);
			walk.bound.pop();
		}
		if (p.optional && !p.rest && fit != Fits) step(walk, arg, param + 1);
	}

}

/** The state of one `ArgumentSlots.runs` walk: the runs found so far, and the binding of the one being built. */
private typedef SlotWalk = {
	final params: Array<SlotParam>;
	final count: Int;
	final fit: (arg:Int, param:Int) -> ArgumentFit;
	final bound: Array<Int>;
	final out: Array<Array<Int>>;
	var overflow: Bool;
}
