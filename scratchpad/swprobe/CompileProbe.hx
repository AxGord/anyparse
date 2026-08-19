class CompileProbe {
	static inline final T: String = 'true';
	static final PLAIN: String = 'plain';
	var mutable: String = 'm';

	public function new() {}

	// static inline final, bare
	public static function pickInline(text: String): Int {
		return switch (text) {
			case T: 1;
			case _: 0;
		}
	}

	// non-inline static final, bare
	public static function pickPlainFinal(text: String): Int {
		return switch (text) {
			case PLAIN: 1;
			case _: 0;
		}
	}

	// LOCAL variable as a pattern
	public static function pickLocal(text: String, target: String): Int {
		return switch (text) {
			case target: 1;
			case _: 0;
		}
	}

	public static function main() {
		Sys.println(pickInline('true') + ' ' + pickInline('zzz'));
		Sys.println(pickPlainFinal('plain') + ' ' + pickPlainFinal('zzz'));
		Sys.println(pickLocal('a', 'a') + ' ' + pickLocal('zzz', 'a'));
	}
}
