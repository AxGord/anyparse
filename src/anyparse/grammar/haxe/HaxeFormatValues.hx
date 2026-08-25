package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.EmptyCurly;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.MetadataLineEndPolicy;
import anyparse.format.OptionalSemicolon;
import anyparse.format.RightCurlyPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.TrailingCommaPolicy;
import anyparse.format.UniformStatementBlanksPolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.format.HxBetweenImportsLevel;
import anyparse.grammar.haxe.format.HxFormatBodyPolicy;
import anyparse.grammar.haxe.format.HxFormatCommentEmptyLinesPolicy;
import anyparse.grammar.haxe.format.HxFormatEmptyCurlyPolicy;
import anyparse.grammar.haxe.format.HxFormatKeepEmptyLinesPolicy;
import anyparse.grammar.haxe.format.HxFormatKeywordPlacement;
import anyparse.grammar.haxe.format.HxFormatLeftCurlyPolicy;
import anyparse.grammar.haxe.format.HxFormatLineEndCharacter;
import anyparse.grammar.haxe.format.HxFormatMetadataLineEndPolicy;
import anyparse.grammar.haxe.format.HxFormatOptionalSemicolonPolicy;
import anyparse.grammar.haxe.format.HxFormatRightCurlyPolicy;
import anyparse.grammar.haxe.format.HxFormatSameLinePolicy;
import anyparse.grammar.haxe.format.HxFormatTrailingCommaPolicy;
import anyparse.grammar.haxe.format.HxFormatUniformStatementBlanksPolicy;
import anyparse.grammar.haxe.format.HxFormatWhitespacePolicy;
import anyparse.grammar.haxe.format.HxFormatWrappingTrailingCommaPolicy;

/**
 * The VALUE vocabulary of `hxformat.json`: one-to-one maps from the fork's config enums
 * (`HxFormat*Policy`, the `wrapping` strings) onto the runtime write-option values the writer
 * consumes (`anyparse.format.*`, `anyparse.format.wrap.*`).
 *
 * Split out of `HaxeFormatConfigLoader`, which keeps the SECTION side — walking a parsed
 * `HxFormatConfig` and deciding which knob each section writes. Nothing here reads a config
 * section or touches `HxModuleWriteOptions`: every member is a pure total function of one
 * policy token, lenient in the same direction as the loader (an unrecognised token maps to the
 * default arm, or to `null` for the `…FromString` readers whose caller then leaves the existing
 * option intact).
 */
@:nullSafety(Strict)
final class HaxeFormatValues {

	private static inline function trailingCommaToBool(policy: HxFormatTrailingCommaPolicy): Bool {
		return policy == HxFormatTrailingCommaPolicy.Yes;
	}

	private static function wrappingLocationFromString(s: String): Null<WrappingLocation> {
		return switch s {
			case 'beforeLast': WrappingLocation.BeforeLast;
			case 'afterLast': WrappingLocation.AfterLast;
			case _: null;
		};
	}

	private static function wrapModeFromString(s: String): Null<WrapMode> {
		return switch s {
			case 'noWrap', 'NoWrap': WrapMode.NoWrap;
			case 'onePerLine', 'OnePerLine': WrapMode.OnePerLine;
			case 'onePerLineAfterFirst', 'OnePerLineAfterFirst': WrapMode.OnePerLineAfterFirst;
			case 'fillLine', 'FillLine': WrapMode.FillLine;
			case 'fillLineWithLeadingBreak', 'FillLineWithLeadingBreak':
				WrapMode.FillLineWithLeadingBreak;
			// ω-keep-objectlit: fork's `WrappingType.Keep` preserves
			// source-newline pattern per-element. Loader maps it to
			// `WrapMode.Keep`; `triviaSepStarExpr` (`TriviaSepLowering.hx`)
			// consumes it for trivia-bearing Stars (ObjectLit, Anon-type,
			// etc.) via the `_keepEmit` gate. `BinaryChainEmit` and
			// `MethodChainEmit` route `Keep` to their `shapeNoWrap` arms
			// — chain Keep semantics is a follow-up slice; the NoWrap
			// fallback preserves the pre-recognition baseline byte-
			// identically for chain-config Keep fixtures.
			case 'keep', 'Keep':
				WrapMode.Keep;
			// ω-cascade-emits-comments: anyparse extension with NO fork
			// counterpart (the fork's `WrappingType` ends at `keep`) — it
			// drops source-newline signal and lets the cascade pick a
			// width-driven layout. Sister to Keep on the same axis.
			// `triviaSepStarExpr` consumes it via the `_ignoreEmit`
			// gate; chain emitters route `Ignore → shapeNoWrap` as a
			// defensive fallback.
			case 'ignore', 'Ignore':
				WrapMode.Ignore;
			// ω-packed-or-oneperline: anyparse extension with no fork
			// counterpart — leading break, then the items share one
			// continuation line if they fit at that indent, else one per line.
			case 'packedOrOnePerLine', 'PackedOrOnePerLine': WrapMode.PackedOrOnePerLine;
			case _: null;
		};
	}

