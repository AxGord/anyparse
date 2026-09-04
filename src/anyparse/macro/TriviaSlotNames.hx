package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;

using anyparse.macro.MetaInspect;

/**
 * The generated parser\'s trivia-slot local names.
 *
 * Each of these is one spelling of a local the generated parse body
 * DECLARES in one emitter and READS in another — the before-newline
 * flag, the leading-gap comment array, the trailing open / close /
 * blank slots. A mismatch between the two sides is not a macro compile
 * error: it is an undefined local in the GENERATED parser, which is why
 * every name is spelled exactly once, here, instead of being repeated
 * at each emitter.
 *
 * They live outside `Lowering` for the same reason they live in one
 * function each — the vocabulary is shared by `Lowering`\'s field
 * emitters, `TriviaTypeSynth`\'s slot synthesis and the struct-literal
 * build that reads them back, and a name is easier to keep single when
 * it has an address.
 */
final class TriviaSlotNames {

	/**
	 * Name of the `Bool` local that records whether the trailing
	 * trivia run captured on a `@:trivia` Star's final iteration
	 * crossed a blank line. Shared between `emitTriviaStarFieldSteps`
	 * (the producer) and `lowerStruct`'s Seq-child loop (the consumer
	 * that pushes it into the struct literal).
	 */
	public static inline function trailingBlankBeforeLocalName(localName: String): String return '${localName}_trailBB';

	/**
	 * ω-keep-fnsig-newline: name of the `Bool` local that records whether the
	 * source had at least one newline (not necessarily a blank line) between
	 * the last `@:trivia` Star element and the close literal. Sibling of
	 * `trailingBlankBeforeLocalName`; set from the same terminal
	 * `_lead.newlineBefore`. Consumed by the writer's `_keepEmit` close
	 * placement to round-trip a kept signature's glued-vs-own-line close.
	 */
	public static inline function trailingNewlineBeforeLocalName(localName: String): String return '${localName}_trailNL';

	/**
	 * Name of the `Array<String>` local that records the own-line
	 * comments captured on a `@:trivia` Star's final iteration (after
	 * the last element, before the close / EOF).
	 */
	public static inline function trailingLeadingLocalName(localName: String): String return '${localName}_trailLC';

	/**
	 * Name of the `Null<String>` local that records a same-line
	 * trailing comment captured right after a close-peek `@:trivia`
	 * Star's close literal (ω-close-trailing). Only declared in the
	 * close-peek branch of `emitTriviaStarFieldSteps`; the EOF and
	 * try-parse branches skip it.
	 */
	public static inline function trailingCloseLocalName(localName: String): String return '${localName}_trailClose';

	/**
	 * Name of the `Null<String>` local that records a same-line trailing
	 * comment captured right after a `@:trivia` Star's open literal
	 * (ω-open-trailing). Mirror of `trailingCloseLocalName`. Only declared
	 * in branches of `emitTriviaStarFieldSteps` that emit the open lit
	 * (i.e. `openText != null`).
	 */
	public static inline function trailingOpenLocalName(localName: String): String return '${localName}_trailOpen';

	/**
	 * Name of the `Bool` local carrying a bare non-first Ref's `<field>BeforeNewline`
	 * slot value (ω-issue-48-v2), and of the `Array<String>` local carrying its
	 * `<field>BeforeLeading` gap comments (ω-598-member-leading-comment).
	 *
	 * Two emitters declare them — `emitPreFieldWs` for the mandatory field and
	 * `emitAbsentOnBeforeSlots` for the `@:fmt(bareRefSepWhenPresent)` optional one —
	 * and `lowerStruct`'s struct-literal build reads them back by name. Spelling the
	 * name in one place is what keeps those three from drifting apart silently: a
	 * mismatch is not a compile error in the macro, only an undefined local in the
	 * GENERATED parser.
	 */
	public static inline function beforeNewlineLocalName(fieldName: String): String return '_beforeNl_$fieldName';

	/** Sibling of `beforeNewlineLocalName` for the `<field>BeforeLeading` slot. */
	public static inline function beforeLeadingLocalName(fieldName: String): String return '_beforeLeadCm_$fieldName';

	/**
	 * ω-region-prefix-blank — hosts of `<field>BeforeBlank`: a bare non-first Ref
	 * (one that already grew `BeforeLeading`, so the same `collectTrivia` scan
	 * fills all three) that opts in with `@:fmt(keepBlankAfterStarCtor(...))`.
	 * Spelled to agree with `TriviaTypeSynth.isBeforeBlankRef` and
	 * `WriterLowering`'s consume gate — the three decide synthesise / capture /
	 * consume for ONE slot, and only an identical spelling makes the agreement
	 * checkable by eye.
	 */
	public static inline function hasBeforeBlankSlotFor(child: ShapeNode, hasBeforeLeadingSlot: Bool): Bool {
		return hasBeforeLeadingSlot && child.fmtReadStringArgs('keepBlankAfterStarCtor') != null;
	}

	public static inline function beforeBlankLocalName(fieldName: String): String return '_beforeBlank_$fieldName';

	/**
	 * Name of the `Bool` local that records whether a tryparse+nestBody
	 * Star's stashed orphan trail run was followed by a blank line
	 * (ω-trail-blank-after). Mirrors `trailingBlankBeforeLocalName` —
	 * the "after" cousin records gap between trail and the next outer
	 * sibling, while "before" records gap between the last body element
	 * and the trail itself.
	 */
	public static inline function trailingBlankAfterLocalName(localName: String): String return '${localName}_trailBA';

	/**
	 * Name of the `Bool` local that records whether the source had a
	 * trailing separator after the last element of a `@:trivia` sep-Star
	 * with a close literal (ω-objectlit-source-trail-comma). Set by the
	 * per-iteration `matchLit(sepText)` capture inside
	 * `emitTriviaStarFieldSteps`'s sep+close branch; pushed into the
	 * synth pair's `<field>TrailPresent` slot by `lowerStruct`. Consumed
	 * by the writer's `WrapList.emit` call as the `forceExceeds` flag.
	 */
	public static inline function trailPresentLocalName(localName: String): String return '${localName}_trailPresent';

}
#end
