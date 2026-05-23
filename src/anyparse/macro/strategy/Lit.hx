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

	public var name(default, null):String = 'Lit';
	public var runsAfter(default, null):Array<String> = [];
	public var runsBefore(default, null):Array<String> = [];
	public var ownedMeta(default, null):Array<String> = [':lit', ':lead', ':trail', ':trailOpt', ':wrap', ':sep', ':sepAlt'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) switch entry.name {
			case ':lit' | ':lead' | ':trail' | ':trailOpt' | ':wrap' | ':sep' | ':sepAlt': return true;
			case _:
		}
		return false;
	}

	public function annotate(node:ShapeNode, ctx:LoweringCtx):Void {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) switch entry.name {
			case ':lit':
				final list:Array<String> = collectStrings(entry.params);
				node.annotations.set('lit.litList', list);
			case ':lead':
				node.annotations.set('lit.leadText', singleString(entry.params, ':lead'));
			case ':trail':
				node.annotations.set('lit.trailText', singleString(entry.params, ':trail'));
			case ':trailOpt':
				node.annotations.set('lit.trailText', singleString(entry.params, ':trailOpt'));
				node.annotations.set('lit.trailOptional', true);
			case ':wrap':
				if (entry.params.length != 2) {
					Context.fatalError('@:wrap expects exactly two string arguments', entry.pos);
				}
				node.annotations.set('lit.leadText', stringOrFail(entry.params[0], ':wrap'));
				node.annotations.set('lit.trailText', stringOrFail(entry.params[1], ':wrap'));
			case ':sep':
				if (entry.params.length == 0 || entry.params.length > 2)
					Context.fatalError('@:sep expects 1 or 2 arguments: @:sep("text") or @:sep("text", tailRelax)', entry.pos);
				node.annotations.set('lit.sepText', stringOrFail(entry.params[0], ':sep'));
				if (entry.params.length == 2) switch entry.params[1].expr {
					case EConst(CIdent('tailRelax')):
						node.annotations.set('lit.sepTailRelax', true);
					case _:
						Context.fatalError('@:sep second argument must be the ident `tailRelax`', entry.params[1].pos);
				}
			case ':sepAlt':
				node.annotations.set('lit.sepAltText', singleString(entry.params, ':sepAlt'));
			case _:
		}
	}

	public function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR> {
		// Phase 2 keeps tree construction centralized in Lowering; strategies
		// only annotate. Returning null defers to base structural lowering.
		return null;
	}

	// -------- helpers --------

	private static function collectStrings(params:Array<Expr>):Array<String> {
		return [for (p in params) stringOrFail(p, ':lit')];
	}

	private static function singleString(params:Array<Expr>, tag:String):String {
		if (params.length != 1) Context.fatalError('$tag expects exactly one string argument', Context.currentPos());
		return stringOrFail(params[0], tag);
	}

	private static function stringOrFail(e:Expr, tag:String):String {
		return switch e.expr {
			case EConst(CString(s, _)): s;
			case _:
				Context.fatalError('$tag argument must be a string literal', e.pos);
				throw 'unreachable';
		};
	}
}
#end
