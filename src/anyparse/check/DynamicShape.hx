package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/** Resolved kind sets + config-independent names threaded through the walk, built once per run. */
typedef DynCtx = {
	final dynName: String;
	final fieldKinds: Array<String>;
	final paramKinds: Array<String>;
	final localKinds: Array<String>;
	final bodyKinds: Array<String>;
	final prefixKinds: Array<String>;
	final externKind: Null<String>;
	final enumAbstractKind: Null<String>;
	final anonKind: String;

	/** Kinds projected INSIDE a declaration's annotation text - they do not end the scanned region. */
	final typeRefKinds: Array<String>;
	final varFieldKind: String;
	final callKind: String;
	final fieldAccessKind: String;
	final identKind: String;
	final selfText: Null<String>;
	final typeDeclKinds: Array<String>;
};

/**
 * The grammar-shape vocabulary the three parts of `avoid-dynamic` share: the resolved kind sets
 * and names every walk threads (`DynCtx`), the lookups that find the declaration a raw `Dynamic`
 * token annotates, and the predicates that decide whether a written type name is a nominal one.
 *
 * It lives outside all three because none of them owns it: the primary rule builds the context,
 * the bag arm and the ascription arm each read part of it, and a scan may not reach back into a
 * rule for vocabulary.
 */
@:nullSafety(Strict)
final class DynamicShape {

	/**
	 * Whether `c` is an identifier character - the class both nominal-name proofs and the whole-word scan cut on.
	 */
	public static inline function isWordChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/** The smallest node whose kind is in `kinds` and whose span contains `span`, or null. */
	public static function innermostContaining(tree: QueryNode, span: Span, kinds: Array<String>): Null<QueryNode> {
		var best: Null<QueryNode> = null;
		var bestWidth: Int = 0;
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (s != null && kinds.contains(n.kind) && s.from <= span.from && span.to <= s.to) {
				final width: Int = s.to - s.from;
				if (best == null || width < bestWidth) {
					best = n;
					bestWidth = width;
				}
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * The `from:to` span keys of every read/write occurrence of `name` that `Refs.find` binds to the
	 * declaration at `bindFrom` — the set both use classifiers match an identifier node against, so
	 * neither ever judges a same-named binding from another scope.
	 */
	public static function occurrenceKeysOf(name: String, bindFrom: Int, tree: QueryNode, shape: RefShape): Map<String, Bool> {
		final keys: Map<String, Bool> = [];
		for (h in Refs.find(name, tree, shape)) {
			final b: Null<Span> = h.bindingSpan;
			if (h.kind != RefKind.Decl && b != null && b.from == bindFrom) keys['${h.span.from}:${h.span.to}'] = true;
		}
		return keys;
	}

	/** Whether `ty` is a usable narrowing / sink type — a plain nominal name that is not the raw dynamic name or `Any`. */
	public static function acceptableType(ty: String, dynName: String): Bool {
		return ty != dynName && ty != 'Any' && isNominalName(ty);
	}

	/** Whether `name` is a plain nominal simple/qualified name — no generics, arrows or other type syntax. */
	public static function isNominalName(name: String): Bool {
		if (name.length == 0) return false;
		for (k in 0...name.length) {
			final c: Int = name.fastCodeAt(k);
			if (!isWordChar(c) && c != '.'.code) return false;
		}
		return true;
	}

	/** The resolved kind sets threaded through the walk, built once per run. */
	public static function buildCtx(shape: RefShape, dynName: String): DynCtx {
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final localKinds: Array<String> = shape.localDeclKinds ?? [];
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		final prefixKinds: Array<String> = (shape.modifierOrderKinds ?? []).copy();
		final externName: Null<String> = shape.externModifierKind;
		if (externName != null) prefixKinds.push(externName);
		final macroMod: Null<String> = shape.macroModifierKind;
		if (macroMod != null) prefixKinds.push(macroMod);
		prefixKinds.push('Meta');
		return {
			dynName: dynName,
			fieldKinds: fieldKinds,
			paramKinds: paramKinds,
			localKinds: localKinds,
			bodyKinds: bodyKinds,
			prefixKinds: prefixKinds,
			externKind: externName,
			enumAbstractKind: shape.enumAbstractDeclKind,
			anonKind: 'Anon',
			typeRefKinds: shape.typeRefChildKinds ?? [],
			varFieldKind: 'VarField',
			callKind: shape.callKind ?? '',
			fieldAccessKind: shape.fieldAccessKind ?? '',
			identKind: shape.identKind,
			selfText: shape.selfReferenceText,
			typeDeclKinds: shape.visibilityContainerKinds ?? []
		};
	}

	/**
	 * The return-type node of `node` when it is a function form (has a body-marker
	 * child): the child directly before the body, when that child is neither a
	 * parameter nor a body marker — mirroring `explicit-type`'s rule, which also
	 * separates a generic constraint (before the parameters) from the return type
	 * (immediately before the body). A constructor's before-body child is a
	 * parameter, so it yields no return type.
	 */
	public static function returnTypeNode(node: QueryNode, ctx: DynCtx): Null<QueryNode> {
		final kids: Array<QueryNode> = node.children;
		var bodyIndex: Int = -1;
		for (i in 0...kids.length) if (ctx.bodyKinds.contains(kids[i].kind)) bodyIndex = i;
		if (bodyIndex <= 0) return null;
		final before: QueryNode = kids[bodyIndex - 1];
		return ctx.paramKinds.contains(before.kind) || ctx.bodyKinds.contains(before.kind) ? null : before;
	}

	/**
	 * The innermost declaration of one of `kinds` whose OWN whole-type annotation is EXACTLY
	 * the `Dynamic` token at `span` — the char before it (skipping whitespace) is a `:` and
	 * the char after is `=` / `;` / decl-end, so `Array<Dynamic>` / `Dynamic->Void` and a
	 * struct-field `Dynamic` (which lives in a projected child) are all rejected. Null when
	 * `span` is not a whole-type declaration annotation of one of `kinds`.
	 */
	public static function wholeDynamicDecl(
		tree: QueryNode, source: String, span: Span, dynName: String, kinds: Array<String>
	): Null<QueryNode> {
		if (kinds.length == 0) return null;
		if (span.to > source.length || source.substring(span.from, span.to) != dynName) return null;
		var i: Int = span.from - 1;
		while (i >= 0 && isSpaceCode(source.fastCodeAt(i))) i--;
		if (i < 0 || source.fastCodeAt(i) != ':'.code) return null;
		var j: Int = span.to;
		while (j < source.length && isSpaceCode(source.fastCodeAt(j))) j++;
		final after: Int = j < source.length ? source.fastCodeAt(j) : -1;
		if (after != '='.code && after != ';'.code && after != -1) return null;
		final decl: Null<QueryNode> = innermostContaining(tree, span, kinds);
		if (decl == null) return null;
		for (c in decl.children) {
			final cs: Null<Span> = c.span;
			if (cs != null && cs.from <= span.from && span.to <= cs.to) return null;
		}
		return decl;
	}

	private static inline function isSpaceCode(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

}
