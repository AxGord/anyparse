package anyparse.macro.strategy;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.core.CoreIR;
import anyparse.core.LoweringCtx;
import anyparse.core.RuntimeContrib;
import anyparse.core.ShapeTree;
import anyparse.core.Strategy;

/**
 * Lit strategy — owns literal text glue.
 *
 * Metadata handled:
 *  - `@:lit("text")`                — whole node matches a literal. If
 *                                     the meta carries multiple args
 *                                     (`@:lit("true","false")`) the
 *                                     node matches any of them and
 *                                     Lowering chooses a branch per
 *                                     the sidecar build-spec.
 *  - `@:lead("open")`               — emit `Lit("open")` before the
 *                                     node's inner match.
 *  - `@:trail("close")`             — emit `Lit("close")` after.
 *  - `@:trailOpt("close")`          — like `@:trail` but the close
 *                                     literal is optional on parse:
 *                                     parser emits `matchLit` (peek +
 *                                     consume-if-present) instead of
 *                                     `expectLit`. The writer keeps
 *                                     emitting the literal as canonical
 *                                     output. Source-fidelity (preserve
 *                                     presence) is a separate slice.
 *                                     Sets `lit.trailText` and
 *                                     `lit.trailOptional:true`.
 *  - `@:wrap("o","c")`              — shorthand for `@:lead`+`@:trail`.
 *  - `@:sep(",")`                   — separator between elements of a
 *                                     `Star` child of this node.
 *  - `@:sep(",", tailRelax)`        — opt-in: make the intent explicit
 *                                     that a sep immediately before the
 *                                     close terminator is accepted as
 *                                     tail (no required following
 *                                     element). Mirrors the current
 *                                     implicit close-peek behaviour
 *                                     (`Lowering.hx:emitStarFieldSteps`
 *                                     L1 — "tolerate trailing sep
 *                                     before close") and earmarks
 *                                     consumers for the BlockBody
 *                                     refactor. Sets
 *                                     `lit.sepTailRelax:true`.
 *  - `@:sep(";", tailRelax, blockEnded)` — opt-in: between two elements,
 *                                     sep may be omitted when the prior
 *                                     element ended with `}` or `;`
 *                                     (parser-side byte-level check on
 *                                     `_prevEndPos - 1`); writer-side uses
 *                                     `DocMeasure.endsWithCloseBrace` on
 *                                     each element's rendered Doc.
 *                                     `blockEnded` must come AFTER
 *                                     `tailRelax` — `@:sep(";",
 *                                     blockEnded)` is rejected at compile
 *                                     time (second arg must match
 *                                     `tailRelax` ident). Sets
 *                                     `lit.sepBlockEnded:true`.
 *  - `@:sep(";", tailRelax, blockEnded('<predicate>'))` — option b2 form
 *                                     (Session 6): in addition to the
 *                                     byte-check `}` / `;`, the Star
 *                                     primitive calls a schema-instance
 *                                     predicate
 *                                     (`schema.instance.<predicate>(_arr[_arr.length
 *                                     - 1])`) on the just-pushed element
 *                                     to decide sep-elision by AST shape.
 *                                     Required to cover ident-terminated
 *                                     stmts (`x is String` — Slice 43) and
 *                                     `]`-terminated stmts (`[1,2,3]` —
 *                                     Slice 39) which the byte-check can't
 *                                     cover safely. Reaches the predicate
 *                                     through the same channel as
 *                                     `trailOptParseGate` (see
 *                                     `Lowering.buildBlockEndedPredicateCall`).
 *                                     Sets both `lit.sepBlockEnded:true`
 *                                     and `lit.sepBlockEndedPredicate:<name>`.
 *  - `@:sepAlt(";")`               — opt-in alternate separator,
 *                                     accepted alongside `@:sep` by the
 *                                     tolerant close-driven loop (an
 *                                     optional `,` OR `;` between
 *                                     elements). Sets `lit.sepAltText`.
 *
 * Pass 2 (annotate) writes results under the `lit.*` namespace on the
 * shape node; Lowering and Codegen read them back in pass 3/4.
 */
class Lit implements Strategy {

	public var name(default, null): String = 'Lit';
	public var runsAfter(default, null): Array<String> = [];
	public var runsBefore(default, null): Array<String> = [];
	public var ownedMeta(default, null): Array<String> = [':lit', ':lead', ':trail', ':trailOpt', ':wrap', ':sep', ':sepAlt'];
	public var runtimeContribution(default, null): RuntimeContrib = { ctxFields: [], helpers: [], cacheKeyContributors: [] };

