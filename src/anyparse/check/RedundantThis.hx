package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a redundant `this.` qualifier — a `this.field` access where no local,
 * parameter, loop / catch variable or local function in the enclosing member
 * shadows `field`, so `this.` adds nothing and the access reduces to bare
 * `field`. `Info` severity (a cosmetic cleanup); `fix` drops the `this.`.
 *
 * A `this.field` is kept (not flagged) when a same-named binding is in scope —
 * the canonical `this.x = x` constructor pattern, where the parameter `x`
 * shadows the field and `this.` is load-bearing.
 *
 * ## Grammar-agnostic
 *
 * The self-qualifier text comes from `RefShape.selfReferenceText` (`this` /
 * `self`; unset → no-op), the access node from `fieldAccessKind`, the receiver
 * ident from `identKind`. Shadowing names are collected from `paramKinds`,
 * `localDeclKinds`, `selfScopeDeclKinds` (loop iterator / catch var) and
 * `localFunctionKinds`, scoped to each enclosing member function. A compile-time
 * abstract's `this.field` (where `this` is the underlying value and `this.` is
 * mandatory) carries no `identKind` receiver child, so it is never matched.
 */
@:nullSafety(Strict)
final class RedundantThis implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-this';
	}

	public function description(): String {
		return 'a this.field access whose this. qualifier is redundant';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final ctx: Null<Ctx> = context(plugin);
		if (ctx == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walkMembers(violations, entry.file, tree, ctx);
		}
		return violations;
	}

	/** Drop the `this.` qualifier of each flagged access, leaving the bare field name. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final ctx: Null<Ctx> = context(plugin);
		return ctx == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [ctx.fieldAccessKind], (node, span) -> {
				if (!isThisAccess(node, ctx)) return null;
				final fieldName: Null<String> = node.name;
				return fieldName == null ? null : { span: span, text: fieldName };
			});
	}

	/** Bundle the seams the check needs, or null when the grammar lacks any. */
	private static function context(plugin: GrammarPlugin): Null<Ctx> {
		final shape: RefShape = plugin.refShape();
		final self: Null<String> = shape.selfReferenceText;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final identKind: Null<String> = shape.identKind;
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		if (self == null || fieldAccessKind == null || identKind == null || functionKinds.length == 0) return null;
		final bindingKinds: Array<String> = (shape.paramKinds ?? []).concat(shape.localDeclKinds ?? [])
			.concat(shape.selfScopeDeclKinds ?? [])
			.concat(shape.localFunctionKinds ?? []);
		return {
			self: self,
			fieldAccessKind: fieldAccessKind,
			identKind: identKind,
			functionKinds: functionKinds,
			bindingKinds: bindingKinds,
			underlyingThisKinds: shape.underlyingThisTypeKinds ?? []
		};
	}

	/**
	 * Descend to each OUTERMOST member function, then flag its redundant `this.`
	 * accesses against the names bound anywhere in its subtree — a name bound in
	 * any branch or nested function is treated as a possible shadow (conservative,
	 * never removes a load-bearing `this.`). On reaching a function the whole
	 * subtree is handled here, so nested functions are not visited again. A
	 * compile-time abstract (where `this` is the underlying value and `this.` is
	 * mandatory) is skipped entirely.
	 */
	private static function walkMembers(out: Array<Violation>, file: String, node: QueryNode, c: Ctx): Void {
		if (c.underlyingThisKinds.contains(node.kind)) return;
		if (c.functionKinds.contains(node.kind)) {
			final names: Array<String> = [];
			collectBindingNames(node, c, names);
			flagThisAccess(out, file, node, c, names);
			return;
		}
		for (child in node.children) walkMembers(out, file, child, c);
	}

	/** Collect every shadowing binding name in `node`'s subtree. */
	private static function collectBindingNames(node: QueryNode, c: Ctx, names: Array<String>): Void {
		if (c.bindingKinds.contains(node.kind)) {
			final name: Null<String> = node.name;
			if (name != null) names.push(name);
		}
		for (child in node.children) collectBindingNames(child, c, names);
	}

	/** Flag each `this.field` in `node`'s subtree whose field name is not shadowed. */
	private static function flagThisAccess(out: Array<Violation>, file: String, node: QueryNode, c: Ctx, names: Array<String>): Void {
		if (isThisAccess(node, c)) {
			final fieldName: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (fieldName != null && span != null && !names.contains(fieldName)) out.push({
				file: file,
				span: span,
				rule: 'redundant-this',
				severity: Severity.Info,
				message: 'redundant this. qualifier — reduces to $fieldName'
			});
		}
		for (child in node.children) flagThisAccess(out, file, child, c, names);
	}


	/** `this.field`: a field-access node whose sole child is the self-reference ident. */
	private static function isThisAccess(node: QueryNode, c: Ctx): Bool {
		if (node.kind != c.fieldAccessKind || node.children.length != 1) return false;
		final receiver: QueryNode = node.children[0];
		return receiver.kind == c.identKind && receiver.name == c.self;
	}

}

private typedef Ctx = {
	self: String,
	fieldAccessKind: String,
	identKind: String,
	functionKinds: Array<String>,
	bindingKinds: Array<String>,
	underlyingThisKinds: Array<String>
};
