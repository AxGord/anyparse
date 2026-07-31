package anyparse.core;

/**
 * Process-wide opt-out switches read from the environment.
 *
 * One shared reading of "is this flag set?" so every switch answers the
 * same way: present and neither empty nor `0` means SET. `FLAG=0` and
 * `FLAG=` read as unset, which is what a shell exporting a computed value
 * (`FLAG=$STRICT`) expects.
 *
 * Targets without an environment (`js` in a browser) have no switches, so
 * every flag reads unset there.
 */
@:nullSafety(Strict)
final class EnvFlag {

	private function new() {}

	/** Whether `name` is set to anything other than the empty string or `0`. */
	public static function isSet(name: String): Bool {
		#if (sys || nodejs)
		final raw: Null<String> = Sys.getEnv(name);
		if (raw == null) return false;
		final trimmed: String = StringTools.trim(raw);
		return trimmed != '' && trimmed != '0';
		#else
		return false;
		#end
	}

}
