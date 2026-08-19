class NeverProbe {
	public static var NEVER(default, never): String = 'n';
	public static final PLAINFINAL: String = 'p';

	static function f(text: String): Int {
		return switch (text) {
			case NEVER: 1;
			case _: 0;
		}
	}

	static function g(text: String): Int {
		return switch (text) {
			case PLAINFINAL: 1;
			case _: 0;
		}
	}

	public static function main() {
		Sys.println(f('n') + ' ' + f('zzz') + ' | ' + g('p') + ' ' + g('zzz'));
	}
}
