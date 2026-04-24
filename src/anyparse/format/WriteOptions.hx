package anyparse.format;

/**
 * Base write options shared by all text writers.
 *
 * Per-grammar option typedefs extend this shape via struct intersection:
 * `typedef JValueWriteOptions = WriteOptions & { ... };`.
 * Resolution happens once in the generated `write()` entry point — the
 * internal `writeXxx` helpers see a fully populated, non-nullable struct.
 *
 * The format singleton owns the defaults (`JsonFormat.instance.defaultWriteOptions`,
 * `HaxeFormat.instance.defaultWriteOptions`): the format describes the
 * target language and therefore is the source of truth for its default
 * formatting style.
 */
typedef WriteOptions = {

	/**
	 * Character used to render one indent unit: tab or space.
	 */
	indentChar:IndentChar,

	/**
	 * Columns per indent level when `indentChar = Space`.
	 */
	indentSize:Int,

	/**
	 * Logical width of one tab character in columns. Used when
	 * `indentChar = Tab` to decide nesting width for line-fit
	 * calculations.
	 */
	tabWidth:Int,

	/**
	 * Target line width used by the Wadler-style renderer to pick
	 * between flat and broken layout for groups.
	 */
	lineWidth:Int,

	/**
	 * End-of-line sequence emitted by the writer. Declared in σ;
	 * honored once the renderer gains line-ending awareness.
	 */
	lineEnd:String,

	/**
	 * Whether the output ends with a newline. Declared in σ;
	 * honored once the renderer gains final-newline awareness.
	 */
	finalNewline:Bool,

	/**
	 * When `true`, blank lines between content carry the surrounding
	 * block's indent rather than rendering bare. Opt-in gate on top of
	 * the renderer's default deferred-indent, which silently drops
	 * indent on empty rows. Matches haxe-formatter's
	 * `indentation.trailingWhitespace` knob; default `false` keeps every
	 * other corpus case byte-identical.
	 */
	trailingWhitespace:Bool,

	/**
	 * Output wrap style for multi-line block comments. `Plain` emits
	 * `/*…*\/` with content-only interior lines; `Javadoc` emits
	 * `/**…**\/` with ` * ` markers on each content line. The parser
	 * strips both `*` markers and leading whitespace at capture time,
	 * so this knob fully drives the output appearance — source style
	 * is not echoed.
	 */
	commentStyle:CommentStyle,
};
