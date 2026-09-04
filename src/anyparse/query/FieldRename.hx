package anyparse.query;

import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Rewrite every reference to a backing field into a property name, inside ONE type, or refuse.
 *
 * The binding-aware half of the `trivial-getter` collapse, and the reason it is here rather than
 * in the check: deciding that `_x` may become `x` is a question about BINDINGS — which enclosing
 * function declares the new name, which construct hides the old one, whether a reference is a
 * bare identifier, a `this.` access or a `$x` interpolation read — and that is the question
 * `Rename` and `CrossRename` next door already own. The check keeps the PREDICATE (is this
 * property a trivial bridge, and what does the collapse mean); this module owns the walk.
 *
 * Not a general rename: it is a whole-set proposal, all-or-nothing. A single reference the walk
 * cannot prove is the field (`<other>.<field>`, a case-pattern mention, a construct whose binding
 * slot could hide a shadow) makes `collectRenameEdits` return null and the caller drop the entire
 * fix. That refuse-on-doubt bias is the opposite of `Rename`, which repairs what it can and
 * reports captures — a collapse has no repair to offer, only a correct rewrite or none.
 *
 * The one thing it does BEYOND replacing a token: when an enclosing function binds the property
 * name (`FieldRefScan.functionBindsName`), a bare `field` read must become `this.propName` — or
 * `<ClassName>.propName` where `this` cannot reach the member — because a plain `propName` there
 * would resolve to that binding instead. Missing a binder is what silently turns
 * `if (color == _color)` into the always-true `color == color`.
 */
@:nullSafety(Strict)
final class FieldRename {

	/**
	 * The rename edits for every backing-field reference in `cls`, or null when any reference is
	 * not provably the field. `propStatic` marks a STATIC property: `this` cannot reach it from
	 * anywhere, so a shadowed reference is class-qualified in every method, not only a static one.
	 */
	public static function collectRenameEdits(
		cls: QueryNode, source: String, field: String, skipSpans: Array<Span>, fieldNode: QueryNode, propName: String, propStatic: Bool
	): Null<Array<{ span: Span, text: String }>> {
		final edits: Array<{ span: Span, text: String }> = [];
		return renameWalk(cls, source, field, skipSpans, fieldNode, propName, false, false, cls.name, propStatic, edits) ? edits : null;
	}

	/**
	 * The qualifier prefix for a shadowed backing-field reference: the enclosing class name
	 * (`C.`) whenever `this` cannot carry it — inside a static method, where `this` is illegal,
	 * and for a STATIC property, which `this` never reaches from any method — else `this.` for
	 * an instance property in an instance method. A `(default, null)` property is writable from
	 * within its own class, so `C.prop = value` is legal too.
	 */
	private static inline function shadowQualifier(classQualified: Bool, className: Null<String>): String {
		return classQualified && className != null ? '$className.' : 'this.';
	}

	/** Whether `span` is fully contained in any of `spans`. */
	private static inline function withinAny(spans: Array<Span>, span: Span): Bool {
		return spans.exists(s -> span.from >= s.from && span.to <= s.to);
	}

	/**
	 * Walk `node`, collecting `field -> propName` rename edits; returns false (refuse the whole
	 * fix) on any reference that is not provably the field — a `<other>.<field>` access, a
	 * binding that shadows the name, a case-pattern mention, or a construct whose dropped
	 * binding slot could hide a shadow (`hidesBindingNamed`). The backing field decl and every
	 * `skipSpans` subtree (each deleted accessor, plus a relocated constructor-init statement)
	 * are skipped; the KEPT accessor is NOT in `skipSpans`, so its references ARE renamed.
	 * `inPattern` marks a case-pattern subtree. `shadowsProp` is set once an enclosing function
	 * binds `propName` in ANY form (`functionBindsName`): a bare `field` reference there must
	 * rewrite to `this.propName` (or to `<ClassName>.propName` via `shadowQualifier` when
	 * `classQualified` — inside a static method, where `this` is illegal, or for a static
	 * property, which `this` never reaches), since a plain `propName` would resolve to that
	 * binding instead of the field (silent data loss).
	 */
	private static function renameWalk(
		node: QueryNode, source: String, field: String, skipSpans: Array<Span>, fieldNode: QueryNode, propName: String, inPattern: Bool,
		shadowsProp: Bool, className: Null<String>, classQualified: Bool, out: Array<{ span: Span, text: String }>
	): Bool {
		if (node == fieldNode) return true;
		final span: Null<Span> = node.span;
		if (span != null && withinAny(skipSpans, span)) return true;
		if (FieldRefScan.hidesBindingNamed(node, span, source, field)) return false;
		final nowPattern: Bool = inPattern || node.kind == 'Plain';
		if (!renameFieldRef(node, span, source, field, propName, shadowsProp, classQualified, className, nowPattern, out)) return false;
		final childShadows: Bool = shadowsProp || (FieldRefScan.isFnScope(node) && FieldRefScan.functionBindsName(node, propName));
		return renameChildren(
			node, source, field, skipSpans, fieldNode, propName, nowPattern, childShadows, className, classQualified, out
		);
	}

