package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Expr;

using anyparse.macro.MetaInspect;

/**
 * Which synthesized trivia slot a STRUCT FIELD earns, and what that
 * slot's declaration looks like.
 *
 * A `@:trivia` Seq rule's paired `*T` typedef is its plain twin plus a
 * set of extra fields, each recording one thing the plain AST has no
 * room for: the newline before a field's first token, the own-line
 * comments in front of it, whether a blank line preceded it, a same-line
 * trailing comment after its trail literal, the trailing run captured on
 * a Star's final iteration. Every member here answers one of two
 * questions about ONE of those slots — WHICH fields earn it (the `is…`
 * predicates, each reading the shape and its metadata) and WHAT its
 * `Field` declaration is (the `build…Slot` builders, each returning the
 * `@:optional Null<T>` field the parser writes and the writer reads).
 *
 * The two halves are deliberately adjacent: a slot that is built but
 * never gated, or gated but never built, is not a macro compile error —
 * it is a missing or undefined field in the GENERATED type, so the pair
 * is easier to keep honest when it has one address.
 *
 * Split out of `TriviaTypeSynth`, which kept the name vocabulary, the
 * atomic `defineModule` arm and the type-definition assembler that
 * calls these. Nothing here reads state: that class declares no
 * instance field, so the seam is the QUESTION each member answers, not
 * a state boundary.
 */
@:access(anyparse.macro.TriviaTypeSynth)
final class TriviaPairSlots {

	public static inline function wrapOptional(node: ShapeNode, base: ComplexType): ComplexType {
		return node.annotations[AnnotationKeys.BASE_OPTIONAL] == true ? TPath({ pack: [], name: 'Null', params: [TPType(base)] }) : base;
	}

	/** The `<field>BeforeTrail:Null<String>` slot — twin of `buildAfterTrailSlot`, on the other side of the trail literal. */
	public static inline function buildBeforeTrailSlot(child: ShapeNode, pos: Position): Field {
		return buildNullStringSlot(child, pos, TriviaTypeSynth.BEFORE_TRAIL_SUFFIX);
	}

	public static inline function buildAfterTrailSlot(child: ShapeNode, pos: Position): Field {
		return buildNullStringSlot(child, pos, TriviaTypeSynth.AFTER_TRAIL_SUFFIX);
	}


	public static function buildStructField(child: ShapeNode, pos: Position, synthPack: Array<String>): Field {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final ct: ComplexType = TriviaTypeSynth.shapeToComplexType(child, synthPack);
		final optional: Bool = child.annotations[AnnotationKeys.BASE_OPTIONAL] == true;
		final meta: Metadata = optional ? [{ name: ':optional', params: [], pos: pos }] : [];
		return {
			name: fieldName,
			kind: FVar(ct),
			pos: pos,
			access: [],
			meta: meta
		};
	}

	public static function isOptionalKw(child: ShapeNode): Bool {
		// Generalised over kind=Ref|Star — both shapes need the kw-trivia
		// sibling slots (`<f>BeforeKwLeading` / `<f>BeforeKwTrailing` /
		// `<f>AfterKw` / `<f>KwLeading` / `<f>BeforeKwNewline` /
		// `<f>BodyOnSameLine`) so the writer can round-trip the kw→body
		// gap regardless of whether the body is a single Ref or a Star
		// of decls/statements.
		//
		// Ref consumer: `HxIfStmt.elseBody` (`@:optional @:kw('else')`
		// Ref to HxStatement). Star consumer: `HxConditionalDecl.elseBody`
		// (`@:optional @:kw('#else')` Star of HxTopLevelDecl, slice
		// ω-cond-comp-engine). Lowering's `isOptionalKwStar` mirrors this
		// predicate's Star branch on the parser side.
		return (child.kind == Ref || child.kind == Star)
			&& (child.annotations[AnnotationKeys.BASE_OPTIONAL] == true && child.readMetaString(':kw') != null);
	}

