package unit.miniblockstrict;

import anyparse.format.ArrayMatrixWrap;
import anyparse.format.CommentStyle;
import anyparse.format.ConditionalIndentationPolicy;
import anyparse.format.Encoding;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.UnknownPolicy;

/**
 * Pilot format for the `MiniBlockStrict` `sepStartsElement` flag
 * validation (BlockBody Star Session 9). Mirrors
 * `unit.miniblock.MiniBlockFormat` structurally; the only behavioral
 * difference is the consumer grammar's `@:sep` flag, not this class.
 *
 * Predicate `endsImplicitly` exercises BOTH paths of the byte-check
 * OR predicate-call disjunction:
 *  - `Block(_)` → true. Redundant with the byte-check `}`.
 *  - `EmptyAtom` → true. Body IS `;`, so byte-check `;` ALSO matches;
 *    this predicate path is symmetric.
 *  - `Atom('end')` → true. Byte-check on `end` fails — predicate is
 *    the sole reason `{end b}` permits sep elision.
 *  - anything else → false.
 */
@:nullSafety(Strict)
final class MiniBlockStrictFormat {

	public static final instance:MiniBlockStrictFormat = new MiniBlockStrictFormat();

	public var name(default, null):String = 'MiniBlockStrict';
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
		arrayMatrixWrap: ArrayMatrixWrap.NoMatrixWrap,
		conditionalPolicy: ConditionalIndentationPolicy.Aligned,
		addLineCommentSpace: true,
		compressSuccessiveParenthesis: true,
	};

	private function new() {}

	public function escapeChar(c:Int):String {
		return String.fromCharCode(c);
	}

	public function endsImplicitly(item:Null<MiniBlockStrict>):Bool {
		return switch item {
			case null: false;
			case Block(_): true;
			case EmptyAtom: true;
			case Atom(s) if ((s : String) == 'end'): true;
			case _: false;
		};
	}
}
