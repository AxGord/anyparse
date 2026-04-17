package anyparse.grammar.ar;

/**
 * One member file in a Unix ar archive.
 *
 * Header fields are fixed-width ASCII, right-padded with spaces. On
 * parse trailing spaces are stripped and numeric fields are decoded
 * to `Int`; on write the reverse transformation is applied. The payload
 * length lives in a 10-byte decimal prefix immediately before the
 * 2-byte `` `\n `` header terminator — neither is exposed as an AST
 * field. Entries are 2-byte aligned — an odd-length payload is
 * followed by a single `\n` padding byte.
 */
@:align(2)
typedef ArEntry = {

	/** File name (16 bytes). `/`-terminated for short names, space-padded. */
	@:bin(16) var name:String;

	/** Modification time as unix seconds (12 bytes decimal). */
	@:bin(12, Dec) var mtime:Int;

	/** Owner UID (6 bytes decimal). */
	@:bin(6, Dec) var ownerId:Int;

	/** Group GID (6 bytes decimal). */
	@:bin(6, Dec) var groupId:Int;

	/** File mode in octal (8 bytes). e.g. `0o100644` for a regular file. */
	@:bin(8, Oct) var mode:Int;

	/**
	 * Raw file data. Preceded by a 10-byte decimal size prefix and the
	 * 2-byte `` `\n `` header terminator; both are handled by the
	 * macro-generated parser/writer and do not appear in the AST.
	 */
	@:length(10, Dec) @:lead("`\n") var data:haxe.io.Bytes;
};
