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

	/**
	 * Whether a call passing `count` arguments to `params` compiles, as far as `fit` decides each argument (`unify_call_args`,
	 * 4.3.7): `Misfits` when no way to bind them compiles (`runs` answers none), `Fits` when the compiler's own way — an
	 * argument that unifies binds the parameter it meets, one that does not skips an optional parameter while fewer
	 * arguments than parameters are left, a rest parameter takes every argument left — is decided at every step and ends
	 * bound, every skip one `skipSafe` allows (Flash refuses to skip a parameter whose type is not nullable,
	 * `pf_can_skip_non_nullable_argument`); `MayFit` otherwise.
	 */
	public static function compiles(
		params: Array<SlotParam>, count: Int, fit: (arg:Int, param:Int) -> ArgumentFit, skipSafe: (param:Int) -> Bool
	): ArgumentFit {
		final all: Null<Array<Array<Int>>> = runs(params, count, fit);
		return all != null && all.length == 0 ? Misfits : compilerPath(params, count, fit, skipSafe).verdict;
	}

	/**
	 * The parameter each argument binds on the compiler's own way (`compiles`), in argument order, when that way surely
	 * compiles; null otherwise.
	 */
	public static function compiledRun(
		params: Array<SlotParam>, count: Int, fit: (arg:Int, param:Int) -> ArgumentFit, skipSafe: (param:Int) -> Bool
	): Null<Array<Int>> {
		final path: CompilerPath = compilerPath(params, count, fit, skipSafe);
		return path.verdict == Fits ? path.bound : null;
	}

	/**
	 * The compiler's own way to bind `count` arguments to `params` (`unify_call_args`): an argument that unifies binds the
	 * parameter it meets, one that does not skips an optional parameter while fewer arguments than parameters are left, a
	 * rest parameter takes every argument left — followed while every fit on it is decided. Its verdict: `Misfits` where it
	 * fails, `Fits` where it ends bound with every skip one `skipSafe` allows, `MayFit` otherwise; and the parameter each
	 * argument it followed binds.
	 */
	private static function compilerPath(
		params: Array<SlotParam>, count: Int, fit: (arg:Int, param:Int) -> ArgumentFit, skipSafe: (param:Int) -> Bool
	): CompilerPath {
		final bound: Array<Int> = [];
		var arg: Int = 0;
		var param: Int = 0;
		var safe: Bool = true;
		while (arg < count) {
			if (param >= params.length) return { verdict: Misfits, bound: bound };
			final p: SlotParam = params[param];
			switch fit(arg, param) {
				case Fits:
					bound.push(param);
					arg++;
					if (!p.rest) param++;
				case Misfits if (!p.rest && p.optional && count - arg < params.length - param):
					if (!skipSafe(param)) safe = false;
					param++;
				case Misfits:
					return { verdict: Misfits, bound: bound };
				case MayFit:
					return { verdict: MayFit, bound: bound };
			}
		}
		for (q in param ... params.length) if (!params[q].optional && !params[q].rest) return { verdict: Misfits, bound: bound };
		return { verdict: safe ? Fits : MayFit, bound: bound };
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

/** The compiler's own way to bind a call's arguments (`ArgumentSlots.compilerPath`): its verdict, the parameter each bound. */
private typedef CompilerPath = {
	final verdict: ArgumentFit;
	final bound: Array<Int>;
}