	private static function wrapCondFromString(s: String): Null<WrapConditionType> {
		return switch s {
			case 'itemCount <= n', 'ItemCountLessThan': WrapConditionType.ItemCountLessThan;
			case 'itemCount >= n', 'ItemCountLargerThan': WrapConditionType.ItemCountLargerThan;
			case 'anyItemLength >= n', 'AnyItemLengthLargerThan': WrapConditionType.AnyItemLengthLargerThan;
			case 'anyItemLength <= n', 'AnyItemLengthLessThan':
				WrapConditionType.AnyItemLengthLessThan;
			// `allItemLengths <= n` is the FORK's spelling; `allItemLengths < n` is
			// hxq's own older one, kept because this repo's docs and one ingest
			// test still name it. Both mean `max(itemFlatLength) <= n`.
			case 'allItemLengths <= n', 'allItemLengths < n', 'AllItemLengthsLessThan': WrapConditionType.AllItemLengthsLessThan;
			case 'allItemLengths >= n', 'AllItemLengthsLargerThan': WrapConditionType.AllItemLengthsLargerThan;
			case 'equalItemLengths', 'EqualItemLengths': WrapConditionType.EqualItemLengths;
			case 'totalItemLength >= n', 'TotalItemLengthLargerThan': WrapConditionType.TotalItemLengthLargerThan;
			case 'totalItemLength <= n', 'TotalItemLengthLessThan': WrapConditionType.TotalItemLengthLessThan;
			case 'exceedsMaxLineLength', 'ExceedsMaxLineLength': WrapConditionType.ExceedsMaxLineLength;
			case 'lineLength >= n', 'LineLengthLargerThan':
				WrapConditionType.LineLengthLargerThan;
			// The fork's IDENTIFIER is `HasMultiLineItems` (capital L); hxq's own
			// enum spells it `HasMultilineItems`. Accept both, or a config
			// serialised from the fork's enum drops the whole rule.
			case 'hasMultilineItems', 'HasMultiLineItems', 'HasMultilineItems': WrapConditionType.HasMultilineItems;
			case 'complexItemCount >= n', 'ComplexItemCountLargerThan': WrapConditionType.ComplexItemCountLargerThan;
			case _: null;
		};
	}

	/**
	 * Map a haxe-formatter `betweenImportsLevel` string token to the
	 * runtime enum. Mirrors fork's `BetweenImportsEmptyLinesLevel` JSON
	 * encoding (`"all"` / `"firstLevelPackage"` / … / `"fullPackage"`).
	 * Unknown tokens return `null` and the caller leaves the existing
	 * `opt.betweenImportsLevel` (defaults `All`) intact — same lenient
	 * behaviour as the rest of the loader's enum mappings.
	 */
	private static function betweenImportsLevelFromString(raw: String): Null<HxBetweenImportsLevel> {
		return switch raw {
			case 'all': HxBetweenImportsLevel.All;
			case 'firstLevelPackage': HxBetweenImportsLevel.FirstLevelPackage;
			case 'secondLevelPackage': HxBetweenImportsLevel.SecondLevelPackage;
			case 'thirdLevelPackage': HxBetweenImportsLevel.ThirdLevelPackage;
			case 'fourthLevelPackage': HxBetweenImportsLevel.FourthLevelPackage;
			case 'fifthLevelPackage': HxBetweenImportsLevel.FifthLevelPackage;
			case 'fullPackage': HxBetweenImportsLevel.FullPackage;
			case _: null;
		};
	}