	public static function isBareNonFirstRef(child: ShapeNode, parent: ShapeNode): Bool {
		// ω-orphan-prefix-member: `@:fmt(bareRefSepWhenPresent)` puts an
		// `@:optional @:absentOn` Ref back on the bare-Ref footing — when
		// PRESENT it needs the same `<field>BeforeNewline` /
		// `<field>BeforeLeading` signals the mandatory field had, or the
		// writer has nothing to reproduce the gap from. Spelled the same way as
		// `Lowering.computeBeforeSlots` and `WriterLowering`'s `optBareSep` gate on
		// purpose — three places decide synthesise / capture / consume for one slot,
		// and only an identical spelling makes the agreement checkable by eye.
		return child.kind == Ref && ((
			child.annotations[AnnotationKeys.BASE_OPTIONAL] != true || child.fmtHasFlag('bareRefSepWhenPresent')
		) && (child.readMetaString(':kw') == null && (
			child.readMetaString(':lead') == null && (child != parent.children[0] || child.fmtHasFlag('beforeNewlineSlotFirst'))
		)));
	}

	/**
	 * ω-casepattern-keep — true for a bare (lead-less, kw-less,
	 * non-optional) trivia Star that is the FIRST field of its struct and
	 * opts into the source-newline-before channel via
	 * `@:fmt(beforeNewlineSlotFirst)`. Sister of `isBareNonFirstRef`'s
	 * first-field allowance, but for a Star value (`HxCaseBranch.patterns`,
	 * `@:sep(',') @:trail(':')`) rather than a bare Ref. Such a field grows
	 * a `<field>BeforeNewline:Bool` slot recording whether the source broke
	 * right after the parent's `case` keyword (whose post-kw `skipWs` the
	 * parent ctor omits via `@:fmt(forwardNewlineForBody)`). Read by the
	 * writer's struct-Star emit under `opt.leftCurly == Next`.
	 */
	public static function isBareFirstStarNlOptIn(child: ShapeNode, parent: ShapeNode): Bool {
		return child.kind == Star && (child.annotations[AnnotationKeys.BASE_OPTIONAL] != true && (child.readMetaString(':kw') == null && (
			child.readMetaString(':lead') == null && (child == parent.children[0] && child.fmtHasFlag('beforeNewlineSlotFirst'))
		)));
	}

