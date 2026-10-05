package anyparse.query;

using StringTools;

/** One `APQ_TEST` token: the class substring it selects, and which slice of that class's tests it runs. */
typedef ShardToken = {
	cls: String,
	part: Int,
	parts: Int
};

/**
 * The `APQ_TEST` token grammar `ShardPlan` writes and `RunTests` reads: a bare class substring runs every test of each
 * class it selects, and `<class>#<i>/<k>` runs the `i`-th of `k` slices of them.
 *
 * A slice exists because one class can outweigh a whole shard. `unit.query.MemberReachFactsTest` measured 271 s of a
 * 470 s suite — its fixtures each compile twice — so with whole classes as the unit no plan finishes before that one
 * process does, and seven of eight shards idled for four minutes. Slice `i` of `k` is every test name whose index in the
 * SORTED name list is `i` modulo `k`: a pure function of the name list, so the `k` slices are disjoint and cover the
 * class whatever order the runner lists the names in.
 */
@:nullSafety(Strict)
final class ShardFilter {

	/** Separates a token's class substring from its slice. */
	private static inline final SLICE_MARK: String = '#';

	private static inline final SLICE_SEPARATOR: String = '/';

	/** The token running slice `part` of `parts` of `cls`, or `cls` itself for a whole class. */
	public static function render(cls: String, part: Int, parts: Int): String {
		return parts == 1 ? cls : '$cls$SLICE_MARK$part$SLICE_SEPARATOR$parts';
	}

	/** The token `raw` read back; throws on a slice that is not two integers `0 <= i < k`. */
	public static function parse(raw: String): ShardToken {
		final at: Int = raw.indexOf(SLICE_MARK);
		if (at < 0) return { cls: raw, part: 0, parts: 1 };
		final slice: Array<String> = raw.substr(at + 1).split(SLICE_SEPARATOR);
		final part: Int = (slice.length == 2 ? digits(slice[0]) : null) ?? -1;
		final parts: Int = (slice.length == 2 ? digits(slice[1]) : null) ?? 0;
		if (part < 0 || part >= parts) throw 'APQ_TEST token "$raw": a slice is #<i>/<k> with 0 <= i < k';
		return { cls: raw.substr(0, at), part: part, parts: parts };
	}

	/**
	 * Which of `names`, the test methods of the class `className`, the tokens `tokens` run: null for every one of them
	 * (a whole-class token selects it), else the union of the slices the tokens selecting it name — empty when none does.
	 */
	public static function selected(className: String, names: Array<String>, tokens: Array<ShardToken>): Null<Array<String>> {
		final sorted: Array<String> = names.copy();
		sorted.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		final out: Array<String> = [];
		for (token in tokens) if (className.indexOf(token.cls) >= 0) {
			if (token.parts == 1) return null;
			for (i in 0...sorted.length) if (i % token.parts == token.part && !out.contains(sorted[i])) out.push(sorted[i]);
		}
		return out;
	}

	/** `text` as a non-negative decimal integer, or null. */
	private static function digits(text: String): Null<Int> {
		return new EReg('^[0-9]+$', '').match(text) ? Std.parseInt(text) : null;
	}

}
