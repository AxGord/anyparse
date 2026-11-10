package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;

/**
 * The one answer to "which reader ends this grammar's conditional-compilation condition": the `@:scan` reader of the
 * terminal the grammar marks `@:condRegionCondition`, or null when it marks none. The generated parser's splice
 * predicates and the query walker's published `conditionEnd` both read it here, so the grammar's condition terminal
 * is the one place that names it.
 */
final class CondConditionReader {

	/** The opt-in a grammar puts on its condition terminal. */
	public static inline final META: String = ':condRegionCondition';

	/** The qualified static reader of `shape`'s condition terminal, or null when the grammar declares none. */
	public static function of(shape: ShapeBuilder.ShapeResult): Null<String> {
		var found: Null<String> = null;
		for (name => node in shape.rules) if (node.kind == Terminal && MetaInspect.hasMeta(node, META)) {
			final reader: Null<String> = MetaInspect.readMetaString(node, ':scan');
			if (reader == null)
				Context.fatalError('$name: a @$META terminal names the reader of its extent by @:scan', Context.currentPos());
			if (found != null && found != reader)
				Context.fatalError('$name: a grammar declares one condition reader, found $found and $reader', Context.currentPos());
			found = reader;
		}
		return found;
	}

}
#end