	public static function buildBeforeNewlineSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		return {
			name: fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX,
			kind: FVar(boolCT),
			pos: pos,
			access: []
		};
	}

	/**
	 * ω-598-member-leading-comment — `<field>BeforeLeading:Array<String>`
	 * companion to `buildBeforeNewlineSlot`, gated on the same
	 * `isBareNonFirstRef` host. Holds the verbatim comments the
	 * `BeforeNewline` `collectTrivia` scan captured in the pre-field gap.
	 */
	public static function buildBeforeLeadingSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final arrayStrCT: ComplexType = TPath({
			pack: [],
			name: 'Array',
			params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
		});
		return {
			name: fieldName + TriviaTypeSynth.BEFORE_LEADING_SUFFIX,
			kind: FVar(arrayStrCT),
			pos: pos,
			access: []
		};
	}

	/**
	 * ω-region-prefix-blank — hosts of `<field>BeforeBlank`: a bare non-first Ref
	 * that opts in with `@:fmt(keepBlankAfterStarCtor(starField, ctorName))`.
	 * Spelled as `isBareNonFirstRef` PLUS the opt-in on purpose, so the slot can
	 * never be synthesised for a field whose writer seat would not read it —
	 * the same synthesise / capture / consume agreement `BeforeNewline` keeps
	 * across `Lowering.computeBeforeSlots` and `WriterLowering`.
	 */
	public static function isBeforeBlankRef(child: ShapeNode, parent: ShapeNode): Bool {
		return isBareNonFirstRef(child, parent) && child.fmtReadStringArgs('keepBlankAfterStarCtor') != null;
	}

	/**
	 * ω-region-prefix-blank — `<field>BeforeBlank:Bool` companion to
	 * `buildBeforeNewlineSlot`. Records whether the `collectTrivia` scan that
	 * filled `BeforeNewline` saw a BLANK line, which `newlineBefore` alone
	 * cannot distinguish from a single break.
	 */
	public static function buildBeforeBlankSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		return {
			name: fieldName + TriviaTypeSynth.BEFORE_BLANK_SUFFIX,
			kind: FVar(boolCT),
			pos: pos,
			access: []
		};
	}

	/**
	 * True for mandatory Ref fields carrying `@:trail(LIT)`. Reads
	 * `@:trail` from `base.meta` directly (TriviaTypeSynth.arm runs
	 * BEFORE the Lit strategy populates `lit.trailText`, same ordering
	 * constraint as `isOptionalKw` / star-trailing predicates).
	 * Optional Refs with `@:lead` + `@:trail` ARE included:
	 * the lead-led commit branch in `Lowering` consumes the trail and
	 * captures a same-line `// comment` into `<field>AfterTrail`, same as
	 * the mandatory path. The absent branch leaves the slot null.
	 */
	public static function isTrailRef(child: ShapeNode): Bool {
		// Mandatory Ref with @:trail, OR a @:fmt(captureTrailComment)-opted Star
		// (case-pattern list) — both grow a `<field>AfterTrail:Null<String>` slot.
		return child.readMetaString(':trail') != null && (child.kind == Ref || child.fmtHasFlag('captureTrailComment'));
	}

	/**
	 * Hosts of `<field>BeforeTrail`: a MANDATORY Ref carrying `@:trail`. The
	 * optional-Ref path emits its trail from a different writer seat
	 * (`emitOptionalRefLead`) and is left alone — the slot would be synthesised
	 * with nothing to fill or read it.
	 */
	public static function isBeforeTrailRef(child: ShapeNode): Bool {
		return child.kind == Ref && child.annotations[AnnotationKeys.BASE_OPTIONAL] != true && isTrailRef(child);
	}

	/**
	 * Build the `<field>TrailPresent` slot for struct typedef fields gated
	 * by `isStructFieldTrailOpt`. Slot is `@:optional Null<Bool>` so
	 * paired-struct construction in `Lowering` may omit it (`null` = "no
	 * source info", e.g. a synthesised paired-T from a writer-only path;
	 * `true`/`false` = source had / lacked the trail literal). The writer
	 * does not yet consume the slot (see `isStructFieldTrailOpt`). Suffix
	 * shared with `buildStarTrailingSlots`'s `@:sep+@:trail` Star case
	 * (disjoint host — Ref vs Star within one Seq cannot collide on field
	 * name).
	 *
	 */
	public static function buildStructFieldTrailPresentSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		final nullBoolCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(boolCT)] });
		final meta: Metadata = [{ name: ':optional', params: [], pos: pos }];
		return {
			name: fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX,
			kind: FVar(nullBoolCT),
			pos: pos,
			access: [],
			meta: meta
		};
	}

	/**
	 * True for any Ref field opted in via `@:fmt(captureSourceNewlineAfter)`.
	 * The slot records whether the source had a newline AFTER this
	 * field's parse position — used by the writer's `padTrailingDoc`
	 * walker as a per-field source-shape signal for the boundary
	 * between this field and the parent ctor's trail literal (or
	 * the next non-signal-bearing sibling).
	 *
	 * Bare Ref, optional Ref, and optional-kw Ref are all eligible —
	 * the capture position is "wherever ctx.pos lands after this
	 * field's parse case branch settles", which is well-defined for
	 * all three kinds (post-parse for present case, post-rewind for
	 * absent case).
	 *
	 * Currently consumed by:
	 *   - `HxConditionalExpr.expr` (mandatory bare Ref) — captures the
	 *     `expr → '#end'` boundary newline when both `elseifs` is empty
	 *     and `elseExpr` is absent.
	 *   - `HxConditionalExpr.elseExpr` (optional kw Ref) — captures the
	 *     `elseExpr → '#end'` boundary newline.
	 */
	public static function isPadTrailingTerminalRef(child: ShapeNode): Bool {
		return child.kind == Ref && child.fmtHasFlag('captureSourceNewlineAfter');
	}

	public static function buildNewlineAfterSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		return {
			name: fieldName + TriviaTypeSynth.NEWLINE_AFTER_SUFFIX,
			kind: FVar(boolCT),
			pos: pos,
			access: []
		};
	}

	/**
	 * ω-condition-wrap-keep — true for the mandatory-Ref condition field of a
	 * `@:fmt(condWrap)` struct (`HxIfStmt.cond` / `HxWhileStmt.cond`) that opts
	 * into source-shape capture via `@:fmt(captureCondOpenNewline)`. Such a
	 * field grows a `<field>CondOpenNewline:Bool` slot recording whether the
	 * source broke right after the open paren. Requires `condWrap` (the field
	 * carries the `@:lead('(')` open delimiter whose post-`(` gap is probed)
	 * and a bare mandatory Ref (the condWrap contract). Disjoint from
	 * `isPadTrailingTerminalRef` (which keys on `captureSourceNewlineAfter`).
	 * Reads the flags via `fmtHasFlag`, which works at arm-time (`base.meta`
	 * populated by `ShapeBuilder` before `arm()` runs — same path the sister
	 * predicates rely on).
	 */
	public static function isCondOpenNewlineRef(child: ShapeNode): Bool {
		return child.kind == Ref
			&& (child.annotations[AnnotationKeys.BASE_OPTIONAL] != true
				&& (child.fmtHasFlag('condWrap') && child.fmtHasFlag('captureCondOpenNewline')));
	}

	public static function buildCondOpenNewlineSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		return {
			name: fieldName + TriviaTypeSynth.CONDITION_OPEN_NEWLINE_SUFFIX,
			kind: FVar(boolCT),
			pos: pos,
			access: []
		};
	}

	public static function buildKwTriviaSlots(child: ShapeNode, pos: Position): Array<Field> {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
		final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
		final arrayStrCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(strCT)] });
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		// Slots are mandatory (no `@:optional`). The parser always
		// populates them — `AfterKw` gets a captured same-line trailing
		// or `null`; `KwLeading` gets a list of own-line comments
		// (possibly empty); `BeforeKwNewline` / `BodyOnSameLine` carry
		// source-shape booleans for the `Keep` policy branches.
		// Mandatory typing keeps Null-Safety strict happy in the
		// writer's `kwGapDoc` / `bodyPolicyWrap` call sites.
		return [
			{
				name: fieldName + TriviaTypeSynth.AFTER_KW_SUFFIX,
				kind: FVar(nullStrCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + TriviaTypeSynth.KW_LEADING_SUFFIX,
				kind: FVar(arrayStrCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + TriviaTypeSynth.BODY_ON_SAME_LINE_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX,
				kind: FVar(arrayStrCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX,
				kind: FVar(nullStrCT),
				pos: pos,
				access: []
			}
		];
	}

	public static function isTriviaStarField(child: ShapeNode): Bool {
		return child.kind == Star && child.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
	}

	/**
	 * Opt-in: non-trivia `@:sep + @:tryparse` no-`@:trail` Star
	 * field with `@:fmt(sepBeforeOpt)` requesting a `<field>SepBefore:Bool`
	 * synth slot. The slot captures whether the source had a leading
	 * separator inside the body (`#if cond, body` shape) for byte-roundtrip
	 * re-emission by the writer.
	 *
	 * Independent of `@:trivia` (the gate fires for both trivia and plain
	 * Stars) but coupled to the @:sep+@:tryparse no-trail shape — those
	 * are the only Lowering / WriterLowering paths that interpret the
	 * slot. Macro shape validation lives in `Lowering.emitStarFieldSteps`
	 * (fatalError on missing `:sep` / `:tryparse` / present `:trail`) and
	 * `WriterLowering.emitWriterStarField` (fatalError on missing
	 * `padLeading`).
	 */
	public static function isSepBeforeOptStarField(child: ShapeNode): Bool {
		return child.kind == Star && child.fmtHasFlag('sepBeforeOpt');
	}

	public static function buildStarTrailingSlots(child: ShapeNode, pos: Position): Array<Field> {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
		final arrayStrCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(strCT)] });
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		final fields: Array<Field> = [
			{
				name: fieldName + TriviaTypeSynth.TRAILING_BLANK_BEFORE_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			},
			// ω-keep-fnsig-newline: sibling slot recording a single newline (not
			// a blank line) before the close. Defined unconditionally alongside
			// TrailingBlankBefore so the arity stays locked.
			{
				name: fieldName + TriviaTypeSynth.TRAILING_NEWLINE_BEFORE_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX,
				kind: FVar(arrayStrCT),
				pos: pos,
				access: []
			}
		];
		// ω-close-trailing: close-peek Stars (those with `@:trail`)
		// additionally carry a same-line trailing comment captured right
		// after the close literal. EOF-mode Stars omit this slot —
		// there's no close to trail. `@:trivia + @:tryparse` already
		// rejects `@:trail`, so tryparse cannot reach this branch.
		//
		// Reads `@:trail` directly from `base.meta` rather than the
		// Lit-strategy-derived `lit.trailText` annotation: `TriviaTypeSynth.arm`
		// runs BEFORE `registry.runAnnotate` in `Build.buildParser` /
		// `buildWriter` (the paired type must exist before Lowering /
		// WriterLowering reference it), so at this point the Lit pass has
		// not yet populated `lit.trailText`. Mirrors `isOptionalKw`'s
		// direct-meta read pattern.
		if (child.readMetaString(':trail') != null) {
			final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
			fields.push({
				name: fieldName + TriviaTypeSynth.TRAILING_CLOSE_SUFFIX,
				kind: FVar(nullStrCT),
				pos: pos,
				access: []
			});
		}
		// ω-open-trailing: same-line `// comment` after the open literal
		// is captured here for Stars that carry `@:lead`. Read directly
		// from `base.meta` for the same TriviaTypeSynth/Lit-pass ordering
		// reason as `:trail` above.
		//
		// Skipped for `@:tryparse` Stars: their writer helper
		// (`triviaTryparseStarExpr`) does not consume an open-trail slot,
		// so capturing one would silently drop the comment at write time.
		// `HxDefaultBranch.stmts` (`@:lead(':') @:trivia @:tryparse`) is
		// the lone current consumer of this gate.
		if (child.readMetaString(':lead') != null && !child.hasMeta(':tryparse')) {
			final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
			fields.push({
				name: fieldName + TriviaTypeSynth.TRAILING_OPEN_SUFFIX,
				kind: FVar(nullStrCT),
				pos: pos,
				access: []
			});
		}
		// ω-trail-blank-after: tryparse + nestBody Stars need a Bool slot
		// to carry the source's blank-line-between-trail-and-next-sibling
		// signal (`_lead.blankAfterLeadingComments` from the failed-element
		// trivia run). Other tryparse shapes either rewind on failure (no
		// stash) or have no nestBody indent wrap. Reads `:fmt` directly from
		// `base.meta` for the same TriviaTypeSynth/Lit-pass ordering reason
		// as `:trail` / `:lead` above.
		if (child.hasMeta(':tryparse') && child.fmtHasFlag('nestBody')) {
			fields.push({
				name: fieldName + TriviaTypeSynth.TRAILING_BLANK_AFTER_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			});
		}
		// ω-objectlit-source-trail-comma: sep-Stars with a close literal
		// grow a `Bool` slot capturing whether the source had a trailing
		// separator after the last element. The writer reads it via
		// `<field>TrailPresent` to force the wrap-rules cascade into
		// break-mode when the source committed to a multi-line list.
		// Reads `:sep` / `:trail` directly from `base.meta` for the same
		// pre-Lit-pass ordering reason as the gates above.
		//
		// ω-blockended-trivia-meta-arity: `hasMeta` instead of
		// `readMetaString` so multi-arg `@:sep('text', tailRelax, blockEnded)`
		// counts the same as 1-arg `@:sep(',')`. Parser-side gate reads
		// `lit.sepText` (set by Lit strategy after both 1- and 3-arg forms)
		// — synth must match the parser to keep ctor / struct arity in sync.
		if (child.hasMeta(':sep') && child.hasMeta(':trail')) {
			fields.push({
				name: fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			});
		}
		return fields;
	}

	/** A `<field><suffix>:Null<String>` sidecar slot on the paired-T struct. */
	private static function buildNullStringSlot(child: ShapeNode, pos: Position, suffix: String): Field {
		final fieldName: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
		final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
		return {
			name: fieldName + suffix,
			kind: FVar(nullStrCT),
			pos: pos,
			access: []
		};
	}

}
#end
