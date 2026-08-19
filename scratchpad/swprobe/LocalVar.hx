class LocalVar {
	public static function pick(text: String, target: String, other: String): Int {
		return if (text == target)
			1
		else if (text == other)
			2
		else
			0;
	}
}
