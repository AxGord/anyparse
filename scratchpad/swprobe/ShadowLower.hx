class ShadowLower {
	static inline final alpha: String = 'a';
	static inline final beta: String = 'b';

	static function f(text: String): Int {
		final alpha = 'x';
		final beta = 'y';
		return switch (text) {
			case alpha: 1;
			case beta: 2;
			case _: 0;
		}
	}

	public static function main() {
		Sys.println(f('x') + ' ' + f('y') + ' ' + f('zzz') + ' ' + f('a'));
	}
}
