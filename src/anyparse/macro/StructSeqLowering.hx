package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.StarFieldLowering.*;
import anyparse.macro.Lowering.*;
import anyparse.macro.StructFieldTrailLowering.*;
import anyparse.macro.TriviaSlotNames.*;
import anyparse.macro.BinaryParseLowering.*;
import anyparse.macro.MacroNames.*;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3 helpers - the struct (Seq) rule shape and every field emit under it.
 *
 * The largest of the four shapes `Lowering.lowerRule` dispatches on: a
 * typedef rule whose generated parser walks its fields in order and builds
 * an anonymous structure. `lowerStruct` is the walk; everything else here
 * is ONE question about ONE field - which slots it declares
 * (`computeStructFieldFlags`, `computeBeforeSlots`, the four
 * `has*Field` predicates), what its value expression is
 * (`emitFieldValueByKind`), what a repetition emits in each of its four
 * modes (`emitStarFieldSteps`, `emitOptionalStarFieldSteps`,
 * `emitOptionalKwStarFieldSteps`, `emitTriviaStarFieldSteps`,
 * `emitNonTriviaCloseSteps`), what an optional `Ref` emits
 * (`emitOptionalRefField`, `emitAbsentOnRefField`,
 * `emitOptionalRefLeadCommit`) and what the field contributes to the
 * struct literal (`pushStructFieldEntries`, `emitTrailSidecarDecls`,
 * `emitNewlineAfterCapture`). The `@:byName` variant
 * (`shouldLowerByName`, `lowerStructByName` and the four `byName*` emit
 * leaves) rides along because it is the same rule shape read through a
 * key rather than a position, and `lowerStruct` dispatches to it.
 *
 * Split out of `Lowering` by the STATE each member reads. The five
 * purity leaves left in `Lowering` after S83 were the last members that
 * read NOTHING; this family reads `_ctx`, `_shape`, `_formatInfo` and the
 * `_starGates` accumulator, and reaches six members that stayed behind.
 * Those six arrive as callbacks on the bundle rather than as a back
 * reference to the owner, so the bundle IS the dependency surface and
 * widening it is a visible edit in `Lowering`'s constructor.
 *
 * WARNING - Star emission FORKS across four sites: `emitStarFieldSteps`
 * here is the struct-field half, `Lowering.lowerEnumBranch`'s Case 4 and
 * the `lowerStar*Branch` shape leaves are the enum half, and both have a
 * twin in `WriterLowering`. A change to one is a question about all four.
 */
@:access(anyparse.macro.BinaryParseLowering, anyparse.macro.KwBranchLowering, anyparse.macro.Lowering,
	anyparse.macro.OperatorLoopLowering, anyparse.macro.ParseDispatchLowering, anyparse.macro.SpanArgLowering,
	anyparse.macro.StarFieldLowering, anyparse.macro.StarLoopLowering, anyparse.macro.StructFieldTrailLowering,
	anyparse.macro.TriviaSlotNames)
final class StructSeqLowering {

	// -------- struct rule --------