	private static function sameLineToRuntime(policy: HxFormatSameLinePolicy): SameLinePolicy {
		return switch policy {
			case HxFormatSameLinePolicy.Next: SameLinePolicy.Next;
			case HxFormatSameLinePolicy.Keep: SameLinePolicy.Keep;
			case _: SameLinePolicy.Same;
		};
	}

	private static function bodyPolicyToRuntime(policy: HxFormatBodyPolicy): BodyPolicy {
		return switch policy {
			case HxFormatBodyPolicy.Same: BodyPolicy.Same;
			case HxFormatBodyPolicy.Next: BodyPolicy.Next;
			case HxFormatBodyPolicy.FitLine: BodyPolicy.FitLine;
			case HxFormatBodyPolicy.Keep: BodyPolicy.Keep;
			case _: BodyPolicy.Same;
		};
	}

	private static function leftCurlyToRuntime(policy: HxFormatLeftCurlyPolicy): BracePlacement {
		return switch policy {
			case HxFormatLeftCurlyPolicy.Before, HxFormatLeftCurlyPolicy.Both: BracePlacement.Next;
			case _: BracePlacement.Same;
		};
	}

	private static function emptyCurlyToRuntime(policy: HxFormatEmptyCurlyPolicy): EmptyCurly {
		return switch policy {
			case HxFormatEmptyCurlyPolicy.Break: EmptyCurly.Break;
			case _: EmptyCurly.Same;
		};
	}

	private static function optionalSemicolonToRuntime(policy: HxFormatOptionalSemicolonPolicy): OptionalSemicolon {
		return switch policy {
			case HxFormatOptionalSemicolonPolicy.Always: OptionalSemicolon.Always;
			case HxFormatOptionalSemicolonPolicy.Never: OptionalSemicolon.Never;
			case _: OptionalSemicolon.Preserve;
		};
	}

	private static function rightCurlyToRuntime(policy: HxFormatRightCurlyPolicy): RightCurlyPlacement {
		// "before" / "both" → Same (hardline before `}`, default — the
		// trailing newline after `}` is contributed by the outer sibling
		// sep, not by `blockBody`, so `Before` and `Both` collapse).
		// "after" / "none" → Inline (no hardline before `}`).
		return switch policy {
			case HxFormatRightCurlyPolicy.After, HxFormatRightCurlyPolicy.None: RightCurlyPlacement.Inline;
			case _: RightCurlyPlacement.Same;
		};
	}

	private static function lineEndCharacterToRuntime(policy: HxFormatLineEndCharacter): String {
		return switch policy {
			case HxFormatLineEndCharacter.CRLF: '\r\n';
			case HxFormatLineEndCharacter.CR: '\r';
			case _: '\n';
		};
	}

	private static function metadataLineEndToRuntime(policy: HxFormatMetadataLineEndPolicy): MetadataLineEndPolicy {
		return switch policy {
			case HxFormatMetadataLineEndPolicy.After: MetadataLineEndPolicy.After;
			case HxFormatMetadataLineEndPolicy.AfterLast: MetadataLineEndPolicy.AfterLast;
			case HxFormatMetadataLineEndPolicy.ForceAfterLast: MetadataLineEndPolicy.ForceAfterLast;
			case _: MetadataLineEndPolicy.None;
		};
	}

	private static function whitespaceToRuntime(policy: HxFormatWhitespacePolicy): WhitespacePolicy {
		return switch policy {
			case HxFormatWhitespacePolicy.Before, HxFormatWhitespacePolicy.OnlyBefore: WhitespacePolicy.Before;
			case HxFormatWhitespacePolicy.After, HxFormatWhitespacePolicy.OnlyAfter: WhitespacePolicy.After;
			case HxFormatWhitespacePolicy.Around: WhitespacePolicy.Both;
			case _: WhitespacePolicy.None;
		};
	}

