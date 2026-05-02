package anyparse.macro;

#if macro
import haxe.macro.Expr.Metadata;
import anyparse.core.ShapeTree.ShapeNode;

/**
 * Macro-time helpers that read metadata stashed under
 * `node.annotations.get('base.meta')`. Designed for `using` import:
 *
 * ```haxe
 * using anyparse.macro.MetaInspect;
 * ...
 * if (child.hasMeta(':tryparse') && child.fmtHasFlag('nestBody')) ...
 * final lead:Null<String> = child.readMetaString(':lead');
 * ```
 *
 * Two metadata namespaces are supported:
 *
 * - **Top-level metas** (`@:lead('...')`, `@:trail('...')`, `@:tryparse`,
 *   `@:raw`, ...) — `hasMeta` and `readMetaString` look up by entry name.
 * - **`@:fmt(...)` umbrella** — multiple writer-side flags share one entry;
 *   `fmtHasFlag` / `fmtReadString` / `fmtReadStringArgs` /
 *   `fmtReadStringArgsAll` walk the entry's params and match by callee name.
 */
final class MetaInspect {

	/**
	 * True when the node carries the named metadata entry. The entry's
	 * params are not inspected — presence alone is the signal.
	 */
	public static function hasMeta(node:ShapeNode, tag:String):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == tag) return true;
		return false;
	}

	/**
	 * Reads the single string literal argument of the named metadata
	 * entry. Returns null when the entry is absent, has no params, has
	 * more than one param, or its single param is not a string literal.
	 */
	public static function readMetaString(node:ShapeNode, tag:String):Null<String> {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return null;
		for (entry in meta) if (entry.name == tag) {
			if (entry.params.length != 1) return null;
			return switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _: null;
			};
		}
		return null;
	}

	/**
	 * True when the node carries `@:fmt(...)` and any argument matches
	 * `name` either as a bare identifier (flag form, `@:fmt(nestBody)`)
	 * or as the callee of an `ECall` (knob form, `@:fmt(bodyPolicy('x'))`).
	 * Either form counts as flag presence.
	 */
	public static function fmtHasFlag(node:ShapeNode, name:String):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case EConst(CIdent(id)) if (id == name): return true;
				case ECall({expr: EConst(CIdent(id))}, _) if (id == name): return true;
				case _:
			}
		}
		return false;
	}

	/**
	 * Looks for a knob-form argument `name('value')` inside any
	 * `@:fmt(...)` entry on the node and returns the string literal
	 * value. Returns null when no matching entry is present or when
	 * the argument shape is not a single string literal.
	 */
	public static function fmtReadString(node:ShapeNode, name:String):Null<String> {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case ECall({expr: EConst(CIdent(id))}, [{expr: EConst(CString(s, _))}]) if (id == name):
					return s;
				case _:
			}
		}
		return null;
	}

	/**
	 * Generalisation of `fmtReadString` for knob-form args with multiple
	 * string literals — `name('a', 'b', 'c')`. Returns the list of string
	 * values in source order. Returns null when the entry is absent or
	 * any arg is not a string literal.
	 */
	public static function fmtReadStringArgs(node:ShapeNode, name:String):Null<Array<String>> {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case ECall({expr: EConst(CIdent(id))}, args) if (id == name):
					final out:Array<String> = [];
					for (arg in args) switch arg.expr {
						case EConst(CString(s, _)): out.push(s);
						case _: return null;
					}
					return out;
				case _:
			}
		}
		return null;
	}

	/**
	 * Multi-entry variant of `fmtReadStringArgs` — returns every
	 * `@:fmt(name(...))` occurrence on the node, in source order. Used
	 * by knobs that may appear multiple times with different argument
	 * tuples. Entries with non-string args are skipped silently — same
	 * lenient policy as the single-entry helper.
	 */
	public static function fmtReadStringArgsAll(node:ShapeNode, name:String):Array<Array<String>> {
		final out:Array<Array<String>> = [];
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return out;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case ECall({expr: EConst(CIdent(id))}, args) if (id == name):
					final group:Array<String> = [];
					var ok:Bool = true;
					for (arg in args) switch arg.expr {
						case EConst(CString(s, _)): group.push(s);
						case _: ok = false;
					}
					if (ok) out.push(group);
				case _:
			}
		}
		return out;
	}
}
#end
