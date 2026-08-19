class ShadowProbe {
	static inline final ALPHA: String = 'a';
	static inline final BETA: String = 'b';

	static function f(text: String): Int {
		final ALPHA = 'x';
		final BETA = 'y';
		return switch (text) {
			case ALPHA: 1;
			case BETA: 2;
			case _: 0;
		}
	}

	public static function main() {
		Sys.println(f('x') + ' ' + f('y') + ' ' + f('zzz') + ' ' + f('a'));
	}
}
