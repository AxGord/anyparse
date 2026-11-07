package anyparse.query.cli;

/**
 * Whether the find-walks of one call found anything: the one answer to "did every run of this call find nothing".
 * The contexts of a call's runs share one, so `--exit-on-empty` judges the call, not each grammar's run; the dispatcher
 * makes one per call, never per process (invariant 1).
 */
@:nullSafety(Strict)
final class RunMatches {

	private var _asked: Bool = false;
	private var _found: Bool = false;

	public function new() {}

	/** Whether some find-walk answered and none of them found anything. */
	public inline function allEmpty(): Bool {
		return _asked && !_found;
	}

	/** Records one find-walk's answer, `empty` when it found nothing. */
	public function record(empty: Bool): Void {
		_asked = true;
		if (!empty) _found = true;
	}

}
