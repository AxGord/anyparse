package anyparse.format;

/**
 * Indent character selection for text writers.
 */
enum abstract IndentChar(String) to String {

	/**
	 * A horizontal tab (`\t`).
	 */
	var Tab = '\t';

	/**
	 * A space character.
	 */
	var Space = ' ';
}
