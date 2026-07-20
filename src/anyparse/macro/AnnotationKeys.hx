package anyparse.macro;

/**
 * Named constants for the annotation keys that form the string contract between the macro passes (`ShapeBuilder` / `Lowering` set them; `WriterLowering` and the trivia / span synths read them via `annotations.get`/`set`). Extracting the keys here makes a typo in one of the many `.get`/`.set` sites a compile error instead of a silently-missed annotation.
 */
@:nullSafety(Strict)
final class AnnotationKeys {

	public static final LIT_SEP_STARTS_ELEMENT: String = 'lit.sepStartsElement';
	public static final LIT_SEP_TAIL_RELAX: String = 'lit.sepTailRelax';
	public static final LIT_SEP_ALT_TEXT: String = 'lit.sepAltText';
	public static final TERNARY_SEP: String = 'ternary.sep';
	public static final TERNARY_PREC: String = 'ternary.prec';
	public static final PRATT_ASSOC: String = 'pratt.assoc';
	public static final PRATT_OP: String = 'pratt.op';
	public static final TRIVIA_STAR_COLLECTS: String = 'trivia.starCollects';
	public static final TRIVIA_BEARING: String = 'trivia.bearing';
	public static final PRATT_PREC: String = 'pratt.prec';
	public static final TERNARY_OP: String = 'ternary.op';
	public static final PREFIX_OP: String = 'prefix.op';
	public static final POSTFIX_CLOSE: String = 'postfix.close';
	public static final POSTFIX_OP: String = 'postfix.op';
	public static final KW_LEAD_TEXT: String = 'kw.leadText';
	public static final LIT_LIT_LIST: String = 'lit.litList';
	public static final LIT_TRAIL_OPTIONAL: String = 'lit.trailOptional';
	public static final LIT_SEP_BLOCK_ENDED_PREDICATE: String = 'lit.sepBlockEndedPredicate';
	public static final LIT_SEP_BLOCK_ENDED: String = 'lit.sepBlockEnded';
	public static final LIT_SEP_TEXT: String = 'lit.sepText';
	public static final LIT_TRAIL_TEXT: String = 'lit.trailText';
	public static final LIT_LEAD_TEXT: String = 'lit.leadText';
	public static final BASE_FIELD_TYPE: String = 'base.fieldType';
	public static final BASE_TYPE_PATH: String = 'base.typePath';
	public static final BASE_META: String = 'base.meta';
	public static final BASE_OPTIONAL: String = 'base.optional';
	public static final BASE_FIELD_NAME: String = 'base.fieldName';
	public static final BASE_CTOR: String = 'base.ctor';
	public static final BASE_REF: String = 'base.ref';

	private function new() {}

}
