package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.Check.ConfigAware;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a call in STATEMENT position whose result is a PROVABLY non-`Void` value
 * that is discarded — a possibly-lost return value the author should either use or
 * intentionally ignore. `Info`; report-only (the fix is an intent decision, not a
 * mechanical edit, so there is no autofix).
 *
 * ## Provable non-`Void` only — no guessing
 *
 * The callee's return type is resolved exclusively through the existing type
 * infrastructure, and an UNKNOWN return is always a safe miss:
 *
 *  - a plain-identifier call `f()` — the callee binds (scope resolver) to a
 *    same-file function / local function whose `TypeInfoProvider.returnTypes` outer
 *    nominal is read; failing a lexical binding (an unqualified implicit-`this`
 *    method), the enclosing type's member is resolved via `SymbolIndex.returnNominalOf`;
 *  - a `recv.method()` call — `recv`'s declared type (`TypeResolver.identTypeName`) or,
 *    unbound, its own name as a static receiver, keys `SymbolIndex.returnNominalOf`;
 *  - a `this.method()` call — the enclosing type keys `SymbolIndex.returnNominalOf`.
 *
 * A callee with no recovered return nominal (unannotated / inferred / stdlib type
 * absent from the project index / a complex non-identifier receiver / an unresolved
 * binding), a `Void` return, or the untyped escape hatches (`Dynamic` / `Any`) are
 * all skipped — never a "probably". Only a `callKind` that is the DIRECT child of an
 * `exprStatementKind` counts as statement position: the same call as an RHS, an
 * argument, a `return` value, or a condition keeps its result and is not flagged, and
 * only the OUTERMOST call of a chain (`a().b()`) is the discarded one.
 *
 * ## Side-effect idioms — a configurable allowlist
 *
 * Mutators whose non-`Void` result is idiomatically discarded (`push` returns the new
 * length, `remove` a `Bool`, …) are exempt by CALL NAME via `DEFAULT_ALLOW`; a project
 * extends it through `apqlint.json` (`unused-return-value.allow`, a list of names ADDED
 * to the default). The match is on the called name for every receiver form.
 */
@:nullSafety(Strict)
final class UnusedReturnValue implements Check implements ConfigAware {

	/**
	 * Call names whose non-`Void` result is idiomatically discarded — in-place
	 * mutators / membership tests where dropping the return is the norm (`push` /
	 * `unshift` new length, `pop` / `shift` / `splice` the removed element(s),
	 * `remove` / `exists` a `Bool`, `add` / `set` / `insert` / `sort` / `resize`
	 * collection mutations). A project adds to this via `apqlint.json`.
	 */
	private static final DEFAULT_ALLOW: Array<String> = [
		'push',
		'pop',
		'shift',
		'unshift',
		'splice',
		'remove',
		'set',
		'add',
		'sort',
		'resize',
		'insert',
		'exists'
	];