	public function new() {}

	public function appliesTo(node: ShapeNode): Bool {
		final meta: Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) switch entry.name {
			case ':lit' | ':lead' | ':trail' | ':trailOpt' | ':wrap' | ':sep' | ':sepAlt':
				return true;
			case _:
		}
		return false;
	}

	public function annotate(node: ShapeNode, ctx: LoweringCtx): Void {
		final meta: Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) switch entry.name {
			case ':lit':
				final list: Array<String> = collectStrings(entry.params);
				node.annotations.set('lit.litList', list);
			case ':lead':
				node.annotations.set('lit.leadText', singleString(entry.params, ':lead'));
			case ':trail':
				node.annotations.set('lit.trailText', singleString(entry.params, ':trail'));
			case ':trailOpt':
				node.annotations.set('lit.trailText', singleString(entry.params, ':trailOpt'));
				node.annotations.set('lit.trailOptional', true);
			case ':wrap':
				annotateWrap(node, entry);
			case ':sep':
				annotateSep(node, entry);
			case ':sepAlt':
				node.annotations.set('lit.sepAltText', singleString(entry.params, ':sepAlt'));
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
		node.annotations.set('lit.leadText', stringOrFail(entry.params[0], ':wrap'));
		node.annotations.set('lit.trailText', stringOrFail(entry.params[1], ':wrap'));
	}

	private static function annotateSep(node: ShapeNode, entry: MetadataEntry): Void {
		if (entry.params.length == 0 || entry.params.length > 3)
			Context.fatalError(
				'@:sep expects 1-3 arguments: @:sep("text"), @:sep("text", tailRelax | sepFaithful), or @:sep("text", tailRelax, blockEnded[(\'<predicate>\'[, sepStartsElement])])',
				entry.pos
			);
		node.annotations.set('lit.sepText', stringOrFail(entry.params[0], ':sep'));
		if (entry.params.length >= 2) switch entry.params[1].expr {
			case EConst(CIdent('tailRelax')):
				node.annotations.set('lit.sepTailRelax', true);
			// `sepFaithful` (ω-sep-faithful): source-fidelity sep mode for
			// comma-lists inside preprocessor-guarded element groups
			// (`HxConditionalArgs.body` and kin). Parse side reuses the
			// permissive trivia tryparse loop (per-element `sepAfter`
			// capture); writer side re-emits the sep iff the element's
			// captured `sepAfter` is true — no `}`/`;` byte-check, no
			// per-construct knob. Mutually exclusive with `blockEnded`
			// (2-arg form only).
			case EConst(CIdent('sepFaithful')):
				node.annotations.set('lit.sepFaithful', true);
			case _:
				Context.fatalError('@:sep second argument must be the ident `tailRelax` or `sepFaithful`', entry.params[1].pos);
		}
		if (entry.params.length == 3 && node.annotations.get('lit.sepFaithful') == true)
			Context.fatalError('@:sep `sepFaithful` does not combine with a third argument', entry.params[2].pos);
		if (entry.params.length == 3) switch entry.params[2].expr {
			case EConst(CIdent('blockEnded')):
				node.annotations.set('lit.sepBlockEnded', true);
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
				node.annotations.set('lit.sepBlockEnded', true);
				node.annotations.set('lit.sepBlockEndedPredicate', stringOrFail(callArgs[0], ':sep'));
				// Optional 2nd arg `sepStartsElement` (Session 9 BlockBody Star) —
				// flips byte-ambiguity policy: when block-ended is TRUE, the sep
				// byte at pos belongs to the NEXT element, never a separator.
				// Required for grammars where the sep char can ALSO be a valid
				// element body (Haxe `EmptyStmt` whose body IS `;`). Without this
				// flag the default permissive-sep semantics applies.
				if (callArgs.length == 2)
					switch callArgs[1].expr {
						case EConst(CIdent('sepStartsElement')):
							node.annotations.set('lit.sepStartsElement', true);
						case _:
							Context.fatalError(
								'@:sep `blockEnded(...)` second argument must be the ident `sepStartsElement`', callArgs[1].pos
							);
					}
			case _:
				Context.fatalError(
					'@:sep third argument must be `blockEnded` or `blockEnded(\'<predicate>\'[, sepStartsElement])`', entry.params[2].pos
				);
		}
	}

}
#end