	private static function lowerStruct(sc: StructSeqCtx, node: ShapeNode, typePath: String): Expr {
		// The stamp, not a second `shouldLowerByName` call: `generate`
		// derives that decision once per `Seq` rule so `seqFirstToken` can
		// read it too, and one derivation cannot drift from itself. Every
		// node reaching here is a top-level rule, so the stamp is present.
		if (node.annotations[BY_NAME_KEY] == true) return lowerStructByName(sc, node);
		final parseSteps: Array<Expr> = [];
		final structFields: Array<ObjectField> = [];
		// Binary: @:magic prefix — validate fixed magic bytes before fields.
		final magic: Null<String> = node.annotations[AnnotationKeys.BIN_MAGIC];
		if (magic != null) parseSteps.push(macro expectLit(ctx, $v{magic}));
		for (child in node.children) {
			final fieldName: Null<String> = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			if (fieldName == null) {
				Context.fatalError('Lowering: struct field missing base.fieldName', Context.currentPos());
			}
			// Per-field prefix: @:kw (word-boundary checked) and/or @:lead.
			// When both are present, both are emitted sequentially — @:kw
			// first, then @:lead (D50). First consumers:
			// HxDoWhileStmt.cond and HxCatchClause.name.
			//
			// For a Star field, the @:lead/@:trail pair semantically describes
			// the surrounding wrappers of the collection and is read directly
			// from the Star node's own `lit.*` annotations by
			// `emitStarFieldSteps`. Emitting them here too would produce
			// duplicate `expectLit` calls, so we skip struct-level lead/trail
			// emission whenever the field is a Star.
			//
			// For an @:optional field, the lead literal is parsed via
			// `matchLit` as part of the peek-conditional block, not as a
			// preceding unconditional `expectLit` — the peek IS the commit
			// point. So the lead emission is also skipped for optional
			// fields, and the peek + conditional sub-rule call are emitted
			// together inside the field-value switch below.
			final kwLead: Null<String> = child.readMetaString(':kw');
			final leadText: Null<String> = child.readMetaString(':lead');
			final trailText: Null<String> = child.readMetaString(':trail');
			// ω-absent-on: declarative escape-hatch for `@:optional Ref` to
			// an enum without a shared lead literal. Lists the terminator
			// literals that signal field absence at the current position;
			// emission peeks them BEFORE attempting `parseRef` instead of
			// the lead/kw matchLit-commit chain. Used by `HxFnExpr.body`
			// where `HxFnExprBody = BlockBody({-led) | ExprBody(catch-all)`
			// — the latter has no fixed lead, so a regular `@:optional`
			// can't dispatch.
			final absentOnLits: Null<Array<String>> = child.readMetaStringArgs(':absentOn');
			// ω-orphan-prefix-decl: `@:absentOnEof` is the same absence dispatch with
			// the ONE terminator `@:absentOn` cannot spell — end of input has no
			// literal to peek. Composable with `@:absentOn` (the peek chain ORs both)
			// so a field whose terminator set is `}` at one call site and EOF at
			// another needs no second mechanism. Sole consumer today:
			// `HxTopLevelDecl.decl`, the module-scope twin of `HxMemberDecl.member`.
			final absentOnEof: Bool = child.hasMeta(':absentOnEof');
			final isStar: Bool = child.kind == Star;
			final isOptional: Bool = child.annotations.get(AnnotationKeys.BASE_OPTIONAL) == true;
			validateStructField(child, fieldName, isOptional, isStar, kwLead, leadText, trailText, absentOnLits, absentOnEof);
			// Binary @:length prefix — read an N-byte ASCII-encoded length
			// BEFORE any field-level lead literal. The parsed integer is
			// stored in `_lenPrefix_<field>` and consumed by the
			// `bin.lengthPrefix` branch in the Terminal case below, which
			// uses it as the byte count for a variable-length Bytes payload.
			final lenPrefix: Null<{ width: Int, encoding: String }> = child.annotations.get('bin.lengthPrefix');
			if (lenPrefix != null) emitBinLengthPrefix(fieldName, lenPrefix.width, lenPrefix.encoding, parseSteps);
			// ω-condition-wrap-keep: a mandatory-Ref condition field of a
			// `@:fmt(condWrap)` struct opted in via
			// `@:fmt(captureCondOpenNewline)` captures whether the source broke
			// right after the open paren (`if (\n\tcond`). The probe spans the
			// gap between the end of the `@:lead('(')` literal (BEFORE its
			// post-lead `skipWs`) and the cond's first token (AFTER the
			// pre-field `skipWs` at L~2224). Trivia+bearing only — plain mode
			// keeps the original struct shape (no slot synthesised). Read by
			// the writer's single-Ref condWrap emit under `WrapMode.Keep`.
			final hasCondOpenNewlineSlot: Bool = hasCondOpenNewlineField(sc, child, typePath, isStar, isOptional, leadText);
			final condOpenNewlineLocal: String = '_condOpenNewline_$fieldName';
			emitFieldLeadIn(parseSteps, isStar, isOptional, kwLead, leadText, hasCondOpenNewlineSlot);
			// Field value — by kind.
			final localName: String = '_f_$fieldName';
			// Suppress the pre-field `skipWs` only for a trivia-collecting
			// Star with no lead literal (HxModule.decls). There the outer
			// skipWs would discard the file's first leading comments
			// before the Star loop's `collectTrivia` sees them. When a
			// lead IS present (HxClassDecl.members `{`, HxFnDecl.body `{`)
			// the outer skipWs belongs before the lead — comments between
			// the lead `{` and the first member are captured by
			// `collectTrivia` inside the loop regardless.
			final fieldFlags = computeStructFieldFlags(sc, child, node, typePath, isStar, isOptional, kwLead, leadText);
			final triviaEofStar: Bool = fieldFlags.triviaEofStar;
			final isOptionalRef: Bool = fieldFlags.isOptionalRef;
			final isOptionalKwStar: Bool = fieldFlags.isOptionalKwStar;
			final hasBeforeNewlineSlot: Bool = fieldFlags.hasBeforeNewlineSlot;
			final hasBeforeLeadingSlot: Bool = fieldFlags.hasBeforeLeadingSlot;
			final optStarWithLead: Bool = fieldFlags.optStarWithLead;
			// The pre-emit dispatch flags above are computed in computeStructFieldFlags;
			// see there for the per-flag rationale (ω₆a optional-Ref ws ownership,
			// ω-cond-comp-engine optional-kw Star, ω-issue-48-v2 / ω-untyped-keep-trybody
			// / ω-casepattern-keep BeforeNewline slot, ω-598-member-leading-comment
			// BeforeLeading slot).
			final beforeNlLocal: String = beforeNewlineLocalName(fieldName);
			final beforeLeadingLocal: String = beforeLeadingLocalName(fieldName);
			// ω-optional-star-rewind: when the field is `@:optional Star`
			// with `@:lead` (e.g. `HxTypeRef.params:Array<HxType>` —
			// `<...>`), defer the pre-field `skipWs` into the emit so the
			// emit can rewind cursor on `matchLit` miss. The miss-rewind
			// preserves any trivia (notably doc-comments between
			// `typedef Foo = Int` and the next decl) that the pre-field
			// `skipWs` would otherwise silently consume — closes
			// issue_216 / issue_321 cluster's parser-side bug.
			// ω-region-prefix-blank: opt-in third slot of the pre-field gap.
			final hasBeforeBlankSlot: Bool = hasBeforeBlankSlotFor(child, hasBeforeLeadingSlot);
			final beforeBlankLocal: String = beforeBlankLocalName(fieldName);
			emitPreFieldWs(
				parseSteps, triviaEofStar, isOptionalRef, isOptionalKwStar, optStarWithLead, hasBeforeLeadingSlot, hasBeforeNewlineSlot,
				beforeNlLocal, beforeLeadingLocal, hasCondOpenNewlineSlot, condOpenNewlineLocal,
				hasBeforeBlankSlot ? beforeBlankLocal : null
			);
			// ω-condition-wrap-keep: the pre-field `skipWs` above advanced
			// `ctx.pos` to the cond's first token, so `hasNewlineIn` over
			// `[_condLeadEnd, ctx.pos)` answers "did the source break right
			// after `(`?". Captured into the local that the struct literal
			// writes onto the `<field>CondOpenNewline:Bool` synth slot. Runs
			// only for the opted-in condWrap cond field; `_condLeadEnd` was
			// declared right after the lead `expectLit` above.
			// ω-issue-316: for `@:optional @:kw(...)` Ref fields in Trivia
			// mode, declare per-field locals that capture (a) a same-line
			// trailing comment after the kw and (b) own-line leading comments
			// between the kw and the body's first token. These land on synth
			// sibling slots `<field>AfterKw:Null<String>` and
			// `<field>KwLeading:Array<String>` of the paired type. Writer
			// consumes them to preserve source layout.
			//
			// ω-keep-policy: two additional source-shape booleans captured
			// on the same path — `_beforeKwNl_<field>` records whether the
			// whitespace between the preceding token and the kw crossed a
			// newline; `_bodyOnSameLine_<field>` records whether the body
			// follows the kw on the same line. Both default to `false` on
			// the commit-miss path. Landed on synth slots
			// `<field>BeforeKwNewline:Bool` / `<field>BodyOnSameLine:Bool`
			// for the writer's `Keep` dispatch.
			// Sidecar slots (<field>AfterKw, <field>KwLeading, <field>BeforeKwNewline,
			// <field>BodyOnSameLine) only exist on the synth paired `*T` type of
			// trivia-bearing rules. Non-bearing rules have no paired type and the
			// plain typedef has no sidecar fields, so emitting the locals +
			// struct-literal writes for them would reference fields that do not
			// exist on the target type. First non-bearing consumer of the
			// `@:optional @:kw(...)` pattern is `HxIfExpr` — the expression-
			// position `if`. Gating on bearing mirrors every other trivia-
			// conditional branch in the codegen (`parseFnName`, `ruleReturnCT`,
			// `ruleCtorPath` all return the plain form for non-bearing refs in
			// trivia mode).
			final hasKwTriviaSlots: Bool = hasKwTriviaSlotsField(sc, typePath, isOptionalRef, isOptionalKwStar, kwLead);
			final afterKwLocal: String = '_afterKw_$fieldName';
			final kwLeadingLocal: String = '_kwLeading_$fieldName';
			final beforeKwNlLocal: String = '_beforeKwNl_$fieldName';
			final bodyOnSameLineLocal: String = '_bodyOnSameLine_$fieldName';
			final beforeKwLeadingLocal: String = '_beforeKwLeading_$fieldName';
			final beforeKwTrailingLocal: String = '_beforeKwTrailing_$fieldName';
			// ω-optional-ref-trail: pre-declare the
			// `<field>AfterTrail` capture local before the parse step so
			// the optional-Ref's lead-led commit branch can assign into
			// it after `expectLit(trail)`, while the absent branch leaves
			// the default `null`. Mandatory-Ref path declares the same
			// local fresh post-trail (`final … = collectTrailing(ctx)`)
			// — the names collide harmlessly because the mandatory and
			// optional paths are mutually exclusive per field.
			final trailPresentLocal: String = '_trailPresent_$fieldName';
			final trailSidecar = emitTrailSidecarDecls(
				sc, child, typePath, fieldName, isStar, isOptional, trailText, trailPresentLocal, parseSteps
			);
			final hasOptionalRefAfterTrailSlot: Bool = trailSidecar.hasOptionalRefAfterTrailSlot;
			final hasStructFieldTrailOptSlot: Bool = trailSidecar.hasStructFieldTrailOptSlot;
			final captureTrailPresentExpr: Expr = trailSidecar.captureTrailPresentExpr;
			// hasOptionalRefAfterTrailSlot / hasStructFieldTrailOptSlot and the two
			// _afterTrail_/_trailPresent_ accumulator decls + captureTrailPresentExpr
			// splice are computed/emitted by emitTrailSidecarDecls; see there.
			if (hasKwTriviaSlots) {
				emitKwTriviaSlotDecls(
					afterKwLocal, kwLeadingLocal, beforeKwNlLocal, bodyOnSameLineLocal, beforeKwLeadingLocal, beforeKwTrailingLocal,
					parseSteps
				);
			}
			emitFieldValueByKind(
				sc, child, node, fieldName, localName, parseSteps, isOptional, kwLead, leadText, trailText, absentOnLits, absentOnEof,
				hasOptionalRefAfterTrailSlot, captureTrailPresentExpr, hasKwTriviaSlots, afterKwLocal, kwLeadingLocal, beforeKwNlLocal,
				bodyOnSameLineLocal, beforeKwLeadingLocal, beforeKwTrailingLocal, lenPrefix, hasBeforeNewlineSlot
			);
			// Per-field trail. Skipped for Star fields — `emitStarFieldSteps`
			// already emitted the close literal as part of the loop wrappers.
			// Mandatory Ref path: the close + same-line `// comment`
			// capture live here. Optional Ref + lead + trail:
			// the trail consumption AND `collectTrailing` capture live
			// inside the lead-led commit branch (see the Ref-with-trail
			// splicing into `subCall` above); the slot is still emitted
			// to the struct literal via the post-switch `hasAfterTrailSlot`
			// branch below — `_afterTrail_<field>` is pre-declared in the
			// optional-Ref step to default-null in the absent branch.
			final hasAfterTrailSlot: Bool = hasAfterTrailSlotField(sc, child, typePath, isStar, trailText);
			final afterTrailLocal: String = '_afterTrail_$fieldName';
			// ω-before-trail: twin of the above on the OTHER side of the same
			// literal. Declared fresh by `emitFieldTrail` right before the trail
			// consumption, so no pre-declaration is needed — the mandatory path
			// is the only one that reaches it.
			final hasBeforeTrailSlot: Bool = hasBeforeTrailSlotField(sc, child, typePath, isStar, isOptional, trailText);
			final beforeTrailLocal: String = '_beforeTrail_$fieldName';
			// `@:trailOpt("close")` on a struct Ref field: optional
			// trailing literal. The required-trail block above reads the
			// `:trail` meta only (`trailText`), so a `@:trailOpt` field
			// has `trailText == null` and is skipped there. Mirror
			// `lowerEnumBranch`'s `lit.trailOptional` handling (the
			// `else if (trailOptional) matchLit` arm): peek + consume the
			// literal if present, do NOT throw if absent. The literal is
			// consumed, not stored — the AST is identical to the
			// no-literal form. Plain `matchLit` in both modes; no trivia
			// `trailPresent` synth (the round-trip contract for the
			// struct-field consumer is idempotency, not byte presence —
			// no `@:fmt(trailOptShapeGate)` here). First consumer:
			// `HxIfExpr.thenBranch` (`if (c) e1; else e2` in value
			// position; the Build.hx offset-25 self-parse blocker).
			final trailOptText: Null<String> = child.annotations.get(AnnotationKeys.LIT_TRAIL_OPTIONAL) == true
				? child.annotations.get(AnnotationKeys.LIT_TRAIL_TEXT)
				: null;
			emitFieldTrail(
				parseSteps, isStar, isOptional, trailText, hasAfterTrailSlot, afterTrailLocal, trailOptText, captureTrailPresentExpr,
				hasBeforeTrailSlot, beforeTrailLocal
			);
			// ω-cond-comp-expr-multiline: terminal-slot newline capture for
			// bare Ref fields opted in via `@:fmt(captureSourceNewlineAfter)`.
			// Mirrors `hasBeforeNewlineSlot` (which captures the gap BEFORE
			// the field's first token) — this captures the gap AFTER. Drains
			// any `pendingTrivia` stashed by the field's parse path
			// (e.g. Pratt / postfix newline-stash on the bare-Ref's own
			// expression body) AND consumes inter-token whitespace through
			// to the next non-whitespace byte. The captured trivia is
			// re-stashed into `ctx.pendingTrivia` so the next field's own
			// `collectTrivia` can replay it for its leading-newline slot —
			// without the re-stash, the newline would be consumed by the
			// terminal slot's read alone and the downstream signal walker
			// in `WriterLowering.padTrailingDoc` would lose its primary
			// (non-terminal) signal.
			final newlineAfter: { newlineAfterLocal: String, hasNewlineAfterSlot: Bool } = emitNewlineAfterCapture(
				sc, child, typePath, fieldName, isStar, trailText, parseSteps
			);
			final hasNewlineAfterSlot: Bool = newlineAfter.hasNewlineAfterSlot;
			final newlineAfterLocal: String = newlineAfter.newlineAfterLocal;
			pushStructFieldEntries(
				sc, structFields, fieldName, localName, child, hasStructFieldTrailOptSlot, trailPresentLocal, hasAfterTrailSlot,
				afterTrailLocal, hasBeforeNewlineSlot, beforeNlLocal, hasBeforeLeadingSlot, beforeLeadingLocal, hasNewlineAfterSlot,
				newlineAfterLocal, hasCondOpenNewlineSlot, condOpenNewlineLocal, hasKwTriviaSlots, afterKwLocal, kwLeadingLocal,
				beforeKwNlLocal, bodyOnSameLineLocal, beforeKwLeadingLocal, beforeKwTrailingLocal, hasBeforeTrailSlot, beforeTrailLocal
			);
			// pushStructFieldEntries pushes the field value + every applicable
			// trivia/source-shape sidecar slot (TrailPresent / AfterTrail /
			// BeforeNewline / BeforeLeading / NewlineAfter / CondOpenNewline / the
			// kw-trivia set / TrailingStar slots / SepBefore); see there for the
			// per-slot gating rationale.
		}
		// Binary: @:align — skip to next alignment boundary after all fields.
		final align: Null<Int> = node.annotations['bin.align'];
		if (align != null) {
			parseSteps.push(macro {
				final _rem: Int = ctx.pos % $v{align};
				if (_rem != 0 && ctx.pos < ctx.input.length) ctx.pos += $v{align} - _rem;
			});
		}
		// ω-spanned-struct: a Seq typedef tagged `@:spanned('<Kind>')` opts
		// out of QueryNode transparency. Its paired `*S` struct carries
		// `_span` + `_kind` (synthesised by SpanTypeSynth); inject the
		// matching values here so `HaxeQueryPlugin.appendNodes` can surface
		// it as an addressable node. `_start` is in scope because
		// `instrumentSpans` wraps the whole rule body for span-bearing
		// (incl. Seq) rules. Flat/no-span builds skip both fields entirely.
		final spannedKind: Null<String> = node.readMetaString(':spanned');
		if (sc.ctx.spans && spannedKind != null) {
			structFields.push({ field: '_span', expr: macro new anyparse.runtime.Span(_start, ctx.pos) });
			structFields.push({ field: '_kind', expr: macro $v{spannedKind} });
		}
		final structLiteral: Expr = { expr: EObjectDecl(structFields), pos: Context.currentPos() };
		parseSteps.push(macro return $structLiteral);
		return macro $b{parseSteps};
	}


