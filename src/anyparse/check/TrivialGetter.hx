package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

import anyparse.query.RefactorSupport;
import anyparse.check.Check.ConfigAware;
import anyparse.check.LintConfig;

/**
 * Flags a property that only bridges a private same-class backing field through trivial
 * accessors, and collapses it to a plainer form. The user's rule: don't hand-write a trivial
 * getter/setter over a backing field, use property access instead.
 * `Severity.Info`, with an autofix that renames the backing field into the property within the
 * class and deletes the collapsed accessors — airtight only when every backing-field reference
 * is a bare or `this.` access (other shapes stay report-only).
 *
 * ## Shapes
 *
 * - `public var x(get, never):T` / `(get, null):T` with `get_x` body exactly `return _x;` ->
 *   `(default, null)`, `get_x` deleted.
 * - `public var x(get, set):T` with a TRIVIAL getter (`return _x;`) and a NON-TRIVIAL setter ->
 *   `(default, set)`, `get_x` deleted, `set_x` kept. Decided three ways by the external writes
 *   (below).
 * - `public var x(get, set):T` with BOTH accessors trivial (getter `return _x;`, setter `return
 *   _x = value;`) -> a plain field `public var x:T`, both accessors deleted.
 * - `public var x(get, set):T` with a NON-TRIVIAL getter and a TRIVIAL setter -> `(get,
 *   default)`, `set_x` deleted, `get_x` kept. Read-gated (below).
 *
 * A trivial getter is exactly `return _x;` / `return this._x;`; a trivial setter is exactly
 * `return _x = value;` / `return this._x = value;` over the setter's single parameter. A `(get,
 * set)` with BOTH accessors non-trivial is left alone.
 *
 * ## Soundness gates (a miss over a wrong flag)
 *
 * 1. The read accessor is exactly `get`; the write is `never` / `null` / `set`. A custom-named
 *    accessor or a plain stored slot is skipped — only the standard `get_` / `set_` resolve.
 * 2. Neither accessor is `dynamic` (re-bindable at runtime — real behaviour).
 * 3. The backing field is private and declared in the SAME class. Interfaces (no accessor
 *    bodies) are skipped wholesale: only `ClassDecl` / `ClassForm` bodies are inspected.
 * 4. The declaring class has NO subtype in the index (`SymbolIndex.hasSubtype`) — a subclass
 *    could override an accessor, so the collapse would break the override.
 * 5. When the class `implements` anything and the property is PUBLIC, an implemented interface
 *    may declare it and so require a physical accessor; a COLLAPSING shape is skipped unless every
 *    implemented interface is resolvable in the index and provably lacks it
 *    (`SymbolIndex.typeProvablyLacksMember`). The inline arm (below) keeps `get_x`, so this gate
 *    never applies to it.
 *
 * ## The `(default, set)` shape-A write decision (three-way)
 *
 * After the `(get, set)` -> `(default, set)` collapse the property gains physical storage, so
 * inside `set_x` the renamed `x = value` is a DIRECT physical write (no recursion), and property
 * reads that previously went through the trivial (now-deleted) getter become identical direct
 * reads. Writes to a `(default, set)` property route through `set_x` EVERYWHERE except inside
 * `set_x` itself, so an external backing-field write, once renamed, would newly route through the
 * setter — a behavior change unless it is marked a direct write. Let `writes` be the external
 * statement-level writes to the backing field outside `set_x` (excluding the one movable
 * constructor-init below):
 *
 * - 0 writes -> collapse to `(default, set)` exactly as before.
 * - 1..`maxBypassWrites` writes, ALL statement-level -> collapse anyway and prefix each such write
 *   statement with `@:bypassAccessor ` (a bypass write on a `(default, set)` property is a direct
 *   field write — semantics preserved). Those writes still rename `_x` -> `x` (or `this.x` under
 *   shadowing). `maxBypassWrites` is the `trivial-getter` `maxBypassWrites` option (default 3).
 * - more than `maxBypassWrites`, or ANY write NOT at statement level (nested in a larger
 *   expression, e.g. `if ((_x = v)) ...`, which cannot be marked) -> do NOT collapse; instead
 *   mark `get_x` `inline` (property and backing field kept). Skipped when the getter is already
 *   `inline` or carries `override` (inline + override do not mix; an overriding accessor must stay
 *   overridable).
 *
 * ## The `(get, default)` read-gate
 *
 * After the `(get, set)` -> `(get, default)` collapse the property still has physical storage
 * (the `default` write forces it), so inside the kept `get_x` the renamed property read is a
 * DIRECT physical read (no recursion). The gate exists because READS of a `(get, default)`
 * property route through `get_x` EVERYWHERE except inside `get_x` itself: a backing-field read
 * outside the getter, once renamed, would start routing through the non-trivial getter — a
 * behavior change. So the property is skipped if there is ANY read of the backing field outside
 * `get_x`. A compound-assignment / incr / decr target reads the field (`x += 1` compiles to
 * `x = get_x() + 1`) and so also disqualifies. Writes are direct (`default` write) and never gate.
 *
 * ## Constructor-init exception (shape `(default, set)` only)
 *
 * A single top-level `_x = <literal>;` in the constructor (a compile-time literal, the FIRST
 * reference to `_x` in the constructor, and no field decl-initializer) is a deliberate
 * setter-bypass init. It is relocated onto the property declaration as `= <literal>` — a
 * physical `(default, set)` initializer, identical to the original direct write — and the
 * constructor statement is deleted. It is excluded from `writes`, so it never counts toward the
 * bypass cap.
 *
 * Internal writes to a `(get, never)` / `(get, null)` backing field from other methods are FINE
 * — that is what `(default, null)` preserves — so no write gate applies to those shapes.
 */
@:nullSafety(Strict)
final class TrivialGetter implements Check implements ConfigAware {

