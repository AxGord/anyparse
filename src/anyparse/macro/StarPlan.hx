package anyparse.macro;

#if macro
import anyparse.core.ShapeTree.ShapeNode;
#end

/**
 * The one answer to "what does a writer Star's grammar metadata ask its emitter for": each method is one `@:fmt` flag,
 * argument list or `lit.*` annotation of the Star, named after it and typed, read lazily through `StarMeta`. Plain data
 * with no `Expr` in it, so a new Star input is one method of the family's plan and its reader in the emitter, and a
 * plan answers without a macro context. This class holds what several Star families read; `TryparseStarPlan`,
 * `BlockStarPlan` and `SepStarPlan` add what one family alone reads.
 */
class StarPlan {

	private final _meta: StarMeta;

	public function new(meta: StarMeta) {
		_meta = meta;
	}

	public inline function propagateExprPosition(): Bool return _meta.flag('propagateExprPosition');

	public inline function clearExprPositionNonTail(): Bool return _meta.flag('clearExprPositionNonTail');

	public inline function glueToPrevious(): Null<Array<String>> return _meta.args('glueToPrevious');

	public inline function uniformStmtBlanks(): Bool return _meta.flag('uniformStmtBlanks');

	public inline function relocateTrailingComments(): Bool return _meta.flag('relocateTrailingComments');

	public inline function beforeDocCommentEmptyLines(): Bool return _meta.flag('beforeDocCommentEmptyLines');

	/** The separator text of `@:sep('text', …)`, or null. */
	public inline function sepText(): Null<String> return _meta.annotation(AnnotationKeys.LIT_SEP_TEXT);

	/** The predicate a blockEnded separator asks whether an element ends in a block, or null. */
	public inline function blockEndedPredicate(): Null<String> return _meta.annotation(AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE);

	/** `@:sep(text, tailRelax, blockEnded)`: the separator is owed only after an element not ending in a block. */
	public function blockEnded(): Bool return _meta.annotation(AnnotationKeys.LIT_SEP_BLOCK_ENDED) == true;

	/** `@:sepFaithful`: the separator is re-emitted where the source wrote it. */
	public function sepFaithful(): Bool return _meta.annotation('lit.sepFaithful') == true;

	/** The argument list of `@:fmt(<name>(…))`: null when the flag is absent, empty when it is bare. */
	private function flagArgs(name: String): Null<Array<String>> {
		return _meta.flag(name) ? _meta.args(name) ?? [] : null;
	}

	/** The first argument of `@:fmt(<name>(…))`, or null when the flag is absent or bare. */
	private function firstArg(name: String): Null<String> {
		final args: Null<Array<String>> = _meta.args(name);
		return args != null && args.length >= 1 ? args[0] : null;
	}

	#if macro
	/** How a plan reads a grammar Star node: through `MetaInspect` and the node's annotations. */
	public static function metaOf(node: ShapeNode): StarMeta {
		return {
			flag: name -> MetaInspect.fmtHasFlag(node, name),
			args: name -> MetaInspect.fmtReadStringArgs(node, name),
			string: name -> MetaInspect.fmtReadString(node, name),
			annotation: key -> node.annotations[key]
		};
	}
	#end

}

/** How a `StarPlan` reads its Star: the `@:fmt` flags, argument lists and strings, and the strategy annotations. */
typedef StarMeta = {
	final flag: String -> Bool;
	final args: String -> Null<Array<String>>;
	final string: String -> Null<String>;
	final annotation: String -> Dynamic;
}