	/**
	 * True when the struct node should be lowered as a key-dispatched
	 * (ByName) object. Two conditions must hold: the resolved format
	 * has `fieldLookup == ByName` and no field on the struct carries
	 * positional metadata (`@:kw`, `@:lead`, `@:trail`, `@:sep`) or
	 * binary metadata. The positional Haxe grammar uses anchors to
	 * describe fixed syntax — those structs stay on the original
	 * positional codepath even though `HaxeFormat` also declares
	 * `ByName`. Binary schemas never reach this branch (`isBinary`
	 * short-circuits `fieldLookup` to a non-ByName default inside
	 * `FormatReader`).
	 */
	private static function shouldLowerByName(sc: StructSeqCtx, node: ShapeNode): Bool {
		if (sc.formatInfo.isBinary) return false;
		if (sc.formatInfo.fieldLookup != ByName) return false;
		if (sc.formatInfo.keySyntax != Quoted) return false;
		if (node.annotations[AnnotationKeys.BIN_MAGIC] != null) return false;
		if (node.annotations['bin.align'] != null) return false;
		for (child in node.children) {
			if (child.readMetaString(':kw') != null) return false;
			if (child.readMetaString(':lead') != null) return false;
			if (child.readMetaString(':trail') != null) return false;
			if (child.readMetaString(':sep') != null) return false;
		}
		return true;
	}

