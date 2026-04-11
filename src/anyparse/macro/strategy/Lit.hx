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
 *  - `@:wrap("o","c")`              — shorthand for `@:lead`+`@:trail`.
 *  - `@:sep(",")`                   — separator between elements of a
 *                                     `Star` child of this node.
 *
 * Pass 2 (annotate) writes results under the `lit.*` namespace on the
 * shape node; Lowering and Codegen read them back in pass 3/4.
 */
class Lit implements Strategy {

	public var name(default, null):String = 'Lit';
	public var runsAfter(default, null):Array<String> = [];
	public var runsBefore(default, null):Array<String> = [];
	public var ownedMeta(default, null):Array<String> = [':lit', ':lead', ':trail', ':wrap', ':sep'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) switch entry.name {
			case ':lit' | ':lead' | ':trail' | ':wrap' | ':sep': return true;
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
			case ':wrap':
				if (entry.params.length != 2) {
					Context.fatalError('@:wrap expects exactly two string arguments', entry.pos);
				}
				node.annotations.set('lit.leadText', stringOrFail(entry.params[0], ':wrap'));
				node.annotations.set('lit.trailText', stringOrFail(entry.params[1], ':wrap'));
			case ':sep':
				node.annotations.set('lit.sepText', singleString(entry.params, ':sep'));
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
