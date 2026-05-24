package unit.miniblock;

import anyparse.format.CommentStyle;
import anyparse.format.Encoding;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.UnknownPolicy;

/**
 * Pilot format for the `MiniBlock` BlockBody Star option (b2) AST-shape
 * adapter wiring validation ([[project-blockbody-star-session7-b2-infra]]).
 *
 * Provides the minimum surface `FormatReader.resolve` requires (literal
 * vocabulary, field-lookup policy, key-syntax) plus the instance method
 * `endsImplicitly` consulted by
 * `@:sep(';', tailRelax, blockEnded('endsImplicitly'))` on
 * `MiniBlock.Block.items`. The byte-check `}`/`;` is OR'd with this
 * predicate at parse time, so any prior element on which the predicate
 * returns true also permits sep elision between it and the next item.
 *
 * Predicate semantics — chosen to exercise BOTH paths of the OR:
 *  - `Block(_)` → true. Redundant with the byte-check `}` — proves the
 *    wiring is well-typed without changing behaviour.
 *  - `Atom('end')` → true. Byte-check on `end` fails (no `}`/`;`); the
 *    predicate is the sole reason `{end b}` parses without an explicit
 *    `;`. This is the cross-cutting test of the new mechanism.
 *  - anything else → false.
 *
 * Replaces the prior reuse of `JsonFormat` as a whitespace carrier
 * (`A dedicated MiniBlockFormat is overkill for a pilot` — true until
 * the schema-instance predicate API forced one).
 */
@:nullSafety(Strict)
final class MiniBlockFormat {

	public static final instance:MiniBlockFormat = new MiniBlockFormat();

	public var name(default, null):String = 'MiniBlock';
	public var version(default, null):String = '1.0';
	public var encoding(default, null):Encoding = Encoding.UTF8;

	public var whitespace(default, null):String = ' \t\n\r';

	public var mappingOpen(default, null):String = '{';
	public var mappingClose(default, null):String = '}';
	public var sequenceOpen(default, null):Null<String> = '[';
	public var sequenceClose(default, null):Null<String> = ']';
	public var keyValueSep(default, null):String = ':';
	public var entrySep(default, null):String = ';';

	public var keySyntax(default, null):KeySyntax = KeySyntax.Quoted;
	public var fieldLookup(default, null):FieldLookup = FieldLookup.ByName;
	public var onMissing(default, null):MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null):UnknownPolicy = UnknownPolicy.Skip;

	/**
	 * Default `WriteOptions` consumed by the generated writer's
	 * `publicEntry` when the caller omits the `options` argument.
	 * Values chosen for minimal-noise pilot output (tab indent,
	 * narrow line, no final newline) — the existing
	 * `MiniBlockWriter` tests pass options-less calls, so these
	 * defaults gate `Block` round-trip shape.
	 */
	public var defaultWriteOptions(default, null):WriteOptions = {
		indentChar: Tab,
		indentSize: 1,
		tabWidth: 4,
		lineWidth: 80,
		lineEnd: '\n',
		finalNewline: false,
		trailingWhitespace: false,
		maxConsecutiveBlanks: -1,
		commentStyle: Verbatim,
		addLineCommentSpace: true,
	};

	private function new() {}

	/**
	 * Identity passthrough — MiniBlock has no quoted-string atoms
	 * (`MiniAtomLit` is `@:rawString`), so the writer's
	 * `escapeString` helper is dead code at runtime. The macro
	 * still emits a reference to `instance.escapeChar` at compile
	 * time (`WriterCodegen.escapeStringField` is unconditional),
	 * which forces this method to exist. Plain `String.fromCharCode`
	 * is sufficient.
	 */
	public function escapeChar(c:Int):String {
		return String.fromCharCode(c);
	}

	public function endsImplicitly(item:Null<MiniBlock>):Bool {
		return switch item {
			case null: false;
			case Block(_): true;
			case Atom(s) if ((s : String) == 'end'): true;
			case _: false;
		};
	}
}