	/**
	 * Lower a typedef struct as a JSON-style key-dispatched object. The
	 * generated body emits one `Null<T>` local per field, then runs a
	 * loop that reads `"key"`, dispatches to the matching field's
	 * parser, and finally materialises the struct literal. Unknown keys
	 * are routed by the format's `onUnknown` policy — `Skip` silently
	 * consumes the value via `_skipJsonValue`, `Error` raises a
	 * `ParseError` naming the offending key. Non-optional fields are
	 * checked for null after the loop and raise `ParseError` listing
	 * the missing name; optional fields retain their `null` default.
	 */
	private static function lowerStructByName(sc: StructSeqCtx, node: ShapeNode): Expr {
		final structFields: Array<ObjectField> = [];
		final declareLocals: Array<Expr> = [];
		final switchCases: Array<Case> = [];
		final missingChecks: Array<Expr> = [];
		for (child in node.children) {
			final fieldName: Null<String> = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			if (fieldName == null) Context.fatalError('Lowering: ByName struct field missing base.fieldName', Context.currentPos());
			final isOptional: Bool = child.annotations.get(AnnotationKeys.BASE_OPTIONAL) == true;
			final fieldCT: Null<ComplexType> = child.annotations.get(AnnotationKeys.BASE_FIELD_TYPE);
			if (fieldCT == null)
				Context.fatalError('Lowering: ByName struct field "$fieldName" missing base.fieldType', Context.currentPos());
			final localName: String = '_f_$fieldName';
			final localCT: ComplexType = isOptional ? fieldCT : TPath({ pack: [], name: 'Null', params: [TPType(fieldCT)] });
			declareLocals.push({
				expr: EVars([
					{
						name: localName,
						type: localCT,
						expr: macro null,
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
			final parseCall: Expr = byNameFieldParseExpr(sc, child, fieldName);
			switchCases.push({
				values: [{ expr: EConst(CString(fieldName)), pos: Context.currentPos() }],
				expr: macro $i{localName} = $parseCall
			});
			if (isOptional) {
				structFields.push({ field: fieldName, expr: macro $i{localName} });
			} else {
				final errMsg: String = 'missing required field "$fieldName"';
				final checkedName: String = '_r_$fieldName';
				// Two-step unwrap: the `if (... == null) throw` narrows the
				// local in the subsequent statement, and the `final` re-bind
				// produces a non-null local that the struct literal can
				// consume without tripping the object-literal inference
				// collapsing back to Null<T>.
				missingChecks.push(macro {
					if ($i{localName} == null)
						throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{errMsg});
				});
				missingChecks.push({
					expr: EVars([
						{
							name: checkedName,
							type: fieldCT,
							expr: macro $i{localName},
							isFinal: true
						}
					]),
					pos: Context.currentPos()
				});
				structFields.push({ field: fieldName, expr: macro $i{checkedName} });
			}
		}
		final defaultExpr: Expr = switch sc.formatInfo.onUnknown {
			case Skip:
				final anyType: Null<String> = sc.formatInfo.anyType;
				if (anyType == null) {
					Context.fatalError(
						'Lowering: UnknownPolicy.Skip requires the format ${sc.formatInfo.schemaTypePath}'
						+ ' to declare anyType (the universal-value grammar type used to consume unknown keys)',
						Context.currentPos()
					);
					throw 'unreachable';
				}
				final anyFn: String = 'parse${simpleName(anyType)}';
				// Skip still SKIPS — the value is consumed and discarded, so
				// parse behaviour and the forward-compat contract are
				// unchanged. What changes is that the key is no longer
				// dropped without trace: it lands on the context with the
				// schema's own field list beside it, and a boundary that
				// knows where the input came from can say so. A consumer
				// that never reads `ctx.unknownFields` sees nothing.
				final knownNames: Expr = {
					expr: EArrayDecl([for (c in switchCases) c.values[0]]),
					pos: Context.currentPos()
				};
				macro {
					ctx.recordUnknownField(_key, _keyPos, $knownNames);
					$i{anyFn}(ctx);
				};
			case Error: macro throw new anyparse.runtime.ParseError(
				new anyparse.runtime.Span(ctx.pos, ctx.pos), 'unknown field: "' + _key + '"'
			);
			case _:
				Context.fatalError(
					'Lowering: UnknownPolicy.Store is not supported in ByName mode (schema ${sc.formatInfo.schemaTypePath})',
					Context.currentPos()
				);
				throw 'unreachable';
		};
		final switchExpr: Expr = { expr: ESwitch(macro _key, switchCases, defaultExpr), pos: Context.currentPos() };
		final structLiteral: Expr = { expr: EObjectDecl(structFields), pos: Context.currentPos() };
		// The field locals sit ahead of the shared mapping loop — pure
		// null-init declarations, so their position relative to the open
		// literal is unobservable.
		final parseSteps: Array<Expr> = declareLocals;
		parseSteps.push(byNameMappingLoopExpr(sc, 'ByName struct parsing', '_key', switchExpr));
		for (c in missingChecks) parseSteps.push(c);
		parseSteps.push(macro return $structLiteral);
		return macro $b{parseSteps};
	}

	private static function byNameFieldParseExpr(sc: StructSeqCtx, child: ShapeNode, fieldName: String): Expr {
		return switch child.kind {
			case Ref:
				final refName: String = child.annotations[AnnotationKeys.BASE_REF];
				final fnName: String = sc.parseFnName(refName);
				{ expr: ECall(macro $i{fnName}, [macro ctx]), pos: Context.currentPos() };
			case Star:
				child.annotations.exists(AnnotationKeys.BASE_MAP_VALUE)
					? byNameMapParseExpr(sc, child, fieldName)
					: byNameStarParseExpr(sc, child, fieldName);
			case _:
				Context.fatalError(
					'Lowering: ByName struct field "$fieldName" has unsupported kind ${child.kind}'
					+ ' — format ${sc.formatInfo.schemaTypePath} may be missing a primitive type mapping',
					Context.currentPos()
				);
				throw 'unreachable';
		};
	}

	/**
	 * Emit the parse expression for a `ByName` struct field whose type is
	 * `Array<T>`. Walks `formatInfo.sequenceOpen` / `entrySep` /
	 * `sequenceClose` to drive the loop. Inner element parsing routes
	 * through the Ref case's helpers (`parseFnName` + `ruleReturnCT`),
	 * picking up trivia-bearing paths and JSON primitive rewrites
	 * (`Array<HxFormatWrapRule>` reads via `parseHxFormatWrapRule`,
	 * etc.).
	 *
	 * The accumulator local is typed against the field's declared
	 * element type (extracted from `base.fieldType`) rather than the
	 * inner Ref's rewrite target, so primitive-rewrite cases — where
	 * the schema declares `Array<Int>` but the inner Ref points at
	 * `anyparse.grammar.json.JIntLit` — keep the schema's invariant
	 * `Array<Int>` shape and rely on the abstract's `from Int to Int`
	 * conversion at each `push`.
	 *
	 * The element shape must be a single `Ref` child; nested `Star` is
	 * deferred until a real schema needs `Array<Array<T>>`.
	 */
	private static function byNameStarParseExpr(sc: StructSeqCtx, child: ShapeNode, fieldName: String): Expr {
		final seqOpen: Null<String> = sc.formatInfo.sequenceOpen;
		final seqClose: Null<String> = sc.formatInfo.sequenceClose;
		if (seqOpen == null || seqClose == null) {
			Context.fatalError(
				'Lowering: ByName Array<T> field "$fieldName" requires the format ${sc.formatInfo.schemaTypePath} '
				+ 'to declare sequenceOpen / sequenceClose',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		if (child.children.length != 1) {
			Context.fatalError(
				'Lowering: ByName Array<T> field "$fieldName" expected exactly one element child, got ${child.children.length}',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final inner: ShapeNode = child.children[0];
		if (inner.kind != Ref) {
			Context.fatalError(
				'Lowering: ByName Array<T> field "$fieldName" element kind ${inner.kind} is not supported '
				+ '— only Array<RefType> (a single named element type) is implemented',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final refName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final fnName: String = sc.parseFnName(refName);
		final fieldCT: Null<ComplexType> = child.annotations[AnnotationKeys.BASE_FIELD_TYPE];
		final innerCT: ComplexType = extractArrayElementCT(fieldCT) ?? sc.ruleReturnCT(refName);
		final closeCharCode: Int = seqClose.charCodeAt(0);
		final entrySep: String = sc.formatInfo.entrySep;
		return macro {
			final _arr: Array<$innerCT> = [];
			skipWs(ctx);
			expectLit(ctx, $v{seqOpen});
			skipWs(ctx);
			if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
				while (true) {
					skipWs(ctx);
					_arr.push($i{fnName}(ctx));
					skipWs(ctx);
					if (!matchLit(ctx, $v{entrySep})) break;
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{seqClose});
			_arr;
		};
	}

	/**
	 * Parse expression for a ByName `Map<String, V>` field — the
	 * arbitrary-key counterpart of `byNameStarParseExpr`. Emits the
	 * SHARED `byNameMappingLoopExpr` skeleton (the same one
	 * `lowerStructByName` uses, so the two mapping dialects cannot
	 * drift), storing every entry under the key it just parsed instead
	 * of dispatching on a declared field name. The value rule comes
	 * from the Star's single Ref child, exactly like the Array twin;
	 * the accumulator is typed against the schema-DECLARED value type
	 * when extractable (paired-type symmetry with
	 * `extractArrayElementCT`). Parse-only: the ByName WRITER path
	 * fatal-errors on a Map field (see `byNameFieldWriteExpr`).
	 */
	private static function byNameMapParseExpr(sc: StructSeqCtx, child: ShapeNode, fieldName: String): Expr {
		final inner: ShapeNode = child.children[0];
		if (inner.kind != Ref) {
			Context.fatalError(
				'Lowering: ByName Map<String, V> field "$fieldName" value kind ${inner.kind} is not supported '
				+ '— only Map<String, RefType> (a single named value type) is implemented',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final refName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final valueFn: String = sc.parseFnName(refName);
		final fieldCT: Null<ComplexType> = child.annotations[AnnotationKeys.BASE_FIELD_TYPE];
		final valueCT: ComplexType = extractMapValueCT(fieldCT) ?? sc.ruleReturnCT(refName);
		final loop: Expr = byNameMappingLoopExpr(
			sc, 'ByName Map<String, V> field "$fieldName"', '_mapKey', macro {
				_map[_mapKey] = $i{valueFn}(ctx);
			}
		);
		return macro {
			final _map: Map<String, $valueCT> = [];
			$loop;
			_map;
		};
	}

	/**
	 * The one ByName mapping-loop skeleton: `skipWs; expectLit(open);
	 * [empty-mapping short-circuit; loop: key via the format's
	 * `stringType` parser bound to `<keyLocal>`, expectLit(keyValueSep),
	 * <perEntry>, matchLit(entrySep) or break]; skipWs;
	 * expectLit(close)`. Both ByName consumers — the fixed-field struct
	 * dispatch (`lowerStructByName`) and the arbitrary-key Map field
	 * (`byNameMapParseExpr`) — splice THIS skeleton with only the
	 * per-entry statement differing, so key / separator / close /
	 * trailing-sep semantics cannot drift between the two dialects.
	 * `site` names the caller for the stringType diagnostic.
	 */
	private static function byNameMappingLoopExpr(sc: StructSeqCtx, site: String, keyLocal: String, perEntry: Expr): Expr {
		final stringType: Null<String> = sc.formatInfo.stringType;
		if (stringType == null) {
			Context.fatalError(
				'Lowering: $site requires the format ${sc.formatInfo.schemaTypePath} '
				+ 'to declare stringType (the grammar type used to parse mapping keys)',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final keyFn: String = 'parse${simpleName(stringType)}';
		// The key's own start offset, captured before the key is consumed:
		// the unknown-key arm runs after the key AND its separator have been
		// read, so `ctx.pos` no longer points anywhere useful for a
		// diagnostic. One Int local per entry, on every ByName mapping.
		final keyPosDecl: Expr = {
			expr: EVars([
				{
					name: '${keyLocal}Pos',
					type: macro :Int,
					expr: macro ctx.pos,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		};
		final keyDecl: Expr = {
			expr: EVars([
				{
					name: keyLocal,
					type: macro :String,
					expr: { expr: ECall(macro $i{keyFn}, [macro ctx]), pos: Context.currentPos() },
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		};
		final mappingOpen: String = sc.formatInfo.mappingOpen;
		final mappingClose: String = sc.formatInfo.mappingClose;
		final keyValueSep: String = sc.formatInfo.keyValueSep;
		final entrySep: String = sc.formatInfo.entrySep;
		final closeCharCode: Int = mappingClose.charCodeAt(0);
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{mappingOpen});
			skipWs(ctx);
			if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
				while (true) {
					skipWs(ctx);
					$keyPosDecl;
					$keyDecl;
					skipWs(ctx);
					expectLit(ctx, $v{keyValueSep});
					skipWs(ctx);
					$perEntry;
					skipWs(ctx);
					if (!matchLit(ctx, $v{entrySep})) break;
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{mappingClose});
		};
	}


	/**
	 * Emit the `case Ref if (isOptional)` struct-field arm: the lead/kw/absentOn
	 * peek-commit machinery for an optional Ref field. Pushes a single `EVars`
	 * (the `_f_<field>` capture) onto `parseSteps`. Threaded from `lowerStruct`
	 * so the loop's mutable accumulators stay in the loop; this helper is a pure
	 * Expr-builder over the per-field locals it receives.
	 */
	private static function emitOptionalRefField(
		sc: StructSeqCtx, child: ShapeNode, fieldName: String, localName: String, parseSteps: Array<Expr>, kwLead: Null<String>,
		leadText: Null<String>, trailText: Null<String>, absentOnLits: Null<Array<String>>, absentOnEof: Bool,
		hasOptionalRefAfterTrailSlot: Bool, captureTrailPresentExpr: Expr, hasKwTriviaSlots: Bool, afterKwLocal: String,
		kwLeadingLocal: String, beforeKwNlLocal: String, bodyOnSameLineLocal: String, beforeKwLeadingLocal: String,
		beforeKwTrailingLocal: String, hasBeforeSlots: Bool
	): Void {
		if (kwLead == null && leadText == null && absentOnLits == null && !absentOnEof) {
			Context.fatalError(
				'Lowering: @:optional struct field "$fieldName" requires @:lead, @:kw, @:absentOn or @:absentOnEof', Context.currentPos()
			);
		}
		final refName: String = child.annotations[AnnotationKeys.BASE_REF];
		final subCallRaw: Expr = {
			expr: ECall(macro $i{sc.parseFnName(refName)}, [macro ctx]),
			pos: Context.currentPos()
		};
		// ω-optional-ref-trail: consume the per-field `@:trail`
		// literal AFTER the sub-rule parse, INSIDE the lead-led
		// commit branch. Mirrors the mandatory-Ref trail emit
		// (see post-switch block) but threaded into the optional
		// path so the commit-miss branch (lead absent) does not
		// expect a close. First consumer: `HxAbstractDecl.
		// underlyingType` for the `@:coreType` bare-abstract
		// shape `abstract Foo from Int to Int {}`.
		final captureAfterTrail: Expr = hasOptionalRefAfterTrailSlot
			? macro $i{'_afterTrail_$fieldName'} = collectTrailingFull(ctx)
			: macro {};
		// ω-optional-ref-trailOpt (Session 11 path b): consume
		// the per-field `@:trailOpt(';')` literal AFTER the
		// sub-rule parse, INSIDE the lead/kw commit branch.
		// Mirrors the mandatory `@:trail` arm above but uses
		// peek+consume+rewind (no throw on miss) so existing
		// self-consuming inner stmts (ReturnStmt-pre-S10.3,
		// ExprStmt, etc.) stay no-op. First consumer:
		// `HxIfStmt.elseBody` (`if (c) ...; else ...;` —
		// post-S10.3 ReturnStmt migration target). The
		// post-switch `lit.trailOptional` block (~L2500) is
		// gated `!isOptional`, so this arm is the optional+kw
		// path's sole emitter.
		final trailOptText: Null<String> = child.annotations[AnnotationKeys.LIT_TRAIL_OPTIONAL] == true
			? child.annotations[AnnotationKeys.LIT_TRAIL_TEXT]
			: null;
		final subCall: Expr = if (trailText != null)
			macro {
				final _v = $subCallRaw;
				skipWs(ctx);
				expectLit(ctx, $v{trailText});
				$captureAfterTrail;
				_v;
			}
		else if (trailOptText != null)
			macro {
				final _v = $subCallRaw;
				final _trailOptWsPos: Int = ctx.pos;
				skipWs(ctx);
				if (matchLit(ctx, $v{trailOptText}))
					$captureTrailPresentExpr;
				else
					ctx.pos = _trailOptWsPos;
				_v;
			}
		else
			subCallRaw;
		// In trivia or span mode a bearing ref needs the Null<XxxT>
		// / Null<XxxS> wrap around the synth pair — `base.fieldType`
		// captured the plain-mode `Null<Xxx>` form at shape-analysis
		// time so we rebuild it here when the target is bearing;
		// otherwise the cached annotation is re-used unchanged.
		final fieldCT: ComplexType = sc.isSpanBearing(refName) || sc.isTriviaBearing(refName)
			? TPath({ pack: [], name: 'Null', params: [TPType(sc.ruleReturnCT(refName))] })
			: child.annotations[AnnotationKeys.BASE_FIELD_TYPE];
		if (absentOnLits != null || absentOnEof) {
			// ω-region-prefix-blank: `hasBeforeSlots` IS this field's
			// BeforeNewline/BeforeLeading gate (`computeBeforeSlots` returns the same
			// `refSlot` for both), so the blank slot's own host predicate takes it
			// directly — no fourth flag threaded down the chain.
			emitAbsentOnRefField(
				sc, fieldName, localName, parseSteps, absentOnLits ?? [], absentOnEof, subCall, fieldCT, hasBeforeSlots,
				hasBeforeBlankSlotFor(child, hasBeforeSlots)
			);
		} else {
			emitOptionalRefLeadCommit(
				sc, parseSteps, localName, fieldCT, subCall, kwLead, leadText, hasKwTriviaSlots, afterKwLocal, kwLeadingLocal,
				beforeKwNlLocal, bodyOnSameLineLocal, beforeKwLeadingLocal, beforeKwTrailingLocal
			);
		}
	}

	/**
	 * `@:absentOn(lit1, lit2, ...)` — peek-ahead absence dispatch for an optional Ref field.
	 *
	 * The listed terminators are NOT consumed (they belong to the enclosing context); the parser
	 * just decides whether to call `parseRef` or set the field to `null`. On absence the pre-ws
	 * position is restored so any leading whitespace stays visible to the parent's next `skipWs`.
	 * On presence the call runs from the post-ws position; `parseRef` does not double-skip. Trivia
	 * mode applies the same `pendingTrivia` stash as the lead-led branch so leading comments
	 * captured before an absent body flow to the next sibling's `collectTrivia`.
	 *
	 * ω-orphan-prefix-member: with `@:fmt(bareRefSepWhenPresent)` the field ALSO carries the
	 * bare-Ref `<field>BeforeNewline` / `<field>BeforeLeading` slots, so the pre-peek
	 * `collectTrivia` result is captured into the two locals the struct literal reads instead of
	 * being handed straight to `pendingTrivia` — the writer needs those signals to reproduce the
	 * gap before a PRESENT field. The absent branch still stashes and rewinds, so trivia before
	 * the terminator stays visible to the enclosing Star.
	 */
	private static function emitAbsentOnRefField(
		sc: StructSeqCtx, fieldName: String, localName: String, parseSteps: Array<Expr>, absentOnLits: Array<String>, absentOnEof: Bool,
		subCall: Expr, fieldCT: ComplexType, hasBeforeSlots: Bool, hasBeforeBlankSlot: Bool
	): Void {
		// ω-orphan-prefix-decl: EOF is a disjunct of the same chain, not a
		// second mechanism — `@:absentOnEof` contributes `ctx.pos >=
		// ctx.input.length`, which is the terminator a module-scope Seq faces
		// and the ONE `@:absentOn` cannot spell (an empty literal peeks true
		// everywhere). The two metas compose: a field carrying both is absent
		// on either signal.
		final peekChain: Expr = {
			var acc: Null<Expr> = absentOnEof ? (macro ctx.pos >= ctx.input.length) : null;
			for (lit in absentOnLits) {
				final peek: Expr = macro peekLit(ctx, $v{lit});
				acc = acc == null ? peek : macro $acc || $peek;
			}
			acc;
		};
		final captureBeforeSlots: Bool = hasBeforeSlots && sc.ctx.trivia;
		if (captureBeforeSlots) emitAbsentOnBeforeSlots(fieldName, parseSteps, hasBeforeBlankSlot);
		final wsAction: Expr = sc.ctx.trivia
			? macro {
				final _t = collectTrivia(ctx);
				if (_t.leadingComments.length > 0 || _t.blankBefore || _t.blankAfterLeadingComments || _t.newlineBefore)
					ctx.pendingTrivia = _t;
			}
			: macro skipWs(ctx);
		// The absent branch REWINDS to `_absentWsPos`, which puts every byte
		// `collectTrivia` just read back in front of the cursor — so the enclosing
		// Star re-scans them, and must NOT ALSO be handed them through the stash, or
		// the same comment is emitted twice and doubles again on every further pass
		// (`#if a #end` with an own-line `// c` before the class `}` went 1 -> 2 -> 4).
		// Restoring the INCOMING stash instead keeps both halves right: bytes after
		// `_absentWsPos` come back through the re-scan, bytes before it — a preceding
		// empty Star's stash, which no rewind can reach — come back through here.
		final absentOnValueExpr: Expr = captureBeforeSlots
			? macro {
				if ($peekChain) {
					ctx.pendingTrivia = _absentPending;
					ctx.pos = _absentWsPos;
					null;
				} else {
					$subCall;
				}
			}
			: macro {
				final _wsPos: Int = ctx.pos;
				$wsAction;
				if ($peekChain) {
					ctx.pos = _wsPos;
					null;
				} else {
					$subCall;
				}
			};
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: fieldCT,
					expr: absentOnValueExpr,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

	/**
	 * Compute the per-field pre-emit dispatch booleans for one struct field.
	 * These gate the pre-field whitespace/trivia handling and the
	 * `<field>BeforeNewline` / `<field>BeforeLeading` synth-slot captures.
	 * The intermediate flags (`isBareTriviaRefNoLead`, `isFirstField`, …) stay
	 * internal; only the six downstream-read flags are returned. Lifted from
	 * `lowerStruct`'s per-field loop to keep its decision points out of the
	 * orchestrator.
	 */
	private static function computeStructFieldFlags(
		sc: StructSeqCtx, child: ShapeNode, node: ShapeNode, typePath: String, isStar: Bool, isOptional: Bool, kwLead: Null<String>,
		leadText: Null<String>
	): {
		triviaEofStar: Bool,
		isOptionalRef: Bool,
		isOptionalKwStar: Bool,
		hasBeforeNewlineSlot: Bool,
		hasBeforeLeadingSlot: Bool,
		optStarWithLead: Bool
	} {
		final triviaEofStar: Bool = isStar && child.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true
			&& child.readMetaString(':lead') == null && child.readMetaString(':kw') == null && sc.ctx.trivia;
		// Slice ω₆a: an @:optional Ref field takes ownership of its own
		// pre-field ws handling so the commit-check can rewind over the
		// just-consumed whitespace (and any comments inside it, in trivia
		// mode) when the kw/lead miss — that trivia belongs to the next
		// outer @:trivia Star loop, not to this discarded optional slot.
		final isOptionalRef: Bool = child.kind == Ref && isOptional;
		// ω-cond-comp-engine: `@:optional @:kw + tryparse Star` — kw-led
		// commit point on a Star field. Splices the kw commit + miss-rewind
		// machinery from the optional-Ref path with the tryparse Star loop
		// body. Mirrors `isOptionalRef`'s pre-field ws ownership: the
		// commit-check below performs its own ws scan + rewind so trivia
		// stays visible to the next outer @:trivia Star on commit miss.
		// First consumer: `HxConditionalDecl.elseBody` (`#if … #else <decls>
		// #end`). Replaces the pre-slice Ref-wrapper companion typedef
		// pattern (extra fn frame + wrapper struct alloc per `#else` hit).
		final isOptionalKwStar: Bool = child.kind == Star && isOptional && kwLead != null;
		// ω-issue-48-v2: a bare non-first Ref field (no `@:optional`, no
		// `@:kw`, no `@:lead`) in a trivia-bearing Seq captures the
		// `newlineBefore` signal in the gap between preceding content
		// and the sub-rule's first token. Needed when the preceding
		// bare-tryparse Star is empty (e.g. `HxMemberDecl.modifiers`
		// empty → `member` follows an `@:allow(...)\n` meta element):
		// the Star's rewind stashes trivia back to `ctx.pendingTrivia`,
		// and the pre-Ref `collectTrivia` here drains it, preserving
		// the newline on the synth `<field>BeforeNewline:Bool` slot.
		//
		// ω-untyped-keep-trybody: opt-in `@:fmt(beforeNewlineSlotFirst)`
		// extends the slot to FIRST Ref fields when the parent Alt-branch
		// carries `@:fmt(forwardNewlineForBody)` (which omits the parent's
		// post-kw `skipWs`). The first-field `collectTrivia` then scans
		// the gap between the parent kw and the field's first token
		// itself, capturing `newlineBefore` for the writer's `Keep`
		// dispatch. Currently consumed by `HxTryCatchStmt.body` to
		// preserve `try\n\tuntyped {…}` source shape under
		// `untypedBody=Keep`.
		final beforeSlots: { hasBeforeNewlineSlot: Bool, hasBeforeLeadingSlot: Bool } = computeBeforeSlots(
			sc, child, node, typePath, isStar, isOptional, kwLead, leadText
		);
		final hasBeforeNewlineSlot: Bool = beforeSlots.hasBeforeNewlineSlot;
		final hasBeforeLeadingSlot: Bool = beforeSlots.hasBeforeLeadingSlot;
		// ω-casepattern-keep: extend the first-field source-newline-before
		// capture to a bare (lead-less, non-optional) trivia Star whose
		// parent omits its post-kw `skipWs` via `forwardNewlineForBody`.
		// The condition Star (`HxCaseBranch.patterns`, `@:sep(',')
		// @:trail(':')`) then captures `newlineBefore` for the `case`→
		// pattern gap onto a `<field>BeforeNewline:Bool` slot, mirroring
		// the bare-Ref first-field case (`HxTryCatchStmt.body`). Gated on
		// the `beforeNewlineSlotFirst` opt-in so every other bare trivia
		// Star (no opt-in) keeps the plain pre-field `skipWs`.
		// ω-598-member-leading-comment: the bare non-first Ref host (e.g.
		// `HxMemberDecl.member`) additionally captures the `collectTrivia`
		// run's `leadingComments` into a `<field>BeforeLeading` slot. Gated
		// on the bare-Ref host (matches `TriviaTypeSynth.isBareNonFirstRef`),
		// NOT the Star-opt-in host. Without it, a multiline block comment
		// sitting between the last modifier and the member keyword (rejected
		// by the modifier Star's `collectTrailingFull` for its internal
		// newline) is scanned here but discarded.
		// ω-optional-star-rewind: when the field is `@:optional Star`
		// with `@:lead` (e.g. `HxTypeRef.params:Array<HxType>` —
		// `<...>`), defer the pre-field `skipWs` into the emit so the
		// emit can rewind cursor on `matchLit` miss. The miss-rewind
		// preserves any trivia (notably doc-comments between
		// `typedef Foo = Int` and the next decl) that the pre-field
		// `skipWs` would otherwise silently consume — closes
		// issue_216 / issue_321 cluster's parser-side bug.
		final optStarWithLead: Bool = isStar && isOptional && kwLead == null;
		return {
			triviaEofStar: triviaEofStar,
			isOptionalRef: isOptionalRef,
			isOptionalKwStar: isOptionalKwStar,
			hasBeforeNewlineSlot: hasBeforeNewlineSlot,
			hasBeforeLeadingSlot: hasBeforeLeadingSlot,
			optStarWithLead: optStarWithLead
		};
	}

	/**
	 * Push the parsed field value plus every applicable trivia/source-shape
	 * sidecar slot onto the struct literal for one field. Each `<field>*`
	 * synth slot is gated on the same `has*Slot` flag that grew it, so the
	 * struct-literal field set matches the synth-define exactly. The flags +
	 * capture-local names are threaded as params. Lifted from `lowerStruct`'s
	 * per-field loop.
	 */
	private static function pushStructFieldEntries(
		sc: StructSeqCtx, structFields: Array<ObjectField>, fieldName: Null<String>, localName: String, child: ShapeNode,
		hasStructFieldTrailOptSlot: Bool, trailPresentLocal: String, hasAfterTrailSlot: Bool, afterTrailLocal: String,
		hasBeforeNewlineSlot: Bool, beforeNlLocal: String, hasBeforeLeadingSlot: Bool, beforeLeadingLocal: String,
		hasNewlineAfterSlot: Bool, newlineAfterLocal: String, hasCondOpenNewlineSlot: Bool, condOpenNewlineLocal: String,
		hasKwTriviaSlots: Bool, afterKwLocal: String, kwLeadingLocal: String, beforeKwNlLocal: String, bodyOnSameLineLocal: String,
		beforeKwLeadingLocal: String, beforeKwTrailingLocal: String, hasBeforeTrailSlot: Bool, beforeTrailLocal: String
	): Void {
		structFields.push({ field: fieldName, expr: macro $i{localName} });
		// ω-struct-trailopt-source-track (Session 14 Phase 3): push the
		// `<field>TrailPresent` slot fed by the optional-Ref / mandatory-
		// Ref `@:trailOpt` capture above. Phase 4 wires the writer
		// reader; until then the populated true/false value is
		// unobserved (the slot's `@:optional Null<Bool>` shape would
		// also accept omission, but explicit push keeps the field
		// shape consistent and gives the writer a defined value at
		// every site).
		if (hasStructFieldTrailOptSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX, expr: macro $i{trailPresentLocal} });
		if (hasAfterTrailSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX, expr: macro $i{afterTrailLocal} });
		// ω-before-trail: the block comment captured just before the trail
		// literal, re-emitted there by `WriterLowering.emitMandatoryRefTrail`.
		if (hasBeforeTrailSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_TRAIL_SUFFIX, expr: macro $i{beforeTrailLocal} });
		if (hasBeforeNewlineSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX, expr: macro $i{beforeNlLocal} });
		// ω-598-member-leading-comment: push the verbatim leading-comment
		// run captured alongside the BeforeNewline scan above.
		if (hasBeforeLeadingSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_LEADING_SUFFIX, expr: macro $i{beforeLeadingLocal} });
		// ω-region-prefix-blank: the opt-in blank flag of the same scan. Derived
		// from `child` here rather than threaded, so the push cannot drift from
		// the capture — both call `hasBeforeBlankSlotFor`.
		if (hasBeforeBlankSlotFor(child, hasBeforeLeadingSlot)) structFields.push({
			field: fieldName + TriviaTypeSynth.BEFORE_BLANK_SUFFIX,
			expr: macro $i{beforeBlankLocalName(fieldName)}
		});
		if (hasNewlineAfterSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.NEWLINE_AFTER_SUFFIX, expr: macro $i{newlineAfterLocal} });
		// ω-condition-wrap-keep: push the `<field>CondOpenNewline:Bool`
		// slot fed by the open-paren newline probe above. Read by the
		// writer's single-Ref condWrap emit under `WrapMode.Keep`.
		if (hasCondOpenNewlineSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.CONDITION_OPEN_NEWLINE_SUFFIX, expr: macro $i{condOpenNewlineLocal} });
		if (hasKwTriviaSlots) {
			structFields.push({ field: fieldName + TriviaTypeSynth.AFTER_KW_SUFFIX, expr: macro $i{afterKwLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.KW_LEADING_SUFFIX, expr: macro $i{kwLeadingLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX, expr: macro $i{beforeKwNlLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.BODY_ON_SAME_LINE_SUFFIX, expr: macro $i{bodyOnSameLineLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX, expr: macro $i{beforeKwLeadingLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX, expr: macro $i{beforeKwTrailingLocal} });
		}
		if (sc.ctx.trivia && child.kind == Star && child.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true) {
			pushTrailingStarSlots(child, localName, fieldName, structFields);
		}
		// ω-condcomp-body-leading-sep: @:fmt(sepBeforeOpt)
		// on a Star field grows a `<field>SepBefore:Bool` slot fed by
		// the local declared inside `emitStarFieldSteps`'s
		// @:sep+@:tryparse-no-trail branch. The slot lives on the
		// trivia-paired typedef only (TriviaTypeSynth.buildTypeDefinition);
		// the plain typedef shape is unchanged. Gating on `ctx.trivia`
		// ensures plain-mode struct literals stay byte-identical to
		// pre-slice (the captured local is still declared above and
		// discarded — no field-shape mismatch).
		if (!(sc.ctx.trivia && child.kind == Star && child.fmtHasFlag('sepBeforeOpt'))) return;
		final sepBeforeLocal: String = '${localName}SepBefore';
		structFields.push({ field: fieldName + TriviaTypeSynth.SEP_BEFORE_SUFFIX, expr: macro $i{sepBeforeLocal} });
	}

	/**
	 * Compute the two trail-capture sidecar flags for a Ref field and emit
	 * their pre-declared accumulator locals: `_afterTrail_<field>` (null,
	 * filled by the optional-Ref lead-led commit branch) and
	 * `_trailPresent_<field>` (false, set true by the @:trailOpt matchLit hit).
	 * Returns the flags plus the shared `captureTrailPresentExpr` splice. Both
	 * locals are pushed onto `parseSteps`; the flags are read downstream by the
	 * switch arms, emitFieldTrail and pushStructFieldEntries. Lifted from
	 * `lowerStruct`.
	 */
	private static function emitTrailSidecarDecls(
		sc: StructSeqCtx, child: ShapeNode, typePath: String, fieldName: Null<String>, isStar: Bool, isOptional: Bool,
		trailText: Null<String>, trailPresentLocal: String, parseSteps: Array<Expr>
	): {
		hasOptionalRefAfterTrailSlot: Bool,
		hasStructFieldTrailOptSlot: Bool,
		captureTrailPresentExpr: Expr
	} {
		// ω-optional-ref-trail: pre-declare the
		// `<field>AfterTrail` capture local before the parse step so
		// the optional-Ref's lead-led commit branch can assign into
		// it after `expectLit(trail)`, while the absent branch leaves
		// the default `null`. Mandatory-Ref path declares the same
		// local fresh post-trail (`final … = collectTrailing(ctx)`)
		// — the names collide harmlessly because the mandatory and
		// optional paths are mutually exclusive per field.
		final hasOptionalRefAfterTrailSlot: Bool = child.kind == Ref && isOptional && !isStar && trailText != null && sc.ctx.trivia
			&& sc.isTriviaBearing(typePath);
		if (hasOptionalRefAfterTrailSlot) {
			parseSteps.push({
				expr: EVars([
					{
						name: '_afterTrail_$fieldName',
						type: macro :Null<String>,
						expr: macro null,
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
		}
		// ω-struct-trailopt-source-track (Session 14 Phase 3): struct
		// typedef Ref fields carrying `@:trailOpt(LIT)` capture matchLit
		// presence into `_trailPresent_<field>:Bool`. Mirrors the
		// synth-side `<field>TrailPresent` slot pushed by
		// `TriviaTypeSynth.buildStructFieldTrailPresentSlot` (Phase 2).
		// Local is pre-declared `false` here so BOTH the mandatory-Ref
		// path (post-switch L2517) and the optional-Ref + trailOpt path
		// (inside the Ref-isOptional switch arm L2237) can write into
		// the same name (the two paths are mutually exclusive per
		// field — `!isOptional` vs `isOptional`).
		//
		// Phase 4 will read this on the writer side to gate trail
		// re-emission on source presence; until then the captured
		// value is unobserved and Δsweep stays 0.
		final hasStructFieldTrailOptSlot: Bool = child.kind == Ref && !isStar
			&& child.annotations[AnnotationKeys.LIT_TRAIL_OPTIONAL] == true && sc.ctx.trivia && sc.isTriviaBearing(typePath);
		if (hasStructFieldTrailOptSlot) {
			parseSteps.push({
				expr: EVars([
					{
						name: trailPresentLocal,
						type: macro :Bool,
						expr: macro false,
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
		}
		// Splicing the same `Expr` into two `macro` blocks is safe —
		// macro Expr values are AST snapshots, not consumed on splice.
		// Shared between the optional-Ref subCall arm and the mandatory-
		// Ref post-switch matchLit (mutually exclusive per field).
		final captureTrailPresentExpr: Expr = hasStructFieldTrailOptSlot ? macro $i{trailPresentLocal} = true : macro {};
		return {
			hasOptionalRefAfterTrailSlot: hasOptionalRefAfterTrailSlot,
			hasStructFieldTrailOptSlot: hasStructFieldTrailOptSlot,
			captureTrailPresentExpr: captureTrailPresentExpr
		};
	}

	/**
	 * Emit the field-value parse steps for one struct field, dispatched by its
	 * shape kind: optional-Ref (peek-commit), bare Ref (direct sub-rule call),
	 * optional-kw Star / optional Star / plain Star (loop wrappers), or Terminal
	 * (binary fixed-len / int / data / length-prefixed). Each arm delegates to
	 * the corresponding emit*FieldSteps / emitBin* helper. Lifted from
	 * `lowerStruct`'s per-field loop.
	 */
	private static function emitFieldValueByKind(
		sc: StructSeqCtx, child: ShapeNode, node: ShapeNode, fieldName: Null<String>, localName: String, parseSteps: Array<Expr>,
		isOptional: Bool, kwLead: Null<String>, leadText: Null<String>, trailText: Null<String>, absentOnLits: Null<Array<String>>,
		absentOnEof: Bool, hasOptionalRefAfterTrailSlot: Bool, captureTrailPresentExpr: Expr, hasKwTriviaSlots: Bool, afterKwLocal: String,
		kwLeadingLocal: String, beforeKwNlLocal: String, bodyOnSameLineLocal: String, beforeKwLeadingLocal: String,
		beforeKwTrailingLocal: String, lenPrefix: Null<{ width: Int, encoding: String }>, hasBeforeSlots: Bool
	): Void {
		switch child.kind {
			case Ref if (isOptional):
				emitOptionalRefField(
					sc, child, fieldName, localName, parseSteps, kwLead, leadText, trailText, absentOnLits, absentOnEof,
					hasOptionalRefAfterTrailSlot, captureTrailPresentExpr, hasKwTriviaSlots, afterKwLocal, kwLeadingLocal, beforeKwNlLocal,
					bodyOnSameLineLocal, beforeKwLeadingLocal, beforeKwTrailingLocal, hasBeforeSlots
				);
			case Ref:
				final refName: String = child.annotations[AnnotationKeys.BASE_REF];
				// ω-splice-operand-run: `@:fmt(atomOperand)` on a bare struct Ref
				// retargets the call to the `${parseFn}Atom` variant of the
				// sub-rule, exactly as the single-Ref ENUM BRANCH arm already does
				// (`lowerKwRefBranch`, shipped for `HxExpr.CastExpr`). The operand
				// then binds at ATOM level — prefix and the whole postfix loop
				// included, infix Pratt excluded — so a trailing binary operator is
				// left for the NEXT field of the same struct instead of being
				// swallowed into the operand. That is what lets a struct model
				// `<operand> <operator>` as a pair without the Pratt loop ever
				// needing to rewind a failed right operand (`HxCondSpliceOpTerm`).
				final subFnName: String = child.fmtHasFlag(ATOM_OPERAND_FLAG) ? '${sc.parseFnName(refName)}Atom' : sc.parseFnName(refName);
				final callExpr: Expr = {
					expr: ECall(macro $i{subFnName}, [macro ctx]),
					pos: Context.currentPos()
				};
				parseSteps.push({
					expr: EVars([
						{
							name: localName,
							type: null,
							expr: callExpr,
							isFinal: true
						}
					]),
					pos: Context.currentPos()
				});
			case Star if (isOptional && kwLead != null):
				emitOptionalKwStarFieldSteps(
					sc, child, localName, parseSteps, kwLead, hasKwTriviaSlots, afterKwLocal, beforeKwNlLocal, bodyOnSameLineLocal,
					beforeKwLeadingLocal, beforeKwTrailingLocal
				);
			case Star if (isOptional):
				emitOptionalStarFieldSteps(sc, child, localName, parseSteps);
			case Star:
				final isLastField: Bool = child == node.children[node.children.length - 1];
				emitStarFieldSteps(
					sc, child, node.annotations[AnnotationKeys.BASE_TYPE_PATH], fieldName, localName, parseSteps, isLastField
				);
			case Terminal:
				final binFixedLen: Null<Int> = child.annotations['bin.fixedLen'];
				final binEncoding: Null<String> = child.annotations['bin.encoding'];
				final binDataRef: Null<String> = child.annotations['bin.dataRef'];
				if (lenPrefix != null)
					emitBinLengthBytesField(localName, fieldName, parseSteps);
				else if (binFixedLen != null && binEncoding != null)
					emitBinFixedIntField(localName, binFixedLen, binEncoding, fieldName, parseSteps);
				else if (binFixedLen != null)
					emitBinFixedStringField(localName, binFixedLen, parseSteps);
				else if (binDataRef != null)
					emitBinDataField(localName, binDataRef, parseSteps);
				else
					Context.fatalError(
						'Lowering: Terminal struct field "$fieldName" requires @:bin or @:length in binary format', Context.currentPos()
					);
			case _:
				Context.fatalError('Lowering: struct field kind ${child.kind} not supported', Context.currentPos());
		}
	}

	/**
	 * ω-cond-comp-expr-multiline: terminal-slot newline capture for bare Ref
	 * fields opted in via `@:fmt(captureSourceNewlineAfter)`. Computes the
	 * `hasNewlineAfterSlot` flag and, when set, emits the `_newlineAfter_<field>`
	 * decl + the collectTrivia capture (re-stashed into `ctx.pendingTrivia` so
	 * the next field's leading-newline slot still sees it). Returns the flag +
	 * capture-local name for the downstream struct-literal push. Lifted from
	 * `lowerStruct`.
	 */
	private static function emitNewlineAfterCapture(
		sc: StructSeqCtx, child: ShapeNode, typePath: String, fieldName: Null<String>, isStar: Bool, trailText: Null<String>,
		parseSteps: Array<Expr>
	): { hasNewlineAfterSlot: Bool, newlineAfterLocal: String } {
		final hasNewlineAfterSlot: Bool = child.kind == Ref && !isStar && trailText == null && sc.ctx.trivia
			&& sc.isTriviaBearing(typePath) && child.fmtHasFlag('captureSourceNewlineAfter');
		final newlineAfterLocal: String = '_newlineAfter_$fieldName';
		if (hasNewlineAfterSlot) {
			parseSteps.push({
				expr: EVars([
					{
						name: newlineAfterLocal,
						type: macro :Bool,
						expr: macro false,
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
			parseSteps.push(macro {
				final _captured = collectTrivia(ctx);
				$i{newlineAfterLocal} = _captured.newlineBefore;
				if (
					_captured.newlineBefore || _captured.blankBefore || _captured.blankAfterLeadingComments
					|| _captured.leadingComments.length > 0
				) {
					ctx.pendingTrivia = {
						blankBefore: _captured.blankBefore,
						blankAfterLeadingComments: _captured.blankAfterLeadingComments,
						newlineBefore: _captured.newlineBefore,
						leadingComments: _captured.leadingComments,
					};
				}
			});
		}
		return { hasNewlineAfterSlot: hasNewlineAfterSlot, newlineAfterLocal: newlineAfterLocal };
	}

	/**
	 * A mandatory-Ref condition field of a `@:fmt(condWrap)` struct opted in via
	 * `@:fmt(captureCondOpenNewline)` grows a `<field>CondOpenNewline:Bool` slot
	 * (trivia+bearing only). True for exactly that field shape. Pure predicate
	 * lifted from `lowerStruct`.
	 */
	private static function hasCondOpenNewlineField(
		sc: StructSeqCtx, child: ShapeNode, typePath: String, isStar: Bool, isOptional: Bool, leadText: Null<String>
	): Bool {
		return child.kind == Ref && !isStar && !isOptional && leadText != null && sc.ctx.trivia && sc.isTriviaBearing(typePath)
			&& child.fmtHasFlag('condWrap') && child.fmtHasFlag('captureCondOpenNewline');
	}

	/**
	 * An `@:optional @:kw(...)` Ref (or optional-kw Star) field in trivia mode
	 * on a bearing rule grows the kw-trivia sidecar slots (`<field>AfterKw` etc.).
	 * True for exactly that shape. Pure predicate lifted from `lowerStruct`.
	 */
	private static function hasKwTriviaSlotsField(
		sc: StructSeqCtx, typePath: String, isOptionalRef: Bool, isOptionalKwStar: Bool, kwLead: Null<String>
	): Bool {
		return (isOptionalRef || isOptionalKwStar) && kwLead != null && sc.ctx.trivia && sc.isTriviaBearing(typePath);
	}

	/**
	 * A mandatory-Ref field with `@:trail` in trivia mode on a bearing rule
	 * grows the `<field>AfterTrail` same-line-comment slot. True for exactly that
	 * shape. Pure predicate lifted from `lowerStruct`.
	 */
	private static function hasAfterTrailSlotField(
		sc: StructSeqCtx, child: ShapeNode, typePath: String, isStar: Bool, trailText: Null<String>
	): Bool {
		// Mandatory Ref with @:trail, OR a @:fmt(captureTrailComment)-opted Star
		// (case-pattern list ending in `:`) — capture a same-line comment after
		// the trail literal so it stays cuddled to that token.
		return trailText != null && sc.ctx.trivia && sc.isTriviaBearing(typePath)
			&& ((child.kind == Ref && !isStar) || (isStar && child.fmtHasFlag('captureTrailComment')));
	}

	/**
	 * ω-before-trail: whether this field grows a `<field>BeforeTrail:Null<String>`
	 * slot — a MANDATORY Ref carrying `@:trail`, in a trivia-bearing rule. Holds a
	 * BLOCK comment sitting between the field's last token and the trail literal
	 * (`switch (subject /* c *\/)`), which had no slot at all and was therefore
	 * dropped by the writer, refusing the whole round trip.
	 *
	 * The optional-Ref path is excluded: it emits its trail from a different writer
	 * seat, so the slot would have no reader. Mirrors `TriviaTypeSynth.isBeforeTrailRef`.
	 */
	private static function hasBeforeTrailSlotField(
		sc: StructSeqCtx, child: ShapeNode, typePath: String, isStar: Bool, isOptional: Bool, trailText: Null<String>
	): Bool {
		return trailText != null && !isStar && !isOptional && child.kind == Ref && sc.ctx.trivia && sc.isTriviaBearing(typePath);
	}

	/**
	 * Compute the two bare-trivia-Ref/Star BeforeNewline / BeforeLeading slot
	 * flags for a struct field. `hasBeforeNewlineSlot` captures the source
	 * newline in the gap before the field's first token (bare non-first Ref, or
	 * an opted-in first Ref/Star); `hasBeforeLeadingSlot` additionally captures
	 * the verbatim leading-comment run on the bare-Ref host. Pure — split out of
	 * `computeStructFieldFlags`.
	 */
	private static function computeBeforeSlots(
		sc: StructSeqCtx, child: ShapeNode, node: ShapeNode, typePath: String, isStar: Bool, isOptional: Bool, kwLead: Null<String>,
		leadText: Null<String>
	): { hasBeforeNewlineSlot: Bool, hasBeforeLeadingSlot: Bool } {
		// ω-orphan-prefix-member: an `@:optional @:absentOn` Ref owns its own
		// pre-field ws handling and normally grows no before-slots. The
		// `@:fmt(bareRefSepWhenPresent)` opt-in puts it back on the bare-Ref
		// footing for the PRESENT case: it needs the same source-newline and
		// gap-comment signals the mandatory field had, or the writer cannot
		// reproduce the gap between the preceding Star and the field's first
		// token. Mirrored by `TriviaTypeSynth.isBareNonFirstRef`.
		final bareTriviaNoLead: Bool = kwLead == null && leadText == null && sc.ctx.trivia && sc.isTriviaBearing(typePath);
		final bareRef: Bool = child.kind == Ref && bareTriviaNoLead && (!isOptional || child.fmtHasFlag('bareRefSepWhenPresent'));
		final bareStar: Bool = isStar && !isOptional && bareTriviaNoLead;
		final firstFieldOptIn: Bool = child == node.children[0] && child.fmtHasFlag('beforeNewlineSlotFirst');
		final refSlot: Bool = bareRef && (child != node.children[0] || firstFieldOptIn);
		return { hasBeforeNewlineSlot: refSlot || (bareStar && firstFieldOptIn), hasBeforeLeadingSlot: refSlot };
	}

	/**
	 * Emit the lead/kw peek-commit value for an `@:optional` Ref field (the
	 * `else` of the absentOn split): peek the lead literal or keyword; on hit,
	 * apply the post-commit trivia handling (kw-trivia capture / ω₆b stash /
	 * plain skipWs) and parse the sub-rule; on miss, rewind pos so the skipped
	 * trivia stays visible to the enclosing @:trivia Star. Pushes the
	 * `_f_<field>` EVars. Pure — split out of emitOptionalRefField.
	 */
	private static function emitOptionalRefLeadCommit(
		sc: StructSeqCtx, parseSteps: Array<Expr>, localName: String, fieldCT: ComplexType, subCall: Expr, kwLead: Null<String>,
		leadText: Null<String>, hasKwTriviaSlots: Bool, afterKwLocal: String, kwLeadingLocal: String, beforeKwNlLocal: String,
		bodyOnSameLineLocal: String, beforeKwLeadingLocal: String, beforeKwTrailingLocal: String
	): Void {
		// The commit point peeks the lead literal or keyword —
		// on hit, consume and parse the sub-rule; on miss,
		// rewind pos to before the pre-commit ws scan so any
		// trivia we just skipped becomes visible again to the
		// enclosing @:trivia Star's next `collectTrivia`. No
		// backtracking over the sub-rule body (D24). Keywords
		// use matchKw for word-boundary enforcement (D47).
		final commitCheck: Expr = if (kwLead != null)
			macro matchKw(ctx, $v{kwLead})
		else
			macro matchLit(ctx, $v{leadText});
		// Post-commit trivia handling branches three ways:
		//  - Trivia mode + kw: capture same-line trailing into
		//    `_afterKw_<field>`, route own-line leadings into
		//    `_kwLeading_<field>` (ω-issue-316). Additionally
		//    capture source-shape booleans into
		//    `_beforeKwNl_<field>` (pre-kw ws crossed a newline)
		//    and `_bodyOnSameLine_<field>` (post-kw gap stayed
		//    on the same line) for the writer's `Keep` branches
		//    (ω-keep-policy).
		//  - Trivia mode + lead: ω₆b stash — any captured leading
		//    run flows into `pendingTrivia` for the sub-rule's
		//    first @:trivia Star to drain.
		//  - Plain mode: plain ws skip.
		final innerCommitAction: Expr = if (hasKwTriviaSlots)
			macro {
				final _kwEndPos: Int = ctx.pos;
				$i{afterKwLocal} = collectTrailing(ctx);
				final _t = collectTrivia(ctx);
				for (_c in _t.leadingComments) $i{kwLeadingLocal}.push(_c);
				$i{bodyOnSameLineLocal} = !hasNewlineIn(ctx.input, _kwEndPos, ctx.pos);
			}
		else if (sc.ctx.trivia)
			macro {
				final _t = collectTrivia(ctx);
				// Stash whenever the captured run carries any signal the
				// downstream `collectTrivia` would otherwise lose:
				// comments, blank lines, OR a single newline boundary
				// (the `newlineBefore` channel — sub-rule's first
				// `@:trivia` Star element consumes it via `_t.newlineBefore` — EXCEPT
				// when that Star carries a `@:lead`, whose open literal clears the
				// newline again, a gap before `[` never being the first element's own;
				// see `stashNewlineClearExpr`).
				if (_t.leadingComments.length > 0 || _t.blankBefore || _t.blankAfterLeadingComments || _t.newlineBefore)
					ctx.pendingTrivia = _t;
			}
		else
			macro skipWs(ctx);
		final preCommitCapture: Expr = if (hasKwTriviaSlots)
			macro $i{beforeKwNlLocal} = hasNewlineIn(ctx.input, _prevEnd, _kwStartPos);
		else
			macro {};
		// ω-trivia-before-kw: in trivia mode + kw-bearing optional Ref,
		// the pre-commit ws scan must `collectTrivia` instead of
		// `skipWs` — otherwise own-line comments captured between the
		// preceding token and the kw (e.g. `} // comment\nelse`) are
		// silently discarded. On commit-success the captured leading
		// comments flow into `_beforeKwLeading_<field>` for the
		// writer to emit on its own line before the kw. On commit-
		// miss the rewind (`ctx.pos = _wsPos`) drops the captured
		// trivia so the enclosing Star's next `collectTrivia` re-
		// observes it.
		final valueExpr: Expr = if (hasKwTriviaSlots)
			macro {
				final _wsPos: Int = ctx.pos;
				// ω-prev-content-end: scan back past trailing whitespace consumed
				// by the preceding field's parser (notably HxExpr→Pratt, whose tail
				// loop's `skipWsAndStash` swallows `\n` before bailing on no-op
				// match — see Pratt loop tail rewind logic). Without scan-back,
				// `BeforeKwNewline = hasNewlineIn(_wsPos, _kwStartPos)` was always
				// false for `HxExpr→@:optional @:kw` siblings (HxIfExpr.elseBranch
				// most notably). `_prevEnd` walks back over [' ', '\t', '\n', '\r']
				// without touching `ctx.pos`, so `@:raw` next-siblings (e.g. `${expr}`
				// trailing `}` in HxStringSegment.Block) are unaffected.
				var _prevEnd: Int = _wsPos;
				while (_prevEnd > 0) {
					final _wsCh: Int = ctx.input.charCodeAt(_prevEnd - 1);
					if (_wsCh == ' '.code || _wsCh == '\t'.code || _wsCh == '\n'.code || _wsCh == '\r'.code)
						_prevEnd--;
					else
						break;
				}
				// ω-trivia-before-kw-trailing: probe for a single same-line
				// `// comment` after the preceding sibling's last token
				// (e.g. `resize(); // first\nelse`). `collectTrailing`
				// consumes pos to end of comment on hit, rewinds otherwise.
				// On commit-success the captured body lands in
				// `_beforeKwTrailing_<field>` for the writer to cuddle to
				// the prior token. On commit-miss the outer `ctx.pos =
				// _wsPos` rewind drops the capture so the enclosing Star's
				// next `collectTrivia` re-observes it.
				final _trailComment: Null<String> = collectTrailing(ctx);
				final _preTrivia = collectTrivia(ctx);
				final _kwStartPos: Int = ctx.pos;
				if ($commitCheck) {
					$i{beforeKwTrailingLocal} = _trailComment;
					for (_c in _preTrivia.leadingComments) $i{beforeKwLeadingLocal}.push(_c);
					$preCommitCapture;
					$innerCommitAction;
					$subCall;
				} else {
					ctx.pos = _wsPos;
					null;
				}
			}
		else
			macro {
				final _wsPos: Int = ctx.pos;
				skipWs(ctx);
				final _kwStartPos: Int = ctx.pos;
				if ($commitCheck) {
					$preCommitCapture;
					$innerCommitAction;
					$subCall;
				} else {
					ctx.pos = _wsPos;
					null;
				}
			};
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: fieldCT,
					expr: valueExpr,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

}

/**
 * The build state `StructSeqLowering` reads, bundled once in `Lowering`'s
 * constructor. The first four fields are the owner's own state (the
 * `starGates` array is the SAME instance - `emitStarFieldSteps` appends
 * to it as a side effect); the last six are the naming and predicate
 * vocabulary that stayed in `Lowering` because it is reached from every
 * shape, bound here as closures rather than duplicated.
 */
typedef StructSeqCtx = {
	final ctx: LoweringCtx;
	final shape: ShapeBuilder.ShapeResult;
	final formatInfo: FormatReader.FormatInfo;
	final starGates: Array<{
		rule: Null<String>,
		field: Null<String>,
		elem: String,
		first: BranchFirstToken,
	}>;
	final buildBlockEndedPredicateCall: (predicateName:String, accumRef:Expr) -> Expr;
	final isSpanBearing: (refName:String) -> Bool;
	final isTriviaBearing: (refName:String) -> Bool;
	final parseFnName: (refName:String) -> String;
	final ruleReturnCT: (refName:String) -> ComplexType;
	final stashNewlineClearExpr: () -> Expr;
}
#end
