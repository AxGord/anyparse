package anyparse.query;

/** One question's remembered answers, by the declaration each is about. */
@:nullSafety(Strict)
final class DeclarationQuery<V> {

	/** Key -> the answer, held in a box so a remembered `null` is told from an unasked key. */
	private final _answers: Map<String, { final value: V; }> = [];

	public function new() {}

	/** The answer for `key`: the remembered one, else `compute`'s, remembered. */
	public function answer(key: DeclarationKey, compute: () -> V): V {
		final at: String = key;
		final held: Null<{ final value: V; }> = _answers[at];
		if (held != null) return held.value;
		final value: V = compute();
		final box: { final value: V; } = { value: value };
		_answers[at] = box;
		return value;
	}

}