	/** Return outer-nominals that carry no discardable value — `Void` (none) and the untyped escape hatches. */
	private static final NON_VALUE_RETURNS: Array<String> = ['Void', 'Dynamic', 'Any'];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'unused-return-value';
	}

	public function description(): String {
		return 'a call whose provably non-Void result is discarded in statement position — a possibly-lost value';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final identKind: String = shape.identKind;
		final callKind: Null<String> = shape.callKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (callKind == null || exprStmtKind == null) return [];
		final callK: String = callKind;
		final stmtK: String = exprStmtKind;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final ctx: Ctx = {
			shape: shape,
			identKind: identKind,
			callKind: callK,
			exprStmtKind: stmtK,
			fieldAccessKind: shape.fieldAccessKind,
			selfReferenceText: shape.selfReferenceText,
			opaqueKinds: shape.opaqueKinds ?? [],
			index: index
		};
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final extra: Null<Array<String>> = LintConfig.resolveWith(_resolveConfig, entry.file)
				.stringListOption('unused-return-value', 'allow');
			final allow: Array<String> = extra == null ? DEFAULT_ALLOW : DEFAULT_ALLOW.concat(extra);
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			final returnTypes: Map<Int, String> = typed.returnTypes(entry.source);
			walk(violations, entry.file, tree, tree, declaredTypes, returnTypes, allow, ctx);
		}
		return violations;
	}

	/** No safe single edit — using or ignoring the result is an author decision. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Walk `node`, flagging a discarded statement-position call. A call is flagged only
	 * when its `ExprStmt` is NOT the last child of its block: a non-final block / case /
	 * body expression's value is always dropped in Haxe, so the discard is PROVEN. The
	 * LAST statement may instead BE the block's / case's / non-`Void` function's value
	 * (`return switch { case A: f(); }`), so it is conservatively skipped — a discard
	 * there is not provable without full value-context typing.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>,
		returnTypes: Map<Int, String>, allow: Array<String>, ctx: Ctx
	): Void {
		if (ctx.opaqueKinds.contains(node.kind)) return;
		final last: Int = node.children.length - 1;
		for (i in 0...node.children.length) {
			final child: QueryNode = node.children[i];
			if (i < last && child.kind == ctx.exprStmtKind && child.children.length >= 1 && child.children[0].kind == ctx.callKind) {
				final hit: Null<{ span: Span, message: String }> = inspectCall(
					child.children[0], root, declaredTypes, returnTypes, allow, ctx
				);
				if (hit != null) out.push({
					file: file,
					span: hit.span,
					rule: 'unused-return-value',
					severity: Severity.Info,
					message: hit.message
				});
			}
			walk(out, file, child, root, declaredTypes, returnTypes, allow, ctx);
		}
	}

	/**
	 * The finding for a discarded statement-position call, or null when the callee's
	 * return is unknown / `Void` / untyped / allowlisted, or the receiver is not a
	 * plain identifier.
	 */
	private static function inspectCall(
		call: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, returnTypes: Map<Int, String>, allow: Array<String>, ctx: Ctx
	): Null<{ span: Span, message: String }> {
		final span: Null<Span> = call.span;
		if (span == null || call.children.length < 1) return null;
		final at: Span = span;
		final resolved: Null<{ nominal: String, desc: String }> = resolveReturn(
			call.children[0], root, declaredTypes, returnTypes, allow, ctx
		);
		return resolved == null ? null : {
			span: at,
			message: 'the ${resolved.nominal} result of ${resolved.desc} is discarded — a possibly-lost value'
		};
	}

	/**
	 * The proven non-`Void` return nominal + a describing text for `callee`, or null when
	 * the callee is allowlisted, its return is unknown / `Void` / untyped, or its receiver
	 * is not a plain identifier.
	 */
	private static function resolveReturn(
		callee: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, returnTypes: Map<Int, String>, allow: Array<String>, ctx: Ctx
	): Null<{ nominal: String, desc: String }> {
		if (callee.kind == ctx.identKind) {
			final name: Null<String> = callee.name;
			if (name == null || allow.contains(name)) return null;
			final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(callee, root, ctx.shape);
			// A lexical binding (same-file function / local function) reads `returnTypes`;
			// an unqualified implicit-`this` method resolves against the enclosing type.
			final nominal: Null<String> = bindingFrom != null ? returnTypes[bindingFrom] : memberReturn(root, callee.span, name, ctx);
			return discarded(nominal, '${name}()');
		}
		final fieldAccessKind: Null<String> = ctx.fieldAccessKind;
		if (fieldAccessKind == null || callee.kind != fieldAccessKind || callee.children.length != 1) return null;
		final method: Null<String> = callee.name;
		if (method == null || allow.contains(method)) return null;
		final recv: QueryNode = callee.children[0];
		if (recv.kind != ctx.identKind) return null;
		final recvName: Null<String> = recv.name;
		if (recvName == null) return null;
		final name: String = recvName;
		final selfText: Null<String> = ctx.selfReferenceText;
		final nominal: Null<String> = if (selfText != null && name == selfText)
			memberReturn(root, callee.span, method, ctx);
		else {
			// An instance receiver resolves through its declared type; an unbound name is a
			// static / type receiver, looked up by its own name.
			final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(recv, root, ctx.shape);
			final lookupType: Null<String> = bindingFrom == null ? name : declaredTypes[bindingFrom];
			lookupType == null ? null : ctx.index.returnNominalOf(lookupType, method);
		}
		return discarded(nominal, '${name}.${method}()');
	}

	/** The enclosing type's `member` return nominal (for `this.` / implicit-`this` calls), or null. */
	private static function memberReturn(root: QueryNode, span: Null<Span>, member: String, ctx: Ctx): Null<String> {
		final enclosing: Null<String> = enclosingTypeName(root, span);
		return enclosing == null ? null : ctx.index.returnNominalOf(enclosing, member);
	}

	/** The `{nominal, desc}` finding when `nominal` is a discardable value, or null for `Void` / untyped / unknown. */
	private static function discarded(nominal: Null<String>, desc: String): Null<{ nominal: String, desc: String }> {
		if (nominal == null || NON_VALUE_RETURNS.contains(nominal)) return null;
		final n: String = nominal;
		return { nominal: n, desc: desc };
	}

	/** The simple name of the innermost type declaration whose span contains `span`, or null. */
	private static function enclosingTypeName(tree: QueryNode, span: Null<Span>): Null<String> {
		if (span == null) return null;
		final at: Span = span;
		var best: Null<TypeDeclMatch> = null;
		function visit(n: QueryNode): Void {
			final td: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(n);
			if (td != null && td.fullSpan.from <= at.from && at.to <= td.fullSpan.to) {
				final b: Null<TypeDeclMatch> = best;
				if (b == null || (td.fullSpan.to - td.fullSpan.from) < (b.fullSpan.to - b.fullSpan.from)) best = td;
			}
			for (c in n.children) visit(c);
		}
		visit(tree);
		final b: Null<TypeDeclMatch> = best;
		return b == null ? null : b.name;
	}

}

/** Resolved per-run constants threaded through the recursive walk. */
private typedef Ctx = {
	var shape: RefShape;
	var identKind: String;
	var callKind: String;
	var exprStmtKind: String;
	var fieldAccessKind: Null<String>;
	var selfReferenceText: Null<String>;
	var opaqueKinds: Array<String>;
	var index: SymbolIndex;
};
