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
 * Re strategy — owns regex-matched terminals.
 *
 * Reads `@:re("pattern")` on `Terminal` shape nodes (typically
 * abstracts over a primitive type such as `JStringLit`/`JNumberLit`)
 * and stores the pattern under the `re.pattern` annotation slot.
 *
 * Lowering emits `CoreIR.Re(pattern)` for these nodes and Codegen
 * consults the fixed decoder table (keyed on `base.underlying`) to
 * transform the matched slice into the abstract's underlying value:
 *
 *   - `Float`  → `Std.parseFloat(matched)`
 *   - `String` → JSON-aware unescape via `JsonFormat.instance.unescapeChar`
 *
 * The decoder table is intentionally a short closed set in Phase 2;
 * Phase 3+ will generalise once a third case demonstrates the need.
 */
class Re implements Strategy {

	public var name(default, null):String = 'Re';
	public var runsAfter(default, null):Array<String> = [];
	public var runsBefore(default, null):Array<String> = [];
	public var ownedMeta(default, null):Array<String> = [':re', ':captureGroup'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':re') return true;
		return false;
	}

	public function annotate(node:ShapeNode, ctx:LoweringCtx):Void {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':re') {
			if (entry.params.length != 1) {
				Context.fatalError('@:re expects exactly one string argument', entry.pos);
			}
			final pattern:String = switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _:
					Context.fatalError('@:re argument must be a string literal', entry.params[0].pos);
					throw 'unreachable';
			};
			node.annotations.set('re.pattern', pattern);
		}
		for (entry in meta) if (entry.name == ':captureGroup') {
			if (entry.params.length != 1) {
				Context.fatalError('@:captureGroup expects exactly one integer argument', entry.pos);
			}
			final group:Int = switch entry.params[0].expr {
				case EConst(CInt(s, _)): Std.parseInt(s);
				case _:
					Context.fatalError('@:captureGroup argument must be an integer literal', entry.params[0].pos);
					throw 'unreachable';
			};
			if (group < 1) {
				Context.fatalError('@:captureGroup must be >= 1 (group 0 is the default whole match)', entry.pos);
			}
			node.annotations.set('re.captureGroup', group);
		}
	}

	public function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR> {
		return null;
	}
}
#end
