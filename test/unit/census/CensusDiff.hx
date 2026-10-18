package unit.census;

/**
 * The failure message the root's parity censuses share (`unit.PinCensusParityTest`,
 * `unit.ArmCensusParityTest`): a hand-kept list against the generated registry it snapshots.
 */
@:nullSafety(Strict)
final class CensusDiff {

	/**
	 * Enriches a plain failure message with the specific names two hand-maintained
	 * lists disagree on, so a divergence names the vanished or added record
	 * instead of leaving only the failing test METHOD to go on — `Assert.same`
	 * discards its own computed diff whenever a caller passes a custom message. A
	 * pass appends nothing: `baseMsg` reaches `Assert.same` unchanged.
	 */
	public static function diffedMsg(expected: Array<String>, actual: Array<String>, baseMsg: String): String {
		final missing: Array<String> = [for (name in expected) if (!actual.contains(name)) name];
		final extra: Array<String> = [for (name in actual) if (!expected.contains(name)) name];
		final parts: Array<String> = [];
		if (missing.length > 0) parts.push('missing: ${missing.join(', ')}');
		if (extra.length > 0) parts.push('extra: ${extra.join(', ')}');
		return parts.length == 0 ? baseMsg : '$baseMsg (${parts.join('; ')})';
	}

}
