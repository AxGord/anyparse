package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * A `new`-expression's written type: the verbatim text and whether it carries
 * explicit `<...>` type parameters — `writtenNewType`'s result.
 */
private typedef WrittenNewType = {
	var written: String;
	var generic: Bool;
}

/**
 * Shared statically-certain type inference for a declaration's initializer,
 * plus the two textual helpers that locate a declaration's type-annotation slot.
 * Extracted from `explicit-type` so the local-type check (`explicit-local-type`)
 * reuses the exact same rules rather than copying them: a field, a parameter and a
 * local all annotate the same statically-certain initializer shapes at the same
 * offset (right after the name), so the logic is one place.
 */
@:nullSafety(Strict)
final class LiteralInfer {

	/**
	 * The type source to annotate for `init` when its type is statically certain,
	 * else null. A literal maps through `shape.literalTypeNames`; a `Neg` wrapping a
	 * numeric literal takes that literal's type; a `new T<...>()` with WRITTEN type
	 * parameters carries `T<...>` verbatim (a bare `new T()` — possibly generic —
	 * yields null); a typed cast / check-type takes its target type. Anything else
	 * (a call, a field read, an array / map / ternary) is null — report-only.
	 */
	public static function inferType(init: QueryNode, source: String, shape: RefShape, castTargets: () -> Map<Int, String>): Null<String> {
		final literalTypes: Map<String, String> = shape.literalTypeNames ?? [];
		final numeric: Array<String> = shape.numericLiteralKinds ?? [];
		final negKind: Null<String> = shape.negationKind;
		final newKind: Null<String> = shape.newExprKind;
		final castKinds: Array<String> = shape.typedCastKinds ?? [];
		final direct: Null<String> = literalTypes[init.kind];
		if (direct != null) return direct;
		if (negKind != null && init.kind == negKind && init.children.length == 1) {
			final inner: QueryNode = init.children[0];
			return numeric.contains(inner.kind) ? literalTypes[inner.kind] : null;
		}
		if (newKind != null && init.kind == newKind) return newTypeSource(init, source);
		final span: Null<Span> = init.span;
		return span != null && castKinds.contains(init.kind) ? TypeResolver.castTargetWithin(span, castTargets()) : null;
	}

	/**
	 * The `T<...>` type source of a `new T<...>(...)` when it carries WRITTEN type
	 * parameters, else null (a bare `new T(...)` could be a generic used without
	 * parameters, whose bare `:T` annotation would not type-check). Scans from after
	 * `new` for the balanced `<...>`; a `>` preceded by `-` is the arrow `->` inside
	 * a function-type parameter, not an angle close. A constructor `(` reached before
	 * any `<` means no written type parameters.
	 */
	public static function newTypeSource(newNode: QueryNode, source: String): Null<String> {
		final t: Null<WrittenNewType> = writtenNewType(newNode, source);
		return t != null && t.generic ? t.written : null;
	}

	/**
	 * The bare (parameterless) written type of a `new T(...)` — the text between
	 * `new` and the argument `(`, or null when the constructor writes type
	 * parameters (`newTypeSource`'s case) or the span is missing. The caller must
	 * prove `T` non-generic before using this as an annotation.
	 */
	public static function bareNewTypeName(newNode: QueryNode, source: String): Null<String> {
		final t: Null<WrittenNewType> = writtenNewType(newNode, source);
		return t != null && !t.generic ? t.written : null;
	}

	/**
	 * Whether a `:` type annotation precedes the declaration's initializer / default.
	 * The type sits between the name and the first child (the initializer / default
	 * value, when present) or the declaration's end; neither the keyword, the name,
	 * nor property accessors `(get, set)` contain a `:`, so a `:` in that prefix is
	 * the type. A node with no span cannot be judged and is treated as typed.
	 */
	public static function hasTypeBeforeInit(node: QueryNode, source: String): Bool {
		final span: Null<Span> = node.span;
		if (span == null) return true;
		var cutoff: Int = span.to;
		if (node.children.length > 0) {
			final firstSpan: Null<Span> = node.children[0].span;
			if (firstSpan != null) cutoff = firstSpan.from;
		}
		return source.substring(span.from, cutoff).indexOf(':') >= 0;
	}

	/**
	 * The offset right after the declaration's name — where a `:Type` annotation is
	 * inserted — found by walking back over whitespace from the assignment `=` that
	 * precedes the initializer. Returns -1 when no `=` is in the name-to-initializer
	 * prefix (a declaration with no initializer cannot be annotated by this fix).
	 */
	public static function insertPoint(node: QueryNode, init: QueryNode, source: String): Int {
		final span: Null<Span> = node.span;
		final initSpan: Null<Span> = init.span;
		if (span == null || initSpan == null) return -1;
		final prefix: String = source.substring(span.from, initSpan.from);
		final eq: Int = prefix.lastIndexOf('=');
		if (eq < 0) return -1;
		var pos: Int = span.from + eq;
		while (pos > span.from && StringTools.isSpace(source, pos - 1)) pos--;
		return pos;
	}

	/**
	 * Scan a `new T(...)`'s written type: the text between `new` and the argument
	 * `(`. A balanced `<...>` before the `(` marks explicit type parameters
	 * (`generic: true`, text includes them); a `>` preceded by `-` is the arrow
	 * `->` inside a function-type parameter, not an angle close. Null when the
	 * span is missing, the text is empty, or the params never close.
	 */
	private static function writtenNewType(newNode: QueryNode, source: String): Null<WrittenNewType> {
		final span: Null<Span> = newNode.span;
		if (span == null) return null;
		final full: String = source.substring(span.from, span.to);
		var i: Int = 3;
		while (i < full.length && StringTools.isSpace(full, i)) i++;
		final typeStart: Int = i;
		var depth: Int = 0;
		while (i < full.length) {
			switch StringTools.fastCodeAt(full, i) {
				case '('.code if (depth == 0):
					final bare: String = StringTools.rtrim(full.substring(typeStart, i));
					return bare == '' ? null : { written: bare, generic: false };
				case '<'.code:
					depth++;
				case '>'.code if (StringTools.fastCodeAt(full, i - 1) != '-'.code):
					depth--;
					if (depth == 0) return { written: full.substring(typeStart, i + 1), generic: true };
				case _:
			}
			i++;
		}
		return null;
	}

}
