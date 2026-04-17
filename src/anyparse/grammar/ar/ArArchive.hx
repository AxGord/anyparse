package anyparse.grammar.ar;

/**
 * Grammar root for Unix ar archives (.a, .deb, .ipk).
 *
 * Structure: 8-byte magic `!<arch>\n` followed by zero or more
 * `ArEntry` members. Each entry has a 60-byte fixed-format ASCII
 * header and a variable-length data payload.
 */
@:peg
@:schema(anyparse.format.binary.ArFormat)
@:magic("!<arch>\n")
typedef ArArchive = {
	var entries:Array<ArEntry>;
};