	/**
	 * ω-condition-parens (Stage C): map a condition-paren `openingPolicy`'s
	 * `before` sub-policy (gap BEFORE the `(` = gap AFTER the keyword) onto
	 * the kw-after `WhitespacePolicy` consumed by `@:fmt(ifPolicy)` etc.
	 * (`After`/`Both` → space). Paren `Before`/`Both`/`OnlyBefore` carry a
	 * before-`(` space → kw `After`; everything else (`After`/`OnlyAfter`/
	 * `None`) → kw `None` (no space). So `openingPolicy: "onlyAfter"`
	 * collapses `if (` to `if(` while still padding the inner `( `.
	 */
	private static function parenGapToKwAfter(policy: HxFormatWhitespacePolicy): WhitespacePolicy {
		return switch policy {
			case HxFormatWhitespacePolicy.Before, HxFormatWhitespacePolicy.OnlyBefore, HxFormatWhitespacePolicy.Around,
				HxFormatWhitespacePolicy.NoneAfter: WhitespacePolicy.After;
			case _: WhitespacePolicy.None;
		};
	}

	/**
	 * ω-condition-parens (Stage C): map a condition-paren `openingPolicy`'s
	 * `after` sub-policy (gap AFTER the `(` = inner `( ` pad) onto the
	 * `WhitespacePolicy` consumed by the `*InsideOpen` knobs through
	 * `whitespacePolicyLead`. Only the after-`(` component belongs to the
	 * inner pad — the before-`(` component is the kw→`(` gap, already owned by
	 * `parenGapToKwAfter`. `After`/`OnlyAfter`/`Around`/`NoneBefore` carry an
	 * inner space → `After`; everything else (incl. `Before`/`OnlyBefore`) →
	 * `None`. Without this split a `before`/`around` policy would also emit a
	 * space BEFORE the `(` via the inner-pad knob, stacking with the gap into a
	 * double `catch  (` / `switch  (` / `} while  (`.
	 */
	private static function parenOpeningToInnerPad(policy: HxFormatWhitespacePolicy): WhitespacePolicy {
		return switch policy {
			case HxFormatWhitespacePolicy.After, HxFormatWhitespacePolicy.OnlyAfter, HxFormatWhitespacePolicy.Around,
				HxFormatWhitespacePolicy.NoneBefore: WhitespacePolicy.After;
			case _: WhitespacePolicy.None;
		};
	}

	private static function keywordPlacementToRuntime(policy: HxFormatKeywordPlacement): KeywordPlacement {
		return switch policy {
			case HxFormatKeywordPlacement.Next: KeywordPlacement.Next;
			case _: KeywordPlacement.Same;
		};
	}

	private static function commentEmptyLinesToRuntime(policy: HxFormatCommentEmptyLinesPolicy): CommentEmptyLinesPolicy {
		return switch policy {
			case HxFormatCommentEmptyLinesPolicy.None: CommentEmptyLinesPolicy.None;
			case HxFormatCommentEmptyLinesPolicy.One: CommentEmptyLinesPolicy.One;
			case _: CommentEmptyLinesPolicy.Ignore;
		};
	}

	private static function keepEmptyLinesToRuntime(policy: HxFormatKeepEmptyLinesPolicy): KeepEmptyLinesPolicy {
		return switch policy {
			case HxFormatKeepEmptyLinesPolicy.Remove: KeepEmptyLinesPolicy.Remove;
			case _: KeepEmptyLinesPolicy.Keep;
		};
	}

	private static function uniformStatementBlanksToRuntime(policy: HxFormatUniformStatementBlanksPolicy): UniformStatementBlanksPolicy {
		return switch policy {
			case HxFormatUniformStatementBlanksPolicy.Collapse: UniformStatementBlanksPolicy.Collapse;
			case _: UniformStatementBlanksPolicy.Keep;
		};
	}

	/**
	 * Maps the `wrapping.trailingComma` config string onto the runtime
	 * `TrailingCommaPolicy`. Unknown / absent values fall back to `Keep`,
	 * the byte-inert default.
	 */
	private static function trailingCommaRemovalToRuntime(policy: HxFormatWrappingTrailingCommaPolicy): TrailingCommaPolicy {
		return switch policy {
			case HxFormatWrappingTrailingCommaPolicy.Remove: TrailingCommaPolicy.Remove;
			case _: TrailingCommaPolicy.Keep;
		};
	}

}
