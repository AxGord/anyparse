package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;

/**
 * The one answer to "which readers delimit this grammar's conditional-compilation condition": the `@:scan` reader of
 * the terminal the grammar marks `@:condRegionCondition` and the reader its `@:condRegionBlank` names for the blank
 * before and after the condition, or null when the grammar marks no condition terminal. The generated parser's splice
 * predicates and the query walker's published `conditionEnd` / `conditionBlankEnd` read them here, so the grammar's
 * condition terminal is the one place that names them.
 */
final class CondConditionReader {

	/** The opt-in a grammar puts on its condition terminal. */
	public static inline final META: String = ':condRegionCondition';

	/** The meta on the condition terminal naming the reader of the blank around a condition. */
	private static final BLANK_META: String = ':condRegionBlank';

	/** The qualified static readers of `shape`'s condition terminal, or null when the grammar declares none. */
	public static function of(shape: ShapeBuilder.ShapeResult): Null<CondReaders> {
		var found: Null<CondReaders> = null;
		for (name => node in shape.rules) if (node.kind == Terminal && MetaInspect.hasMeta(node, META)) {
			final condition: String = MetaInspect.readMetaString(node, ':scan') ?? Context.fatalError(
				'$name: a @$META terminal names the reader of its extent by @:scan', Context.currentPos()
			);
			final blank: String = MetaInspect.readMetaString(node, BLANK_META) ?? Context.fatalError(
				'$name: a @$META terminal names the reader of its blank by @$BLANK_META', Context.currentPos()
			);
			if (found != null && (found.condition != condition || found.blank != blank))
				Context.fatalError(
					'$name: a grammar declares one condition reader, found ${found.condition} and $condition', Context.currentPos()
				);
			found = { condition: condition, blank: blank };
		}
		return found;
	}

}
/** The qualified static readers a grammar's condition terminal names: the condition's extent and the blank around it. */
typedef CondReaders = {

	/** Where a condition starting at `at` ends, `at` when none. */
	final condition: String;

	/** Where the blank starting at `at` ends, `at` when none. */
	final blank: String;

}
#end