	/**
	 * Emit the rename edit for `node` when it is a bare-or-`this.` reference to the backing
	 * field — an `IdentExpr <field>` (rewritten to `propName`, qualified `this.`/`C.` when a
	 * binding of `propName` shadows it) or a `this.<field>` `FieldAccess` (its name token
	 * rewritten). Returns false (refuse the whole fix) on a reference the rename cannot prove
	 * safe: a pattern-position mention, an `<other>.<field>` access, or any other node kind
	 * carrying the field name. A node that does not name the field is left untouched (true).
	 */
	private static function renameFieldRef(
		node: QueryNode, span: Null<Span>, source: String, field: String, propName: String, shadowsProp: Bool, classQualified: Bool,
		className: Null<String>, nowPattern: Bool, out: Array<{ span: Span, text: String }>
	): Bool {
		if (node.name != field) return true;
		if (nowPattern) return false;
		switch node.kind {
			case 'IdentExpr':
				if (span != null)
					out.push({ span: span, text: shadowsProp ? shadowQualifier(classQualified, className) + propName : propName });
			case 'FieldAccess':
				if (span == null || node.children.length != 1 || node.children[0].kind != 'IdentExpr' || node.children[0].name != 'this')
					return false;
				return pushTokenRename(source, span, field, propName, out);
			case 'Ident':
				// A simple `$field` string-interpolation read: grammar kind `Ident` (not `IdentExpr`),
				// its span covering `$field`, so rename only the identifier token. The `$name` form
				// carries no `this.`/`C.` qualifier, so a prop-name local shadowing the field cannot be
				// disambiguated -- refuse rather than bind the wrong slot.
				if (shadowsProp || span == null) return false;
				return pushTokenRename(source, span, field, propName, out);
			case _:
				return false;
		}
		return true;
	}

	/**
	 * Emit the rename edit for a backing-field reference whose `span` includes syntax around the
	 * identifier -- a `this.` receiver (`FieldAccess`) or a `$` interpolation sigil (`Ident`):
	 * locate the `field` identifier token inside `span` and rewrite just that token to `propName`.
	 * False when the token cannot be located.
	 */
	private static function pushTokenRename(
		source: String, span: Span, field: String, propName: String, out: Array<{ span: Span, text: String }>
	): Bool {
		final off: Int = SourceText.identTokenOffset(source, span, field);
		if (off < 0) return false;
		out.push({ span: new Span(off, off + field.length), text: propName });
		return true;
	}

	/**
	 * Recurse `renameWalk` over `node`'s children, threading the pattern / shadow / qualifier
	 * context. `mods` accumulates the modifier-sibling kinds preceding a member so a `static`
	 * child function is recursed with `classQualified` set (`mods` resets at each member
	 * boundary; `classQualified` itself is monotone — a static property seeds it for the whole
	 * class). Returns false as soon as any descendant refuses the fix.
	 */
	private static function renameChildren(
		node: QueryNode, source: String, field: String, skipSpans: Array<Span>, fieldNode: QueryNode, propName: String, nowPattern: Bool,
		childShadows: Bool, className: Null<String>, classQualified: Bool, out: Array<{ span: Span, text: String }>
	): Bool {
		var mods: Array<String> = [];
		for (c in node.children) {
			final childQualified: Bool = classQualified || (FieldRefScan.isFnScope(c) && mods.contains('Static'));
			if (!renameWalk(c, source, field, skipSpans, fieldNode, propName, nowPattern, childShadows, className, childQualified, out))
				return false;
			mods = switch c.kind {
				case 'VarMember', 'FinalMember', 'FnMember', 'FinalModifiedMember': [];
				case _: mods.concat([c.kind]);
			};
		}
		return true;
	}

}
