package anyparse.check;

/**
 * Severity of a check `Violation`, ordered most- to least-serious.
 * Modelled as a zero-cost `enum abstract(Int)` because the level carries
 * no associated data; the ordinal doubles as a sort key (lower = more
 * serious) so a report can rank findings without a side table.
 *
 *  - `Error`   — a definite defect the check is confident about.
 *  - `Warning` — a likely defect; the default for `unused-import`.
 *  - `Info`    — an advisory the check cannot fully verify (e.g. a
 *    wildcard / `using` import whose usage is implicit).
 */
enum abstract Severity(Int) {

	final Error = 0;
	final Warning = 1;
	final Info = 2;

	/** Lower-case label used in report lines (`error` / `warning` / `info`). */
	public function label(): String {
		return switch (cast this: Severity) {
			case Error: 'error';
			case Warning: 'warning';
			case Info: 'info';
		}
	}

	/**
	 * Resolves a lower-case severity label (`error` / `warning` / `info`) to
	 * its `Severity`, or null when the name is unrecognised. The inverse of
	 * `label()`; shared by the `lint` CLI (`--fail-on`) and `LintConfig`.
	 */
	public static function fromName(name: String): Null<Severity> {
		return switch name {
			case 'error': Error;
			case 'warning': Warning;
			case 'info': Info;
			case _: null;
		};
	}

}
