class Lit {
	public static function pick(text: String): Null<Bool> {
		return if (text == 'true')
			true
		else if (text == 'false')
			false
		else
			null;
	}
}