	/** Default cap on statement-level backing-field writes a shape-A collapse marks `@:bypassAccessor` before it instead falls back to inlining the getter. */
	private static inline final DEFAULT_MAX_BYPASS_WRITES: Int = 3;

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'trivial-getter';
	}

	public function description(): String {
		return
			'a property bridging a private backing field through trivial accessors — (get, never)/(get, null) collapses to (default, null); (get, set) collapses to (default, set) when only the getter is trivial, or to a plain field when both are';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final maxBypass: Int = LintConfig.resolveWith(_resolveConfig, entry.file)
				.intOption('trivial-getter', 'maxBypassWrites') ?? DEFAULT_MAX_BYPASS_WRITES;
			for (cls in classes(tree)) considerClass(out, cls, entry.source, entry.file, index, maxBypass);
		}
		return out;
	}

	/**
	 * Rewrite each flagged trivial-getter property into `(default, null)` — carrying the
	 * backing field's initializer onto the property, deleting the getter and the backing
	 * field, and renaming every in-class reference to the backing field into the property
	 * name. Airtight only for the safe sub-shape where every backing-field reference is a
	 * bare identifier or a `this.<field>` access: a `<other>.<field>` access (a different
	 * instance / class the rename could not prove), a local / parameter / capture that
	 * shadows the FIELD name (including the grammar-dropped multi-var and key-value-for
	 * binding slots), or a case-pattern mention of it, all leave the finding report-only.
	 * A bare backing-field reference inside a function that binds a parameter / local of the
	 * PROPERTY name is rewritten as `this.<prop>` (a plain `<prop>` would resolve to that
	 * binding, not the field — silent data loss). NOTE: a null `index` skips the
	 * subclass-override and interface-conformance gates — the production `lint --fix` caller
	 * always passes one; a direct caller without an index must ensure no subtype overrides
	 * the getter and no implemented interface requires it.
	 *
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final maxBypass: Int = violations.length == 0
			? DEFAULT_MAX_BYPASS_WRITES
			: LintConfig.resolveWith(_resolveConfig, violations[0].file)
				.intOption('trivial-getter', 'maxBypassWrites') ?? DEFAULT_MAX_BYPASS_WRITES;
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) wanted.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (cls in classes(tree)) collectClassFixEdits(cls, source, wanted, index, edits, maxBypass);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Every class-body node in the tree — `ClassDecl` and `final class`'s `ClassForm`. */
	private static function classes(root: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		collectClasses(root, out);
		return out;
	}

	private static function collectClasses(node: QueryNode, out: Array<QueryNode>): Void {
		if (node.kind == 'ClassDecl' || node.kind == 'ClassForm') out.push(node);
		for (child in node.children) collectClasses(child, out);
	}

	/**
	 * Flag each collapsible property of `cls` (`classifyProperty` decides the shape and applies
	 * the soundness gates), using the shared `memberTables`. A class with any subtype in the
	 * index is skipped — a subclass could override an accessor, so the suggested rewrite would
	 * break that override.
	 */
	private static function considerClass(
		out: Array<Violation>, cls: QueryNode, source: String, file: String, index: SymbolIndex, maxBypass: Int
	): Void {
		final className: Null<String> = cls.name;
		if (className == null || index.hasSubtype(className)) return;
		final t = memberTables(cls, source);
		for (prop in t.properties) {
			final c = classifyProperty(cls, source, index, prop, t.getters, t.setters, t.privateFieldNodes, maxBypass);
			if (c == null) continue;
			out.push({
				file: file,
				span: prop.span,
				rule: 'trivial-getter',
				severity: Severity.Info,
				message: c.message
			});
		}
	}

	/**
	 * The backing-field name a getter trivially returns — `_x` for a body of
	 * exactly `return _x;` or `return this._x;` — else null (any other body
	 * carries real logic).
	 */
	private static function trivialReturnField(getter: QueryNode): Null<String> {
		final body: Null<QueryNode> = bodyOf(getter);
		if (body == null || body.children.length != 1) return null;
		return switch body.kind {
			case 'BlockBody': returnedField(body.children[0], 'ReturnStmt');
			case 'ExprBody': returnedField(body.children[0], 'ReturnExpr');
			case _: null;
		}
	}

	/** The getter's body node (`BlockBody` / `ExprBody`), or null. */
	private static function bodyOf(getter: QueryNode): Null<QueryNode> {
		return getter.children.find(child -> child.kind == 'BlockBody' || child.kind == 'ExprBody');
	}

	/**
	 * The field name returned by a single-value `return` node (`ReturnStmt` /
	 * `ReturnExpr`, kind given by `returnKind`) — the name of a bare `IdentExpr`
	 * or a `this.<name>` `FieldAccess` — else null.
	 */
	private static function returnedField(ret: QueryNode, returnKind: String): Null<String> {
		return ret.kind != returnKind || ret.children.length != 1 ? null : fieldRefName(ret.children[0]);
	}

	/**
	 * The two accessor identifiers of a property's `(read, write)` clause, read from the
	 * source right after the field name — or null when the member is a plain field (no `(`
	 * clause) or the clause is malformed. `span.from` is at the `var` keyword.
	 */
	private static function accessorClause(source: String, span: Span): Null<{ read: String, write: String }> {
		final open: Int = accessorParenOpen(source, span);
		if (open < 0) return null;
		final n: Int = source.length;
		final read: Null<{ id: String, next: Int }> = identAt(source, skipSpace(source, open + 1, n), n);
		if (read == null) return null;
		final i: Int = skipSpace(source, read.next, n);
		if (i >= n || StringTools.fastCodeAt(source, i) != ','.code) return null;
		final write: Null<{ id: String, next: Int }> = identAt(source, skipSpace(source, i + 1, n), n);
		return write == null ? null : { read: read.id, write: write.id };
	}

	/** The identifier at `i` (already past whitespace) and the offset after it, or null. */
	private static function identAt(source: String, i: Int, n: Int): Null<{ id: String, next: Int }> {
		final start: Int = i;
		var j: Int = i;
		while (j < n && isIdentChar(StringTools.fastCodeAt(source, j))) j++;
		return j > start ? { id: source.substring(start, j), next: j } : null;
	}

	/** Advance past a whitespace run starting at `i`. */
	private static function skipSpace(source: String, i: Int, n: Int): Int {
		var j: Int = i;
		while (j < n && isSpace(StringTools.fastCodeAt(source, j))) j++;
		return j;
	}

	/** Whether `c` is an identifier character. */
	private static inline function isIdentChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/** Whether `c` is whitespace. */
	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}


	/**
	 * Collect the rewrite edits for every wanted collapsible property of `cls`, using the shared
	 * `memberTables` + `classifyProperty` for the shape / backing-field / accessor nodes and
	 * gates, and skipping a class with any subtype (a subclass override).
	 */
	private static function collectClassFixEdits(
		cls: QueryNode, source: String, wanted: Array<String>, index: Null<SymbolIndex>, out: Array<{ span: Span, text: String }>,
		maxBypass: Int
	): Void {
		final className: Null<String> = cls.name;
		if (className == null || (index != null && index.hasSubtype(className))) return;
		final t = memberTables(cls, source);
		for (prop in t.properties) if (wanted.contains('${prop.span.from}:${prop.span.to}')) {
			final c = classifyProperty(cls, source, index, prop, t.getters, t.setters, t.privateFieldNodes, maxBypass);
			if (c == null) continue;
			final e: Null<Array<{ span: Span, text: String }>> = buildFix(cls, source, prop.span, prop.name, c);
			if (e != null) for (edit in e) out.push(edit);
		}
	}

	/**
	 * The edits realising a classified collapse: rewrite the accessor clause (to `(default,
	 * null)` / `(default, set)`, or remove it for a plain field), move the backing initializer
	 * onto the property (the field's decl-initializer, or the movable constructor-init literal
	 * for a `(default, set)` collapse), delete each collapsed accessor and the backing field (and
	 * the relocated ctor statement), and rename every in-class backing-field reference to the
	 * property name. The KEPT accessor (the setter of a `(default, set)` collapse) is walked and
	 * its references renamed; the deleted accessors and the relocated ctor statement are skipped.
	 * Null when a semicolon / span cannot be located or the reference rename is not provably safe.
	 */
	private static function buildFix(
		cls: QueryNode, source: String, propSpan: Span, propName: String, c: {
			field: String,
			fieldNode: QueryNode,
			message: String,
			clauseSpan: Span,
			clauseText: String,
			deletedAccessors: Array<QueryNode>,
			ctorInit: Null<{ stmt: QueryNode, rhsSpan: Span }>,
			bypassStmts: Array<QueryNode>,
			inlineGetter: Null<QueryNode>
		}
	): Null<Array<{ span: Span, text: String }>> {
		final inlineGetter: Null<QueryNode> = c.inlineGetter;
		if (inlineGetter != null) {
			// The inline arm keeps the property and backing field untouched — a single `inline `
			// insertion before the getter's `function` keyword (the FnMember span start).
			final gSpan: Null<Span> = inlineGetter.span;
			return gSpan == null ? null : [{ span: new Span(gSpan.from, gSpan.from), text: 'inline ' }];
		}
		final edits: Array<{ span: Span, text: String }> = [{ span: c.clauseSpan, text: c.clauseText }];
		final initSpan: Null<Span> = c.ctorInit != null
			? c.ctorInit.rhsSpan
			: (c.fieldNode.children.length >= 1 ? c.fieldNode.children[0].span : null);
		if (initSpan != null) {
			final semi: Int = propSpan.to - 1;
			if (semi < 0 || semi >= source.length || StringTools.fastCodeAt(source, semi) != ';'.code) return null;
			edits.push({ span: new Span(semi, semi), text: ' = ${source.substring(initSpan.from, initSpan.to)}' });
		}
		final deleted: Array<{ node: QueryNode, span: Span }> = [];
		for (acc in c.deletedAccessors) {
			final s: Null<Span> = acc.span;
			if (s == null) return null;
			deleted.push({ node: acc, span: s });
		}
		final skipSpans: Array<Span> = [for (d in deleted) d.span];
		if (c.ctorInit != null) {
			final cs: Null<Span> = c.ctorInit.stmt.span;
			if (cs == null) return null;
			skipSpans.push(cs);
		}
		final renames: Null<Array<{ span: Span, text: String }>> = collectRenameEdits(
			cls, source, c.field, skipSpans, c.fieldNode, propName
		);
		if (renames == null) return null;
		for (e in renames) edits.push(e);
		for (d in deleted)
			edits.push({ span: RefactorSupport.lineExtendedSpan(source, RefactorSupport.declGroupSpan(d.node, cls, d.span)), text: '' });
		final fieldSpan: Null<Span> = c.fieldNode.span;
		if (fieldSpan == null) return null;
		edits.push(
			{ span: RefactorSupport.lineExtendedSpan(source, RefactorSupport.declGroupSpan(c.fieldNode, cls, fieldSpan)), text: '' }
		);
		if (c.ctorInit != null) {
			final cs: Null<Span> = c.ctorInit.stmt.span;
			if (cs == null) return null;
			edits.push({ span: RefactorSupport.lineExtendedSpan(source, cs), text: '' });
		}
		return applyBypassMarks(c.bypassStmts, edits) ? edits : null;
	}

	/** The rename edits for every backing-field reference in `cls`, or null when any reference is not provably the field. */
	private static function collectRenameEdits(
		cls: QueryNode, source: String, field: String, skipSpans: Array<Span>, fieldNode: QueryNode, propName: String
	): Null<Array<{ span: Span, text: String }>> {
		final edits: Array<{ span: Span, text: String }> = [];
		return renameWalk(cls, source, field, skipSpans, fieldNode, propName, false, false, cls.name, false, edits) ? edits : null;
	}

	/**
	 * Walk `node`, collecting `field -> propName` rename edits; returns false (refuse the whole
	 * fix) on any reference that is not provably the field — a `<other>.<field>` access, a
	 * binding that shadows the name, a case-pattern mention, or a construct whose dropped
	 * binding slot could hide a shadow (`hidesBindingNamed`). The backing field decl and every
	 * `skipSpans` subtree (each deleted accessor, plus a relocated constructor-init statement)
	 * are skipped; the KEPT accessor is NOT in `skipSpans`, so its references ARE renamed.
	 * `inPattern` marks a case-pattern subtree. `shadowsProp` is set once an enclosing function
	 * binds a parameter / local named `propName`: a bare `field` reference there must rewrite to
	 * `this.propName` (or to `<ClassName>.propName` inside a static method, where `this` is
	 * illegal, via `shadowQualifier`), since a plain `propName` would resolve to that binding
	 * instead of the field (silent data loss).
	 */
	private static function renameWalk(
		node: QueryNode, source: String, field: String, skipSpans: Array<Span>, fieldNode: QueryNode, propName: String, inPattern: Bool,
		shadowsProp: Bool, className: Null<String>, staticCtx: Bool, out: Array<{ span: Span, text: String }>
	): Bool {
		if (node == fieldNode) return true;
		final span: Null<Span> = node.span;
		if (span != null && withinAny(skipSpans, span)) return true;
		if (hidesBindingNamed(node, span, source, field)) return false;
		final nowPattern: Bool = inPattern || node.kind == 'Plain';
		if (!renameFieldRef(node, span, source, field, propName, shadowsProp, staticCtx, className, nowPattern, out)) return false;
		final childShadows: Bool = shadowsProp || (isFnScope(node) && functionBindsName(node, propName));
		return renameChildren(node, source, field, skipSpans, fieldNode, propName, nowPattern, childShadows, className, staticCtx, out);
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
		node: QueryNode, span: Null<Span>, source: String, field: String, propName: String, shadowsProp: Bool, staticCtx: Bool,
		className: Null<String>, nowPattern: Bool, out: Array<{ span: Span, text: String }>
	): Bool {
		if (node.name != field) return true;
		if (nowPattern) return false;
		switch node.kind {
			case 'IdentExpr':
				if (span != null) out.push({ span: span, text: shadowsProp ? shadowQualifier(staticCtx, className) + propName : propName });
			case 'FieldAccess':
				if (span == null || node.children.length != 1 || node.children[0].kind != 'IdentExpr' || node.children[0].name != 'this')
					return false;
				final off: Int = RefactorSupport.identTokenOffset(source, span, field);
				if (off < 0) return false;
				out.push({ span: new Span(off, off + field.length), text: propName });
			case _:
				return false;
		}
		return true;
	}

	/**
	 * Recurse `renameWalk` over `node`'s children, threading the pattern / shadow / static
	 * context. `mods` accumulates the modifier-sibling kinds preceding a member so a `static`
	 * child function is recursed with `staticCtx` set (reset at each member boundary). Returns
	 * false as soon as any descendant refuses the fix.
	 */
	private static function renameChildren(
		node: QueryNode, source: String, field: String, skipSpans: Array<Span>, fieldNode: QueryNode, propName: String, nowPattern: Bool,
		childShadows: Bool, className: Null<String>, staticCtx: Bool, out: Array<{ span: Span, text: String }>
	): Bool {
		var mods: Array<String> = [];
		for (c in node.children) {
			final childStatic: Bool = staticCtx || (isFnScope(c) && mods.contains('Static'));
			if (!renameWalk(c, source, field, skipSpans, fieldNode, propName, nowPattern, childShadows, className, childStatic, out))
				return false;
			mods = switch c.kind {
				case 'VarMember' | 'FinalMember' | 'FnMember' | 'FinalModifiedMember': [];
				case _: mods.concat([c.kind]);
			};
		}
		return true;
	}

	/** Whether `node` opens a new function scope (method / local fn / lambda) that binds parameters and locals. */
	private static inline function isFnScope(node: QueryNode): Bool {
		return switch node.kind {
			case 'FnMember' | 'FinalModifiedMember' | 'LocalFnStmt' | 'FnExpr' | 'ThinParenLambdaExpr' | 'ParenLambdaExpr' | 'ThinArrow': true;
			case _: false;
		}
	}

	/**
	 * Whether the subtree `node` binds a parameter / local / catch var named `name`. Scanned
	 * subtree-wide from a function scope, so a nested function's binding also trips it —
	 * over-qualifying a backing-field write with `this.` is always semantically correct.
	 */
	private static function functionBindsName(node: QueryNode, name: String): Bool {
		switch node.kind {
			case 'Required' | 'Optional' | 'Rest' | 'LambdaParam' | 'VarStmt' | 'FinalStmt' | 'LocalFnStmt' | 'CatchClause':
				if (node.name == name) return true;
			case _:
		}
		for (c in node.children) if (functionBindsName(c, name)) return true;
		return false;
	}

	/** The `(read, write)` accessor-clause span `[open, close]` of a property (`span.from` at `var`), or null. */
	private static function accessorParenSpan(source: String, propSpan: Span): Null<Span> {
		final open: Int = accessorParenOpen(source, propSpan);
		if (open < 0) return null;
		var i: Int = open + 1;
		while (i < source.length && StringTools.fastCodeAt(source, i) != ')'.code) i++;
		return i >= source.length ? null : new Span(open, i + 1);
	}


	/** The offset just past the `var name` prefix of `span` (keyword + whitespace + identifier), or -1 when it does not begin with `var <name>`. */
	private static function nameEndAfterVar(source: String, span: Span): Int {
		final n: Int = source.length;
		final kw: String = 'var';
		if (span.from + kw.length > n || source.substring(span.from, span.from + kw.length) != kw) return -1;
		var i: Int = skipSpace(source, span.from + kw.length, n);
		final nameStart: Int = i;
		while (i < n && isIdentChar(StringTools.fastCodeAt(source, i))) i++;
		return i == nameStart ? -1 : i;
	}


	/**
	 * Whether collapsing the property `propName` of `cls` to `(default, null)` could drop a
	 * `get_propName` that an implemented interface requires (Haxe: "Field get_propName needed
	 * by I is missing"). True when `cls` implements anything and the property is public, UNLESS
	 * every implemented interface is resolvable in `index` and provably lacks the property
	 * (`typeProvablyLacksMember`). A null `index` cannot prove absence, so any implemented
	 * interface blocks. A private property is never exposed through an interface, so never blocks.
	 */
	private static function interfaceRequiresGetter(cls: QueryNode, propName: String, isPublic: Bool, index: Null<SymbolIndex>): Bool {
		if (!isPublic) return false;
		final ifaces: Array<String> = implementedInterfaces(cls);
		if (ifaces.length == 0) return false;
		if (index == null) return true;
		for (iface in ifaces) if (!index.typeProvablyLacksMember(iface, propName)) return true;
		return false;
	}

	/** The simple names of every interface in `cls`'s `implements` clauses. */
	private static function implementedInterfaces(cls: QueryNode): Array<String> {
		final out: Array<String> = [];
		for (child in cls.children) if (child.kind == 'ImplementsClause') for (named in child.children) {
			final nm: Null<String> = named.name;
			if (nm != null) out.push(simpleName(nm));
		}
		return out;
	}

	/** The last `.`-separated segment of `path` (its simple name). */
	private static inline function simpleName(path: String): String {
		final segments: Array<String> = path.split('.');
		return segments[segments.length - 1] ?? path;
	}

	/**
	 * Build the member tables of `cls` shared by `considerClass` (report) and
	 * `collectClassFixEdits` (fix): private field nodes by name, `get_` getters and `set_`
	 * setters by name (each with its `dynamic` flag), and the collapsible read-only / paired
	 * properties — `(get, never)`, `(get, null)` and `(get, set)`. The shape decision and
	 * soundness gates for each live in `classifyProperty`.
	 */
	private static function memberTables(cls: QueryNode, source: String): {
		privateFieldNodes: Map<String, QueryNode>,
		getters: Map<String, {
			node: QueryNode,
			dyn: Bool,
			isOverride: Bool,
			isInline: Bool
		}>,
		setters: Map<String, {
			node: QueryNode,
			dyn: Bool,
			isOverride: Bool,
			isInline: Bool
		}>,
		properties: Array<{
			name: String,
			node: QueryNode,
			span: Span,
			isPublic: Bool,
			write: String
		}>
	} {
		final privateFieldNodes: Map<String, QueryNode> = [];
		final getters: Map<String, {
			node: QueryNode,
			dyn: Bool,
			isOverride: Bool,
			isInline: Bool
		}> = [];
		final setters: Map<String, {
			node: QueryNode,
			dyn: Bool,
			isOverride: Bool,
			isInline: Bool
		}> = [];
		final properties: Array<{
			name: String,
			node: QueryNode,
			span: Span,
			isPublic: Bool,
			write: String
		}> = [];
		var mods: Array<String> = [];
		for (child in cls.children) {
			switch child.kind {
				case 'VarMember' | 'FinalMember':
					final name: Null<String> = child.name;
					final span: Null<Span> = child.span;
					if (name != null && span != null) {
						final isPublic: Bool = mods.contains('Public');
						if (!isPublic) privateFieldNodes[name] = child;
						if (child.kind == 'VarMember') {
							final access: Null<{ read: String, write: String }> = accessorClause(source, span);
							if (
								access != null && access.read == 'get'
								&& (access.write == 'never' || access.write == 'null' || access.write == 'set')
							) properties.push({
								name: name,
								node: child,
								span: span,
								isPublic: isPublic,
								write: access.write
							});
						}
					}
					mods = [];
				case 'FnMember' | 'FinalModifiedMember':
					final name: Null<String> = child.name;
					if (name != null) {
						final entry: {
							node: QueryNode,
							dyn: Bool,
							isOverride: Bool,
							isInline: Bool
						} = {
							node: child,
							dyn: mods.contains('Dynamic'),
							isOverride: mods.contains('Override'),
							isInline: mods.contains('Inline')
						};
						if (StringTools.startsWith(name, 'get_'))
							getters[name] = entry;
						else if (StringTools.startsWith(name, 'set_'))
							setters[name] = entry;
					}
					mods = [];
				case _:
					mods.push(child.kind);
			}
		}
		return {
			privateFieldNodes: privateFieldNodes,
			getters: getters,
			setters: setters,
			properties: properties
		};
	}

	/** The offset of the property's accessor-clause `(` (right after `var <name>`), or -1 when there is none. */
	private static function accessorParenOpen(source: String, span: Span): Int {
		final afterName: Int = nameEndAfterVar(source, span);
		if (afterName < 0) return -1;
		final open: Int = skipSpace(source, afterName, source.length);
		return open < source.length && StringTools.fastCodeAt(source, open) == '('.code ? open : -1;
	}


	/**
	 * Whether `node` can BIND a name the grammar drops from the projection, and that
	 * hidden slot textually mentions `field` — the two blind spots of the by-name shadow
	 * refusal in `renameWalk`. A multi-variable local declaration (`var a = 1, _x = 2;`,
	 * detected by a top-level comma in its source) keeps only the FIRST name; a key-value
	 * `for (k => _x in m)` header keeps only the KEY name. In both, a shadowing `_x` is
	 * invisible as a node, so any word-match of `field` in the hidden region refuses the
	 * fix (conservative: a multi-var INIT reading the real field also refuses).
	 */
	private static function hidesBindingNamed(node: QueryNode, span: Null<Span>, source: String, field: String): Bool {
		switch node.kind {
			case 'VarStmt' | 'FinalStmt':
				if (span == null) return true;
				final declSource: String = source.substring(span.from, span.to);
				return RefactorSupport.hasTopLevelComma(declSource) && RefactorSupport.identTokenOffset(source, span, field) >= 0;
			case 'ForStmt':
				if (span == null || node.children.length == 0) return true;
				final iterSpan: Null<Span> = node.children[0].span;
				if (iterSpan == null) return true;
				return RefactorSupport.identTokenOffset(source, new Span(span.from, iterSpan.from), field) >= 0;
			case _:
				return false;
		}
	}


	/**
	 * The qualifier prefix for a shadowed backing-field write: the enclosing class name
	 * (`C.`) inside a static method — where `this` is illegal — else `this.` for an instance
	 * method. A `(default, null)` property is writable from within its own class, so
	 * `C.prop = value` is legal in a static method of `C`.
	 */
	private static inline function shadowQualifier(staticCtx: Bool, className: Null<String>): String {
		return staticCtx && className != null ? '$className.' : 'this.';
	}


	/**
	 * Classify one `(get, …)` property into a finding, or null to skip. Shared by
	 * `considerClass` (report) and `collectClassFixEdits` (fix) so the shape decision and the
	 * soundness gates live in ONE place. Shapes:
	 *
	 * - `(get, never)` / `(get, null)` with a trivial getter -> `(default, null)`.
	 * - `(get, set)`, trivial getter + NON-trivial setter -> shape A, decided three ways by the
	 *   external statement-level writes (see `classifySetProperty` / `collectExternalWrites`):
	 *   collapse to `(default, set)` (delete get, keep set) with 0 writes, collapse plus
	 *   `@:bypassAccessor` marks on 1..`maxBypass` writes (`bypassStmts`), or keep the property and
	 *   mark the getter `inline` (`inlineGetter`) beyond the cap / on a non-statement-level write.
	 *   Plus the constructor-init exception.
	 * - `(get, set)`, both trivial -> a plain field (delete both). No gate.
	 * - `(get, set)`, NON-trivial getter + trivial setter -> `(get, default)` (delete set, keep
	 *   get). Read-gated (see `hasExternalRead`): `(get, default)` has physical storage because the
	 *   `default` write forces it, so inside the kept getter the renamed property read is a DIRECT
	 *   physical read, but a backing-field read OUTSIDE the getter, once renamed, would newly route
	 *   through the non-trivial getter -- so the property is skipped if any read of the backing
	 *   field occurs outside `get_x`. Writes are direct (`default` write) and never gate.
	 *
	 * A `(get, set)` with both accessors non-trivial is skipped. The subclass gate is applied at the
	 * call site; the interface gate applies here to every COLLAPSING shape — the inline arm keeps
	 * `get_x`, so an interface-required accessor is never dropped and that gate does not block it.
	 */
	private static function classifyProperty(
		cls: QueryNode, source: String, index: Null<SymbolIndex>, prop: {
			name: String,
			node: QueryNode,
			span: Span,
			isPublic: Bool,
			write: String
		},
		getters: Map<String, {
			node: QueryNode,
			dyn: Bool,
			isOverride: Bool,
			isInline: Bool
		}>,
		setters: Map<String, {
			node: QueryNode,
			dyn: Bool,
			isOverride: Bool,
			isInline: Bool
		}>,
		privateFieldNodes: Map<String, QueryNode>, maxBypass: Int
	): Null<{
		field: String,
		fieldNode: QueryNode,
		message: String,
		clauseSpan: Span,
		clauseText: String,
		deletedAccessors: Array<QueryNode>,
		ctorInit: Null<{ stmt: QueryNode, rhsSpan: Span }>,
		bypassStmts: Array<QueryNode>,
		inlineGetter: Null<QueryNode>
	}> {
		final getter: Null<{
			node: QueryNode,
			dyn: Bool,
			isOverride: Bool,
			isInline: Bool
		}> = getters['get_${prop.name}'];
		if (getter == null || getter.dyn) return null;
		final trivGet: Null<String> = trivialReturnField(getter.node);
		final raw: Null<{
			field: String,
			clauseText: String,
			deleted: Array<QueryNode>,
			ctorInit: Null<{ stmt: QueryNode, rhsSpan: Span }>,
			message: String,
			bypassStmts: Array<QueryNode>,
			inlineGetter: Null<QueryNode>
		}> = if (prop.write == 'never' || prop.write == 'null')
			trivGet == null ? null : {
				field: trivGet,
				clauseText: '(default, null)',
				deleted: [getter.node],
				ctorInit: null,
				message: messageFor('nullcase', prop.name, trivGet),
				bypassStmts: [],
				inlineGetter: null
			}
		else if (prop.write == 'set')
			classifySetProperty(cls, prop, getter.node, getter.isInline, getter.isOverride, trivGet, setters, privateFieldNodes, maxBypass)
		else
			null;
		if (raw == null) return null;
		if (!privateFieldNodes.exists(raw.field)) return null;
		final fieldNode: Null<QueryNode> = privateFieldNodes[raw.field];
		if (fieldNode == null) return null;
		// The interface-conformance gate applies only to a COLLAPSING shape (the getter is dropped);
		// the inline arm keeps the getter, so a required interface accessor is never removed.
		if (raw.inlineGetter == null && interfaceRequiresGetter(cls, prop.name, prop.isPublic, index)) return null;
		final clauseSpan: Null<Span> = raw.clauseText == '' && raw.inlineGetter == null
			? clauseRemovalSpan(source, prop.span)
			: accessorParenSpan(source, prop.span);
		return clauseSpan == null ? null : {
			field: raw.field,
			fieldNode: fieldNode,
			message: raw.message,
			clauseSpan: clauseSpan,
			clauseText: raw.clauseText,
			deletedAccessors: raw.deleted,
			ctorInit: raw.ctorInit,
			bypassStmts: raw.bypassStmts,
			inlineGetter: raw.inlineGetter
		};
	}

	/**
	 * The report message for a finding `shape` (`nullcase` / `setA` / `setABypass` / `setAInline` /
	 * `setB` / `setC`). `count` is the external-write count the two write-aware shape-A arms report
	 * (`setABypass`: writes to mark `@:bypassAccessor`; `setAInline`: writes blocking the collapse);
	 * the other shapes ignore it.
	 */
	private static function messageFor(shape: String, propName: String, field: String, count: Int = 0): String {
		return switch shape {
			case 'setA': 'property \'$propName\' has a trivial getter over backing field \'$field\'; use \'var $propName(default, set)\' and remove get_$propName';
			case 'setABypass': 'property \'$propName\' has a trivial getter over backing field \'$field\'; use \'var $propName(default, set)\', remove get_$propName and mark $count external write(s) with @:bypassAccessor';
			case 'setAInline': 'property \'$propName\' has a trivial getter over backing field \'$field\', but $count external write(s) block a (default, set) collapse; mark get_$propName inline';
			case 'setB': 'property \'$propName\' has a trivial getter and setter over backing field \'$field\'; use a plain field \'var $propName\' and remove get_$propName/set_$propName';
			case 'setC': 'property \'$propName\' has a trivial setter over backing field \'$field\'; use \'var $propName(get, default)\' and remove set_$propName';
			case _: 'property \'$propName\' has a trivial getter returning backing field \'$field\'; use \'var $propName(default, null)\' and remove get_$propName';
		}
	}

	/**
	 * The backing-field name a setter trivially assigns — `_x` for a body of exactly `return _x =
	 * value;` / `return this._x = value;` (`value` = the setter's single parameter) — else null
	 * (any other body carries real logic).
	 */
	private static function trivialSetterField(setter: QueryNode): Null<String> {
		final paramName: Null<String> = setterParamName(setter);
		if (paramName == null) return null;
		final body: Null<QueryNode> = bodyOf(setter);
		if (body == null || body.children.length != 1) return null;
		final ret: QueryNode = body.children[0];
		final retKind: Null<String> = switch body.kind {
			case 'BlockBody': 'ReturnStmt';
			case 'ExprBody': 'ReturnExpr';
			case _: null;
		}
		if (retKind == null || ret.kind != retKind || ret.children.length != 1) return null;
		final assign: QueryNode = ret.children[0];
		if (assign.kind != 'Assign' || assign.children.length != 2) return null;
		final value: QueryNode = assign.children[1];
		return value.kind != 'IdentExpr' || value.name != paramName ? null : fieldRefName(assign.children[0]);
	}

	/** The name of a setter's single value parameter (its first `Required` / `Optional` child), or null. */
	private static function setterParamName(setter: QueryNode): Null<String> {
		final param: Null<QueryNode> = setter.children.find(c -> c.kind == 'Required' || c.kind == 'Optional');
		return param == null ? null : param.name;
	}

	/** The field name a node references as a bare `IdentExpr <name>` or `this.<name>` `FieldAccess`, else null. */
	private static function fieldRefName(node: QueryNode): Null<String> {
		return switch node.kind {
			case 'IdentExpr': node.name;
			case 'FieldAccess':
				node.children.length == 1 && node.children[0].kind == 'IdentExpr' && node.children[0].name == 'this' ? node.name : null;
			case _: null;
		}
	}

	/** The field targeted by an assignment / compound-assignment / incr / decr node (bare or `this.`), else null. */
	private static function writeTargetField(node: QueryNode): Null<String> {
		final isWrite: Bool = switch node.kind {
			case 'Assign' | 'AddAssign' | 'SubAssign' | 'MulAssign' | 'DivAssign' | 'ModAssign' | 'BitAndAssign' | 'BitOrAssign'
				| 'BitXorAssign'
				| 'ShlAssign'
				| 'ShrAssign'
				| 'UShrAssign'
				| 'PreIncr'
				| 'PostIncr'
				| 'PreDecr'
				| 'PostDecr': true;
			case _: false;
		}
		return isWrite && node.children.length >= 1 ? fieldRefName(node.children[0]) : null;
	}


	/**
	 * The one relocatable constructor-init write of `field` — a top-level `field = <literal>;` in
	 * the constructor's block body, where the literal is a compile-time constant, the write is
	 * the FIRST reference to `field` in the constructor (no earlier read to reorder past), and the
	 * backing field has no decl-initializer (checked by the caller). Its RHS is moved onto the
	 * `(default, set)` property (a physical init, sound) and the statement is deleted. Null when
	 * the first constructor reference to `field` is anything else.
	 */
	private static function findMovableCtorInit(
		cls: QueryNode, field: String
	): Null<{ stmt: QueryNode, assign: QueryNode, rhsSpan: Span }> {
		final ctor: Null<QueryNode> = cls.children.find(c -> (c.kind == 'FnMember' || c.kind == 'FinalModifiedMember') && c.name == 'new');
		if (ctor == null) return null;
		final body: Null<QueryNode> = bodyOf(ctor);
		if (body == null || body.kind != 'BlockBody') return null;
		final firstMention: Null<QueryNode> = body.children.find(stmt -> mentionsField(stmt, field));
		return firstMention == null ? null : movableInitOf(firstMention, field);
	}

	/** `stmt` as a movable ctor-init of `field` (`ExprStmt` of `field = <literal>`), else null. */
	private static function movableInitOf(stmt: QueryNode, field: String): Null<{ stmt: QueryNode, assign: QueryNode, rhsSpan: Span }> {
		if (stmt.kind != 'ExprStmt' || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != 'Assign' || assign.children.length != 2 || fieldRefName(assign.children[0]) != field) return null;
		final rhs: QueryNode = assign.children[1];
		if (!isMovableLiteral(rhs)) return null;
		final rhsSpan: Null<Span> = rhs.span;
		return rhsSpan == null ? null : { stmt: stmt, assign: assign, rhsSpan: rhsSpan };
	}

	/** Whether `node` is a compile-time literal safe to relocate to a field-initializer position. */
	private static function isMovableLiteral(node: QueryNode): Bool {
		return switch node.kind {
			case 'IntLit' | 'FloatLit' | 'BoolLit' | 'NullLit': true;
			case 'DoubleStringExpr': true;
			case 'SingleStringExpr':
				node.name != null && node.name.indexOf('$') == -1;
			case _: false;
		}
	}

	/** Whether `node`'s subtree references `field` (bare `IdentExpr` / `this.<field>`, read or write target). */
	private static function mentionsField(node: QueryNode, field: String): Bool {
		if (fieldRefName(node) == field) return true;
		for (child in node.children) if (mentionsField(child, field)) return true;
		return false;
	}

	/** Whether `span` is fully contained in any of `spans`. */
	private static inline function withinAny(spans: Array<Span>, span: Span): Bool {
		return spans.exists(s -> span.from >= s.from && span.to <= s.to);
	}

	/** The span to delete for a plain-field collapse — ` (read, write)` after `var <name>`, leading space included. */
	private static function clauseRemovalSpan(source: String, propSpan: Span): Null<Span> {
		final afterName: Int = nameEndAfterVar(source, propSpan);
		final paren: Null<Span> = accessorParenSpan(source, propSpan);
		return afterName < 0 || paren == null ? null : new Span(afterName, paren.to);
	}


	/**
	 * The `(get, set)` shape decision for `classifyProperty`, given the already-resolved getter
	 * node, its `inline` / `override` flags, and its trivial-field name (`trivGet`, null when the
	 * getter is non-trivial):
	 *
	 * - only the getter trivial -> shape A, three-way on the external statement-level writes
	 *   (`collectExternalWrites`, the movable constructor-init excluded): 0 writes -> `(default,
	 *   set)` collapse; 1..`maxBypass` writes -> the collapse plus `bypassStmts` (each marked
	 *   `@:bypassAccessor` by the fix); more than `maxBypass`, or any write NOT at statement level
	 *   -> `inlineGetter` (keep the property, mark `get_x` `inline`), skipped entirely when the
	 *   getter is already `inline` or carries `override`,
	 * - both accessors trivial over the same backing field -> shape B (plain field),
	 * - only the setter trivial -> shape C `(get, default)` (read-gated),
	 * - else null (both non-trivial).
	 */
	private static function classifySetProperty(
		cls: QueryNode, prop: {
			name: String,
			node: QueryNode,
			span: Span,
			isPublic: Bool,
			write: String
		},
		getterNode: QueryNode, getterInline: Bool, getterOverride: Bool, trivGet: Null<String>, setters: Map<String, {
			node: QueryNode,
			dyn: Bool,
			isOverride: Bool,
			isInline: Bool
		}>,
		privateFieldNodes: Map<String, QueryNode>, maxBypass: Int
	): Null<{
		field: String,
		clauseText: String,
		deleted: Array<QueryNode>,
		ctorInit: Null<{ stmt: QueryNode, rhsSpan: Span }>,
		message: String,
		bypassStmts: Array<QueryNode>,
		inlineGetter: Null<QueryNode>
	}> {
		final setter: Null<{
			node: QueryNode,
			dyn: Bool,
			isOverride: Bool,
			isInline: Bool
		}> = setters['set_${prop.name}'];
		if (setter == null || setter.dyn) return null;
		final trivSet: Null<String> = trivialSetterField(setter.node);
		if (trivGet != null && trivSet == null) {
			if (!privateFieldNodes.exists(trivGet)) return null;
			final fieldNode: Null<QueryNode> = privateFieldNodes[trivGet];
			final setterSpan: Null<Span> = setter.node.span;
			if (fieldNode == null || setterSpan == null) return null;
			final ci: Null<{ stmt: QueryNode, assign: QueryNode, rhsSpan: Span }> = fieldNode.children.length == 0
				? findMovableCtorInit(cls, trivGet)
				: null;
			final allowStmt: Null<QueryNode> = ci == null ? null : ci.stmt;
			final writes: Null<Array<QueryNode>> = collectExternalWrites(cls, trivGet, setterSpan, allowStmt);
			if (writes != null && writes.length <= maxBypass) return {
				field: trivGet,
				clauseText: '(default, set)',
				deleted: [getterNode],
				ctorInit: ci == null ? null : { stmt: ci.stmt, rhsSpan: ci.rhsSpan },
				message: writes.length == 0
					? messageFor('setA', prop.name, trivGet)
					: messageFor('setABypass', prop.name, trivGet, writes.length),
				bypassStmts: writes,
				inlineGetter: null
			};
			// Too many writes, or a write nested inside a larger expression (unmarkable): keep the
			// property and just inline the getter. Skip when the getter is already inline or overrides
			// — inline + override do not mix, and an overriding accessor must stay overridable.
			return getterInline || getterOverride ? null : {
				field: trivGet,
				clauseText: '',
				deleted: [],
				ctorInit: null,
				message: messageFor('setAInline', prop.name, trivGet, countExternalWrites(cls, trivGet, setterSpan, allowStmt)),
				bypassStmts: [],
				inlineGetter: getterNode
			};
		}
		if (trivGet != null && trivSet != null) {
			return trivGet != trivSet ? null : {
				field: trivGet,
				clauseText: '',
				deleted: [getterNode, setter.node],
				ctorInit: null,
				message: messageFor('setB', prop.name, trivGet),
				bypassStmts: [],
				inlineGetter: null
			};
		}
		if (trivGet == null && trivSet != null) {
			if (!privateFieldNodes.exists(trivSet)) return null;
			final getterSpan: Null<Span> = getterNode.span;
			return getterSpan == null
				? null
				: hasExternalRead(cls, trivSet, getterSpan) ? null : {
					field: trivSet,
					clauseText: '(get, default)',
					deleted: [setter.node],
					ctorInit: null,
					message: messageFor('setC', prop.name, trivSet),
					bypassStmts: [],
					inlineGetter: null
				};
		}
		return null;
	}


	/**
	 * Whether `node`'s subtree contains a READ of `field` outside `exclude` (the kept getter).
	 * After the `(get, set)` -> `(get, default)` collapse, reading the property routes through the
	 * non-trivial `get_field` EVERYWHERE except inside `get_field` itself (there the property is a
	 * direct physical read, since the `default` write forces physical storage), so a backing-field
	 * read outside the getter, once renamed to the property name, would newly route through the
	 * real getter -- a behavior change. Writes are direct (`default` write) and never gate.
	 *
	 * A bare `field` / `this.field` that is the TARGET of a plain `=` is a pure write, not a read,
	 * so its RHS is scanned but the target itself is not. A compound-assignment / incr / decr
	 * target IS a read (`x += 1` compiles to `x = get_x() + 1`), so it disqualifies. Every other
	 * `field` occurrence (RHS, call arg, `arr[field]` index, plain read) is a read.
	 */
	private static function hasExternalRead(node: QueryNode, field: String, exclude: Span): Bool {
		final span: Null<Span> = node.span;
		if (span != null && span.from >= exclude.from && span.to <= exclude.to) return false;
		if (node.kind == 'Plain') return false;
		if (writeTargetField(node) == field) {
			if (node.kind != 'Assign') return true;
			for (i in 1...node.children.length) if (hasExternalRead(node.children[i], field, exclude)) return true;
			return false;
		}
		if (fieldRefName(node) == field) return true;
		for (child in node.children) if (hasExternalRead(child, field, exclude)) return true;
		return false;
	}


	/**
	 * Prefix each statement-level bypass write in `bypassStmts` with `@:bypassAccessor ` — on the
	 * collapsed `(default, set)` property such a write is a DIRECT physical field write, so the
	 * marker preserves the pre-collapse semantics exactly. When a backing-field rename already
	 * replaces the statement's first token (a bare `_x` write target, at the same offset), the
	 * marker is FOLDED into that rename's replacement text instead of emitted as a separate
	 * zero-width edit — a zero-width insert coinciding with the rename's start is dropped by
	 * `dropContainedEdits`. A `this._x` write starts before its renamed name token, so its marker
	 * is a standalone insert. Returns false only on an unspanned statement the fix cannot place.
	 */
	private static function applyBypassMarks(bypassStmts: Array<QueryNode>, edits: Array<{ span: Span, text: String }>): Bool {
		for (stmt in bypassStmts) {
			final span: Null<Span> = stmt.span;
			if (span == null) return false;
			final at: Int = span.from;
			final folded: Null<{ span: Span, text: String }> = edits.find(e -> e.span.from == at && e.span.to > at);
			if (folded != null)
				folded.text = '@:bypassAccessor ${folded.text}';
			else
				edits.push({ span: new Span(at, at), text: '@:bypassAccessor ' });
		}
		return true;
	}

	/**
	 * The statement-level external writes to `field` in `node`'s subtree, outside `exclude` (the
	 * kept setter) and the `allowStmt` subtree (a relocatable constructor-init statement) — each an
	 * `ExprStmt` whose single child writes `field` (`writeTargetField`, bare or `this.`). Null the
	 * moment a write to `field` appears NOT in statement position (nested inside a larger
	 * expression, e.g. `if ((_x = v)) ...`): such a write cannot be marked `@:bypassAccessor`, so
	 * the caller must fall back to inlining the getter rather than collapsing.
	 */
	private static function collectExternalWrites(
		node: QueryNode, field: String, exclude: Span, allowStmt: Null<QueryNode>
	): Null<Array<QueryNode>> {
		final out: Array<QueryNode> = [];
		return collectExternalWritesInto(node, field, exclude, allowStmt, out) ? out : null;
	}

	/**
	 * Recursive worker of `collectExternalWrites`: appends each statement-level write of `field` to
	 * `out` and returns true, or returns false the moment a write to `field` sits in a non-statement
	 * position. A subtree inside `exclude` or equal to `allowStmt` is skipped. A statement-level
	 * write's own RHS is still scanned (its write target aside), so a nested write there is caught.
	 */
	private static function collectExternalWritesInto(
		node: QueryNode, field: String, exclude: Span, allowStmt: Null<QueryNode>, out: Array<QueryNode>
	): Bool {
		final span: Null<Span> = node.span;
		if (span != null && span.from >= exclude.from && span.to <= exclude.to) return true;
		if (node == allowStmt) return true;
		if (node.kind == 'ExprStmt' && node.children.length == 1 && writeTargetField(node.children[0]) == field) {
			out.push(node);
			for (c in node.children[0].children) if (!collectExternalWritesInto(c, field, exclude, allowStmt, out)) return false;
			return true;
		}
		if (writeTargetField(node) == field) return false;
		for (c in node.children) if (!collectExternalWritesInto(c, field, exclude, allowStmt, out)) return false;
		return true;
	}

	/**
	 * The total number of writes to `field` in `node`'s subtree, at ANY expression position, outside
	 * `exclude` and the `allowStmt` subtree — the count the inline-fallback message reports (the
	 * statement-level list of `collectExternalWrites` is null when it bails, so the message uses this
	 * position-agnostic count instead).
	 */
	private static function countExternalWrites(node: QueryNode, field: String, exclude: Span, allowStmt: Null<QueryNode>): Int {
		final span: Null<Span> = node.span;
		if (span != null && span.from >= exclude.from && span.to <= exclude.to) return 0;
		if (node == allowStmt) return 0;
		var n: Int = writeTargetField(node) == field ? 1 : 0;
		for (c in node.children) n += countExternalWrites(c, field, exclude, allowStmt);
		return n;
	}

}
