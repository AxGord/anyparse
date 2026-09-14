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

using Lambda;

/**
 * Re strategy — owns regex-matched terminals.
 *
 * Reads `@:re("pattern")` on `Terminal` shape nodes (typically abstracts over a
 * primitive type such as `JStringLit` / `JNumberLit`) and stores the pattern under
 * the `re.pattern` slot; `@:captureGroup(n)` (exactly one integer literal, `n >= 1`
 * — group 0 is the whole match and the default) selects the group whose text
 * becomes the value, under `re.captureGroup`; the position still advances by the
 * whole match. Both slots are read by `TerminalParseLowering`, which emits the
 * anchored `EReg` match and decodes the slice by the abstract's underlying type —
 * `Float` / `Int` / `Bool` directly, a `String` only through `@:unescape` (the
 * `@:schema` format's `unescapeChar`), `@:decode("pkg.Class.method")` or
 * `@:rawString`, which that module reads itself.
 */
class Re implements Strategy {

	public var name(default, null): String = 'Re';
	public var runsAfter(default, null): Array<String> = [];
	public var runsBefore(default, null): Array<String> = [];
	public var ownedMeta(default, null): Array<String> = [':re', ':captureGroup'];
	public var runtimeContribution(default, null): RuntimeContrib = { ctxFields: [], helpers: [], cacheKeyContributors: [] };

	public function new() {}

	public function appliesTo(node: ShapeNode): Bool {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		return meta != null && meta.exists(entry -> entry.name == ':re');
	}

	public function annotate(node: ShapeNode, ctx: LoweringCtx): Void {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return;
		for (entry in meta) if (entry.name == ':re') {
			if (entry.params.length != 1) {
				Context.fatalError('@:re expects exactly one string argument', entry.pos);
			}
			final pattern: String = switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _:
					Context.fatalError('@:re argument must be a string literal', entry.params[0].pos);
					throw 'unreachable';
			};
			node.annotations['re.pattern'] = pattern;
		}
		for (entry in meta) if (entry.name == ':captureGroup') {
			if (entry.params.length != 1) {
				Context.fatalError('@:captureGroup expects exactly one integer argument', entry.pos);
			}
			final group: Int = switch entry.params[0].expr {
				case EConst(CInt(s, _)): Std.parseInt(s);
				case _:
					Context.fatalError('@:captureGroup argument must be an integer literal', entry.params[0].pos);
					throw 'unreachable';
			};
			if (group < 1) {
				Context.fatalError('@:captureGroup must be >= 1 (group 0 is the default whole match)', entry.pos);
			}
			node.annotations['re.captureGroup'] = group;
		}
	}

	public function lower(node: ShapeNode, ctx: LoweringCtx): Null<CoreIR> {
		return null;
	}

}
#end
