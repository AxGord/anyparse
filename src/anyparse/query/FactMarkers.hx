package anyparse.query;

import anyparse.query.CompilerFacts.FactNode;

using Lambda;
using StringTools;

/**
 * A marker a facts node carries (`FactNode.incomplete`), read: the vocabulary `TypedFactsWalk` and `CompilerFacts` write,
 * decided here once. Every reader of the markers switches over this enum, so a marker added to it is a compile error at
 * each reader until that reader decides what it does with it, and a text the vocabulary does not hold reads as `Unknown`.
 */
enum FactMarker {

	/** `stale-foreign`: a fact lies in a file whose text the table no longer has, and is lost to the node. */
	StaleForeign;

	/** `inline-site-unknown`: an inlined function was spliced in, whose facts sit at the callee's positions. */
	InlineSite;

	/** `macro-expansion`: an expression macro expanded into the body, code no text holds. */
	MacroExpansion;

	/** `reflection-inlined`: a `Reflect`/`Type` function was spliced in, and its call, name and arguments are gone. */
	ReflectionInlined;

	/** `reflection-unattributed`: a fact of such a body lies in no method's declared code. */
	ReflectionUnattributed;

	/** `reflection-from:<method>`: the method whose declared code holds a fact of such a body. */
	ReflectionFrom(method: String);

	/** Any other text: a marker no reader here knows, which may say anything of the node's facts. */
	Unknown(text: String);

}

/** The one reader of the markers a facts node carries (`FactMarker`). */
@:nullSafety(Strict)
final class FactMarkers {

	/** The prefix of the marker naming the method whose declared code holds a fact of a spliced reflective body. */
	private static inline final REFLECTION_FROM: String = 'reflection-from:';


	/** The marker `text` reads as; `Unknown` for one the vocabulary does not hold. */
	public static function read(text: String): FactMarker {
		return switch text {
			case 'stale-foreign': StaleForeign;
			case 'inline-site-unknown': InlineSite;
			case 'macro-expansion': MacroExpansion;
			case 'reflection-inlined': ReflectionInlined;
			case 'reflection-unattributed': ReflectionUnattributed;
			case _ if (text.startsWith(REFLECTION_FROM)): ReflectionFrom(text.substr(REFLECTION_FROM.length));
			case _: Unknown(text);
		};
	}

	/** Whether `n` carries a marker `decide` answers true for. */
	public static function carries(n: FactNode, decide: FactMarker -> Bool): Bool {
		return n.incomplete.exists(m -> decide(read(m)));
	}

	/** The first answer `decide` gives a marker `n` carries that is not null, or null when it gives none. */
	public static function first<T>(n: FactNode, decide: FactMarker -> Null<T>): Null<T> {
		for (m in n.incomplete) {
			final answer: Null<T> = decide(read(m));
			if (answer != null) return answer;
		}
		return null;
	}

	/** Why the node `id` carrying the marker `text` no reader knows is no node the facts answer for. */
	public static function unknownReason(id: String, text: String): String {
		return '`$id` carries the facts marker `$text`, which no reader here knows';
	}

}
