class NamedConst {
	static inline final TRUE_LITERAL: String = 'true';
	static inline final FALSE_LITERAL: String = 'false';

	public static function pick(text: String): Null<Bool> {
		return if (text == TRUE_LITERAL)
			true
		else if (text == FALSE_LITERAL)
			false
		else
			null;
	}
}
