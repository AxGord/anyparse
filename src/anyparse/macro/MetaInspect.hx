package anyparse.macro;

#if macro
import anyparse.core.ShapeTree.ShapeNode;
import haxe.macro.Context;
import haxe.macro.Expr.Metadata;
import haxe.macro.Expr.MetadataEntry;
import haxe.macro.ExprTools;

using Lambda;

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
	public static function hasMeta(node: ShapeNode, tag: String): Bool {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		return meta != null && meta.exists(entry -> entry.name == tag);
	}

	/**
	 * Reads the single string literal argument of the named metadata
	 * entry. Returns null when the entry is absent, has no params, has
	 * more than one param, or its single param is not a string literal.
	 */
	public static function readMetaString(node: ShapeNode, tag: String): Null<String> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == tag) return entry.params.length != 1
			? null
			: switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _: null;
			};
		return null;
	}

	/**
	 * The key a by-name format spells the struct field `fieldName` with: the string of its `@:key('…')` entry, else the
	 * field's own name. A format key need not be a Haxe identifier — `"function"`, `"$schema"`, `"content-type"` — and the
	 * parser and the writer must agree on it, so both read it here.
	 */
	public static function wireKey(node: ShapeNode, fieldName: String): String {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		final entries: Array<MetadataEntry> = meta == null ? [] : meta.filter(e -> e.name == ':key');
		if (entries.length == 0) return fieldName;
		final key: Null<String> = entries.length == 1 && entries[0].params.length == 1
			? switch entries[0].params[0].expr {
				case EConst(CString(s, _)): s;
				case _: null;
			}
			: null;
		if (key == null)
			return Context.fatalError(
				'@:key on field "$fieldName" takes exactly one string: the key the format spells the field with', entries[0].pos
			);
		final unwritable: EReg = ~/["\\\x00-\x1f]/;
		if (unwritable.match(key))
			Context.fatalError(
				'@:key "$key" on field "$fieldName" holds a quote, a backslash or a control character, which a writer would emit unescaped',
				entries[0].pos
			);
		return key;
	}

	/**
	 * Whether the by-name field `child` holding null is written as the format's null literal under its key
	 * (`@:writeNull`) rather than left out. Only an `@:optional` field may say so: a reader takes the null literal for an
	 * absent key, so the field reads back as it was written.
	 */
	public static function writesNull(child: ShapeNode): Bool {
		if (!hasMeta(child, ':writeNull')) return false;
		if (child.annotations[AnnotationKeys.BASE_OPTIONAL] != true)
			Context.fatalError(
				'@:writeNull needs an @:optional field: a required one never holds null',
				child.annotations[AnnotationKeys.BASE_FIELD_POS] ?? Context.currentPos()
			);
		return true;
	}

	/**
	 * The one field of the by-name struct `node` written bare (`@:bare`): its value alone, with neither its key nor the
	 * struct's delimiters — how a document whose root is a sequence is written, since a schema roots on a struct. Null
	 * for a struct written whole; refuses `@:bare` on a struct of other than one required field.
	 */
	public static function bareField(node: ShapeNode): Null<ShapeNode> {
		if (!hasMeta(node, ':bare')) return null;
		if (node.children.length != 1 || node.children[0].annotations.get(AnnotationKeys.BASE_OPTIONAL) == true)
			Context.fatalError(
				'@:bare needs a struct of exactly one required field: its value is the whole document', Context.currentPos()
			);
		return node.children[0];
	}

	/** Refuses a by-name struct `node` two of whose fields a format would spell with one key (`wireKey`). */
	public static function checkWireKeys(node: ShapeNode): Void {
		final seen: Map<String, String> = [];
		for (child in node.children) {
			final fieldName: Null<String> = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			if (fieldName == null) continue;
			final key: String = wireKey(child, fieldName);
			final other: Null<String> = seen[key];
			if (other != null)
				Context.fatalError(
					'fields "$other" and "$fieldName" are both spelled "$key" in the document',
					child.annotations.get(AnnotationKeys.BASE_FIELD_POS) ?? Context.currentPos()
				);
			seen[key] = fieldName;
		}
	}

	/**
	 * Reads N string literal arguments of the named metadata entry, in
	 * source order. Returns null when the entry is absent, has zero
	 * params, or any param is not a string literal. Multi-arg sibling
	 * of `readMetaString` for tags like `@:absentOn('a', 'b', ')')`.
	 */
	public static function readMetaStringArgs(node: ShapeNode, tag: String): Null<Array<String>> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == tag) {
			if (entry.params.length == 0) return null;
			final out: Array<String> = [];
			for (p in entry.params) switch p.expr {
				case EConst(CString(s, _)):
					out.push(s);
				case _:
					return null;
			}
			return out;
		}
		return null;
	}

	/**
	 * True when the node carries `@:fmt(...)` and any argument matches
	 * `name` either as a bare identifier (flag form, `@:fmt(nestBody)`)
	 * or as the callee of an `ECall` (knob form, `@:fmt(bodyPolicy('x'))`).
	 * Either form counts as flag presence.
	 */
	public static function fmtHasFlag(node: ShapeNode, name: String): Bool {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':fmt') for (param in entry.params) switch param.expr {
			case EConst(CIdent(id)) if (id == name):
				return true;
			case ECall({ expr: EConst(CIdent(id)) }, _) if (id == name):
				return true;
			case _:
		}
		return false;
	}

	/**
	 * Looks for a knob-form argument `name('value')` inside any
	 * `@:fmt(...)` entry on the node and returns the string literal
	 * value. Returns null when no matching entry is present or when
	 * the argument shape is not a single string literal.
	 */
	public static function fmtReadString(node: ShapeNode, name: String): Null<String> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':fmt') for (param in entry.params) switch param.expr {
			case ECall({ expr: EConst(CIdent(id)) }, [{ expr: EConst(CString(s, _)) }]) if (id == name):
				return s;
			case _:
		}
		return null;
	}

	/**
	 * Generalisation of `fmtReadString` for knob-form args with multiple
	 * string literals — `name('a', 'b', 'c')`. Returns the list of string
	 * values in source order. Returns null when the entry is absent or
	 * any arg is not a string literal.
	 */
	public static function fmtReadStringArgs(node: ShapeNode, name: String): Null<Array<String>> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':fmt') for (param in entry.params) switch param.expr {
			case ECall({ expr: EConst(CIdent(id)) }, args) if (id == name):
				final out: Array<String> = [];
				for (arg in args) switch arg.expr {
					case EConst(CString(s, _)):
						out.push(s);
					case _:
						return null;
				}
				return out;
			case _:
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
	public static function fmtReadStringArgsAll(node: ShapeNode, name: String): Array<Array<String>> {
		final out: Array<Array<String>> = [];
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return out;
		for (entry in meta) if (entry.name == ':fmt') for (param in entry.params) switch param.expr {
			case ECall({ expr: EConst(CIdent(id)) }, args) if (id == name):
				final group: Array<String> = [];
				var ok: Bool = true;
				for (arg in args) switch arg.expr {
					case EConst(CString(s, _)):
						group.push(s);
					case _:
						ok = false;
				}
				if (ok) out.push(group);
			case _:
		}
		return out;
	}

	/**
	 * The first `@:fmt` form of `name` that `fmtReadStringArgsAll` leaves out, as source, or null when
	 * none: the bare flag, or a call with an argument that is not a string literal. For a reader that must
	 * refuse what it cannot read, since taking it for an absent flag fails in silence.
	 */
	public static function fmtUnreadableForm(node: ShapeNode, name: String): Null<String> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':fmt') for (param in entry.params) switch param.expr {
			case EConst(CIdent(id)) if (id == name):
				return name;
			case ECall({ expr: EConst(CIdent(id)) }, args) if (id == name && !args.foreach(arg -> arg.expr.match(EConst(CString(_, _))))):
				return ExprTools.toString(param);
			case _:
		}
		return null;
	}

	/**
	 * Whether `format` reads and writes the struct `node` by key, as a mapping: the one predicate of the by-name lowering of
	 * the parser and the writer, and of what the native door generates over them.
	 */
	public static function isByNameStruct(node: ShapeNode, format: FormatReader.FormatInfo): Bool {
		if (format.isBinary || format.fieldLookup != ByName || format.keySyntax != Quoted) return false;
		if (node.annotations[AnnotationKeys.BIN_MAGIC] != null || node.annotations['bin.align'] != null) return false;
		for (child in node.children) {
			if (readMetaString(child, ':kw') != null) return false;
			if (readMetaString(child, ':lead') != null) return false;
			if (readMetaString(child, ':trail') != null) return false;
			if (readMetaString(child, ':sep') != null) return false;
		}
		return true;
	}

}
#end
