package anyparse.macro.strategy;

#if macro
import anyparse.core.CoreIR;
import anyparse.core.LoweringCtx;
import anyparse.core.RuntimeContrib;
import anyparse.core.ShapeTree;
import anyparse.core.Strategy;
import anyparse.macro.AnnotationKeys;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Lit strategy — owns literal text glue. Annotate-only: each tag below sets `lit.*` slots on the
 * shape node (`AnnotationKeys`), and `Lowering` / `WriterLowering` read them in passes 3/4.
 *
 * - `@:lit("text")` — the whole node matches a literal; several args (`@:lit("true", "false")`)
 *   match any of them and the lowering picks a branch per the sidecar build-spec.
 * - `@:lead("open")` / `@:trail("close")` — emit the literal before / after the node's inner
 *   match; `@:wrap("o", "c")` is both.
 * - `@:trailOpt("close")` — like `@:trail`, but optional on parse (`matchLit` instead of
 *   `expectLit`); the writer re-emits it canonically, source presence tracked in the
 *   `<field>TrailPresent` synth slot. Sets `lit.trailText` and `lit.trailOptional`.
 * - `@:sep(",")` — separator between the elements of a `Star` child of this node.
 * - `@:sep(",", tailRelax)` — a separator right before the close terminator is accepted as a
 *   tail (the close-peek loop already tolerates it; the ident makes the contract explicit).
 *   Sets `lit.sepTailRelax`.
 * - `@:sep(",", sepFaithful)` — source-fidelity separator mode: the parse captures a
 *   per-element `sepAfter` and the writer re-emits the separator iff it was there — no byte
 *   check, no knob. Excludes a third argument. Sets `lit.sepFaithful`.
 * - `@:sep(";", tailRelax, blockEnded)` — between two elements the separator may be omitted
 *   when the prior element ended with `}` or `;` (a byte check on `_prevEndPos - 1`; the
 *   writer's twin is `DocMeasure.endsWithCloseBrace`). Must follow `tailRelax`. Sets
 *   `lit.sepBlockEnded`.
 * - `@:sep(";", tailRelax, blockEnded('<predicate>'[, sepStartsElement]))` — additionally asks
 *   the named predicate on the just-pushed element to decide elision by AST shape (a generated
 *   `AstPreds` function for a format declaring `astPreds`, else a schema-instance method —
 *   `Lowering.buildBlockEndedPredicateCall`); `sepStartsElement` says a separator byte after a
 *   block-ended element begins the NEXT element, for a grammar whose separator can also be an
 *   element (`EmptyStmt`). Sets `lit.sepBlockEndedPredicate` and `lit.sepStartsElement`.
 * - `@:sepAlt(";")` — an alternate separator accepted alongside `@:sep` by the tolerant
 *   close-driven loop. Sets `lit.sepAltText`.
 *
 * Every argument-shape refusal is a `fatalError` in the `annotate*` helpers below.
 */
class Lit implements Strategy {

	public var name(default, null): String = 'Lit';
	public var runsAfter(default, null): Array<String> = [];
	public var runsBefore(default, null): Array<String> = [];
	public var ownedMeta(default, null): Array<String> = [':lit', ':lead', ':trail', ':trailOpt', ':wrap', ':sep', ':sepAlt'];
	public var runtimeContribution(default, null): RuntimeContrib = { ctxFields: [], helpers: [], cacheKeyContributors: [] };

	public function new() {}

	public function appliesTo(node: ShapeNode): Bool {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return false;
		for (entry in meta) switch entry.name {
			case ':lit', ':lead', ':trail', ':trailOpt', ':wrap', ':sep', ':sepAlt':
				return true;
			case _:
		}
		return false;
	}

	public function annotate(node: ShapeNode, ctx: LoweringCtx): Void {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return;
		for (entry in meta) switch entry.name {
			case ':lit':
				final list: Array<String> = collectStrings(entry.params);
				node.annotations[AnnotationKeys.LIT_LIT_LIST] = list;
			case ':lead':
				node.annotations[AnnotationKeys.LIT_LEAD_TEXT] = singleString(entry.params, ':lead');
			case ':trail':
				node.annotations[AnnotationKeys.LIT_TRAIL_TEXT] = singleString(entry.params, ':trail');
			case ':trailOpt':
				node.annotations[AnnotationKeys.LIT_TRAIL_TEXT] = singleString(entry.params, ':trailOpt');
				node.annotations[AnnotationKeys.LIT_TRAIL_OPTIONAL] = true;
			case ':wrap':
				annotateWrap(node, entry);
			case ':sep':
				annotateSep(node, entry);
			case ':sepAlt':
				node.annotations[AnnotationKeys.LIT_SEP_ALT_TEXT] = singleString(entry.params, ':sepAlt');
			case _:
		}
	}

	public function lower(node: ShapeNode, ctx: LoweringCtx): Null<CoreIR> {
		// Phase 2 keeps tree construction centralized in Lowering; strategies
		// only annotate. Returning null defers to base structural lowering.
		return null;
	}

	// -------- helpers --------

	private static function collectStrings(params: Array<Expr>): Array<String> {
		return [for (p in params) stringOrFail(p, ':lit')];
	}

	private static function singleString(params: Array<Expr>, tag: String): String {
		if (params.length != 1) Context.fatalError('$tag expects exactly one string argument', Context.currentPos());
		return stringOrFail(params[0], tag);
	}

	private static function stringOrFail(e: Expr, tag: String): String {
		return switch e.expr {
			case EConst(CString(s, _)): s;
			case _:
				Context.fatalError('$tag argument must be a string literal', e.pos);
				throw 'unreachable';
		};
	}

	private static function annotateWrap(node: ShapeNode, entry: MetadataEntry): Void {
		if (entry.params.length != 2) {
			Context.fatalError('@:wrap expects exactly two string arguments', entry.pos);
		}
		node.annotations[AnnotationKeys.LIT_LEAD_TEXT] = stringOrFail(entry.params[0], ':wrap');
		node.annotations[AnnotationKeys.LIT_TRAIL_TEXT] = stringOrFail(entry.params[1], ':wrap');
	}

	private static function annotateSep(node: ShapeNode, entry: MetadataEntry): Void {
		if (entry.params.length == 0 || entry.params.length > 3)
			Context.fatalError(
				'@:sep expects 1-3 arguments: @:sep("text"), @:sep("text", tailRelax | sepFaithful), or @:sep("text", tailRelax, '
				+ 'blockEnded[(\'<predicate>\'[, sepStartsElement])])',
				entry.pos
			);
		node.annotations[AnnotationKeys.LIT_SEP_TEXT] = stringOrFail(entry.params[0], ':sep');
		if (entry.params.length >= 2) switch entry.params[1].expr {
			case EConst(CIdent('tailRelax')):
				node.annotations[AnnotationKeys.LIT_SEP_TAIL_RELAX] = true;
			// `sepFaithful` (ω-sep-faithful): source-fidelity sep mode for
			// comma-lists inside preprocessor-guarded element groups
			// (`HxConditionalArgs.body` and kin). Parse side reuses the
			// permissive trivia tryparse loop (per-element `sepAfter`
			// capture); writer side re-emits the sep iff the element's
			// captured `sepAfter` is true — no `}`/`;` byte-check, no
			// per-construct knob. Mutually exclusive with `blockEnded`
			// (2-arg form only).
			case EConst(CIdent('sepFaithful')):
				node.annotations['lit.sepFaithful'] = true;
			case _:
				Context.fatalError('@:sep second argument must be the ident `tailRelax` or `sepFaithful`', entry.params[1].pos);
		}
		if (entry.params.length == 3 && node.annotations['lit.sepFaithful'] == true)
			Context.fatalError('@:sep `sepFaithful` does not combine with a third argument', entry.params[2].pos);
		if (entry.params.length == 3) switch entry.params[2].expr {
			case EConst(CIdent('blockEnded')):
				node.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] = true;
			// `blockEnded('predicateName')` — option (b2) AST-shape
			// adapter: instead of (or in addition to) the byte-check
			// `_prevEndPos - 1 == '}'`, the Star primitive calls
			// `schema.instance.<predicateName>(_arr[_arr.length - 1])`
			// to decide whether sep is elidable. The predicate is a
			// schema-method on the plugin's HaxeFormat-shaped class,
			// reached through the same channel as `trailOptParseGate`
			// (see Lowering.hx L1552 for the sister mechanism).
			case ECall({ expr: EConst(CIdent('blockEnded')) }, callArgs):
				if (callArgs.length < 1 || callArgs.length > 2)
					Context.fatalError(
						'@:sep `blockEnded(...)` expects 1-2 arguments: predicate name [, sepStartsElement]', entry.params[2].pos
					);
				node.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] = true;
				node.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE] = stringOrFail(callArgs[0], ':sep');
				// Optional 2nd arg `sepStartsElement` (Session 9 BlockBody Star) —
				// flips byte-ambiguity policy: when block-ended is TRUE, the sep
				// byte at pos belongs to the NEXT element, never a separator.
				// Required for grammars where the sep char can ALSO be a valid
				// element body (Haxe `EmptyStmt` whose body IS `;`). Without this
				// flag the default permissive-sep semantics applies.
				if (callArgs.length == 2) switch callArgs[1].expr {
					case EConst(CIdent('sepStartsElement')):
						node.annotations[AnnotationKeys.LIT_SEP_STARTS_ELEMENT] = true;
					case _:
						Context.fatalError('@:sep `blockEnded(...)` second argument must be the ident `sepStartsElement`', callArgs[1].pos);
				}
			case _:
				Context.fatalError(
					'@:sep third argument must be `blockEnded` or `blockEnded(\'<predicate>\'[, sepStartsElement])`', entry.params[2].pos
				);
		}
	}

}
#end
