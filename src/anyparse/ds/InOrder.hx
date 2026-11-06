package anyparse.ds;

/**
 * The one answer to "which positions of a sequence of distinct integers fall outside its heaviest in-order run": the
 * positions a reorder genuinely moves, where the rest keep their relative order. This package imports nothing from
 * `anyparse.*`.
 */
final class InOrder {

	/**
	 * Per position of `order`, whether it belongs to the increasing subsequence of greatest total `weight` (each position
	 * weighs 1 when `weight` is null); of several equally heavy ones the one met first is taken.
	 */
	public static function kept(order: Array<Int>, ?weight: Int -> Int): Array<Bool> {
		final run: Array<Int> = [];
		final link: Array<Int> = [];
		var best: Int = -1;
		for (k => here in order) {
			var prefix: Int = 0;
			var before: Int = -1;
			for (j in 0...k) if (order[j] < here && run[j] > prefix) {
				prefix = run[j];
				before = j;
			}
			run.push(prefix + (weight == null ? 1 : weight(k)));
			link.push(before);
			if (best < 0 || run[k] > run[best]) best = k;
		}
		final inRun: Array<Bool> = [for (_ in order) false];
		while (best >= 0) {
			inRun[best] = true;
			best = link[best];
		}
		return inRun;
	}

}
