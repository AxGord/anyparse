class CaseProbe {
	static inline final alpha: String = 'a';
	static inline final beta: String = 'b';
	static inline final ALPHA: String = 'a';

	static function lower(text: String): Int {
		return switch (text) {
			case alpha: 1;
			case beta: 2;
			case _: 0;
		}
	}

	static function upper(text: String): Int {
		return switch (text) {
			case ALPHA: 1;
			case _: 0;
		}
	}

	public static function main() {
		Sys.println('lower: ' + lower('a') + ' ' + lower('b') + ' ' + lower('zzz'));
		Sys.println('upper: ' + upper('a') + ' ' + upper('zzz'));
	}
}
