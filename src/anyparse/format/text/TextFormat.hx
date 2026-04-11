package anyparse.format.text;

import anyparse.format.Format;

/**
 * Shape of an inline block comment delimiter pair.
 */
typedef BlockComment = {
	open:String,
	close:String,
};

/**
 * Spelling of a format's boolean literals. `null` on the containing
 * `TextFormat.boolLiterals` means the format has no boolean type.
 */
typedef BoolLiterals = {
	trueLit:String,
	falseLit:String,
};

/**
 * Result of `TextFormat.unescapeChar`. `char` is the decoded Unicode
 * code point; `consumed` is the number of input characters the escape
 * sequence occupied *after* the leading backslash.
 */
typedef UnescapeResult = {
	char:Int,
	consumed:Int,
};

/**
 * Structured-text format interface. Describes the literal vocabulary
 * and policies of JSON-like formats (JSON, JSON5, YAML flow, TOML,
 * INI, S-expressions, HJSON, etc.) using a mapping/sequence/scalar
 * structural model.
 *
 * Format plugins provide an instance (typically a singleton) whose
 * fields the writer and the macro read at compile or runtime. There is
 * no hidden `@:json` metadata — `JsonFormat` is an ordinary class
 * implementing this interface.
 */
interface TextFormat extends Format {
	var mappingOpen(default, null):String;
	var mappingClose(default, null):String;
	var sequenceOpen(default, null):Null<String>;
	var sequenceClose(default, null):Null<String>;
	var keyValueSep(default, null):String;
	var entrySep(default, null):String;

	var whitespace(default, null):String;
	var lineComment(default, null):Null<String>;
	var blockComment(default, null):Null<BlockComment>;

	var keySyntax(default, null):KeySyntax;
	var stringQuote(default, null):Array<String>;

	var fieldLookup(default, null):FieldLookup;

	var trailingSep(default, null):TrailingSepPolicy;
	var onMissing(default, null):MissingPolicy;
	var onUnknown(default, null):UnknownPolicy;

	var intLiteral(default, null):EReg;
	var floatLiteral(default, null):EReg;
	var boolLiterals(default, null):Null<BoolLiterals>;
	var nullLiteral(default, null):Null<String>;

	/**
	 * Escape a single Unicode code point into the format's string
	 * literal syntax. Must return a string that can be emitted verbatim
	 * between the format's string quote characters.
	 */
	function escapeChar(c:Int):String;

	/**
	 * Decode one escape sequence starting *after* the leading backslash
	 * at `pos` in `input`. Returns the decoded code point and how many
	 * characters of `input` were consumed by the escape body.
	 */
	function unescapeChar(input:String, pos:Int):UnescapeResult;
}
