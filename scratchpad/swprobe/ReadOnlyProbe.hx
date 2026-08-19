class ReadOnlyProbe {
	public static var NEVER(default, never): String = 'n';
	public static var NULLW(default, null): String = 'w';

	static function f(text: String): Int {
		return switch (text) {
			case NEVER: 1;
			case _: 0;
		}
	}

	static function g(text: String): Int {
		return switch (text) {
			case NULLW: 1;
			case _: 0;
		}
	}

	public static function main() {
		Sys.println(f('n') + ' ' + f('zzz') + ' | ' + g('w') + ' ' + g('zzz'));
	}
}
