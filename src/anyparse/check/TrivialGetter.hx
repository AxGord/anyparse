package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

import anyparse.query.RefactorSupport;

/**
 * Flags a read-only property whose getter does nothing but return a private
 * backing field of the same class — `public var x(get, never):T` (or `(get,
 * null)`) paired with `private var _x:T` and `function get_x() return _x;`.
 * The user's rule: don't write a trivial getter that only returns a backing
 * field, use property access instead (`public var x(default, null):T = …`).
 * `Severity.Info`, with an autofix that renames the backing field into the
 * property within the class and deletes the getter —
 * airtight only when every backing-field reference is a bare or this. access (other shapes stay report-only).
 *
 * ## What counts as trivial
 *
 * The `get_x` body must be EXACTLY a single `return <field>;` — either `return
 * _x;` (`IdentExpr`) or `return this._x;` (`FieldAccess` on `this`) — where
 * `<field>` is a PRIVATE field declared in the same class body. A block body
 * with any other statement, or a return of a call / literal / different
 * receiver, is real logic and left alone.
 *
 * ## Soundness gates (a miss over a wrong flag)
 *
 * 1. The read accessor is exactly `get` — a custom-named `(myGet, never)` or a
 *    plain stored read is skipped, since only the standard `get_` getter
 *    resolves.
 * 2. The write accessor is `never` or `null` — a custom `set` (or `default`)
 *    means the write slot carries real behaviour, so it is skipped.
 * 3. The getter is not `dynamic` (re-bindable at runtime — real behaviour).
 * 4. The backing field is private and declared in the SAME class — an
 *    inherited / public / cross-class field cannot be collapsed into
 *    `(default, null)` and is skipped. Interfaces (no getter bodies) are
 *    skipped wholesale: only `ClassDecl` / `ClassForm` bodies are inspected.
 *
 * 5. The declaring class has NO subtype in the index (`SymbolIndex.hasSubtype`)
 *    — a subclass could `override get_x`, so the suggested `(default, null)` +
 *    drop-getter refactor would break the override. A class with any subtype is
 *    skipped wholesale; the subtype set is complete only over a whole-project
 *    scope (like `prefer-final-public-field`).
 *
 * Internal writes to the backing field from other methods are FINE — that is
 * exactly what `(default, null)` preserves — so no write gate is needed.
 */
@:nullSafety(Strict)
final class TrivialGetter implements Check {

	public function new() {}

	public function id(): String {
		return 'trivial-getter';
	}

	public function description(): String {
		return 'a (get, never)/(get, null) property whose getter only returns a private backing field — use (default, null)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) for (cls in classes(tree)) considerClass(out, cls, entry.source, entry.file, index);
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
	 * shadows the name (including the grammar-dropped multi-var and key-value-for binding
	 * slots), or a case-pattern mention of it, all leave the finding report-only. NOTE:
	 * a null `index` skips the subclass-override gate — the production `lint --fix` caller
	 * always passes one; a direct caller without an index must ensure no subtype overrides
	 * the getter.
	 *
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) wanted.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (cls in classes(tree)) collectClassFixEdits(cls, source, wanted, index, edits);
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
	 * Flag each read-only property of `cls` whose `get_x` trivially returns a private
	 * same-class backing field, using the shared `memberTables`. A class with any subtype in
	 * the index is skipped — a subclass could override `get_x`, so the suggested rewrite
	 * would break that override.
	 */
	private static function considerClass(out: Array<Violation>, cls: QueryNode, source: String, file: String, index: SymbolIndex): Void {
		final className: Null<String> = cls.name;
		if (className == null || index.hasSubtype(className)) return;
		final t = memberTables(cls, source);
		for (prop in t.properties) {
			final r = resolvedGetterField(t.getters, prop.name);
			if (r == null || !t.privateFieldNodes.exists(r.field)) continue;
			out.push({
				file: file,
				span: prop.span,
				rule: 'trivial-getter',
				severity: Severity.Info,
				message: 'property \'${prop.name}\' has a trivial getter returning backing field \'${r.field}\'; use \'var ${prop.name}(default, null)\' and remove get_${prop.name}'
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
		if (ret.kind != returnKind || ret.children.length != 1) return null;
		final value: QueryNode = ret.children[0];
		return switch value.kind {
			case 'IdentExpr': value.name;
			case 'FieldAccess':
				value.children.length == 1 && value.children[0].kind == 'IdentExpr' && value.children[0].name == 'this' ? value.name : null;
			case _: null;
		}
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
	 * Collect the rewrite edits for every wanted trivial-getter property of `cls`, using the
	 * shared `memberTables` for the property / backing-field / getter nodes, and skipping a
	 * class with any subtype (a subclass override).
	 */
	private static function collectClassFixEdits(
		cls: QueryNode, source: String, wanted: Array<String>, index: Null<SymbolIndex>, out: Array<{ span: Span, text: String }>
	): Void {
		final className: Null<String> = cls.name;
		if (className == null || (index != null && index.hasSubtype(className))) return;
		final t = memberTables(cls, source);
		for (prop in t.properties) if (wanted.contains('${prop.span.from}:${prop.span.to}')) {
			final r = resolvedGetterField(t.getters, prop.name);
			if (r == null) continue;
			final fieldNode: Null<QueryNode> = t.privateFieldNodes[r.field];
			if (fieldNode == null) continue;
			final e: Null<Array<{ span: Span, text: String }>> = buildGetterFix(
				cls, source, prop.span, fieldNode, r.getterNode, r.field, prop.name
			);
			if (e != null) for (edit in e) out.push(edit);
		}
	}

	/**
	 * The edits converting one trivial getter: accessor → `(default, null)`, backing init
	 * moved onto the property, getter + backing field deleted, references renamed. Null when
	 * the accessor / semicolon cannot be located or the reference rename is not provably safe.
	 */
	private static function buildGetterFix(
		cls: QueryNode, source: String, propSpan: Span, fieldNode: QueryNode, getterNode: QueryNode, field: String, propName: String
	): Null<Array<{ span: Span, text: String }>> {
		final paren: Null<Span> = accessorParenSpan(source, propSpan);
		if (paren == null) return null;
		final edits: Array<{ span: Span, text: String }> = [{ span: paren, text: '(default, null)' }];
		if (fieldNode.children.length >= 1) {
			final initSpan: Null<Span> = fieldNode.children[0].span;
			if (initSpan != null) {
				final semi: Int = propSpan.to - 1;
				if (semi < 0 || semi >= source.length || StringTools.fastCodeAt(source, semi) != ';'.code) return null;
				edits.push({ span: new Span(semi, semi), text: ' = ' + source.substring(initSpan.from, initSpan.to) });
			}
		}
		final getterSpan: Null<Span> = getterNode.span;
		final fieldSpan: Null<Span> = fieldNode.span;
		if (getterSpan == null || fieldSpan == null) return null;
		final renames: Null<Array<{ span: Span, text: String }>> = collectRenameEdits(cls, source, field, getterSpan, fieldNode, propName);
		if (renames == null) return null;
		for (e in renames) edits.push(e);
		edits.push(
			{ span: RefactorSupport.lineExtendedSpan(source, RefactorSupport.declGroupSpan(getterNode, cls, getterSpan)), text: '' }
		);
		edits.push({ span: RefactorSupport.lineExtendedSpan(source, RefactorSupport.declGroupSpan(fieldNode, cls, fieldSpan)), text: '' });
		return edits;
	}

	/** The rename edits for every backing-field reference in `cls`, or null when any reference is not provably the field. */
	private static function collectRenameEdits(
		cls: QueryNode, source: String, field: String, getterSpan: Span, fieldNode: QueryNode, propName: String
	): Null<Array<{ span: Span, text: String }>> {
		final edits: Array<{ span: Span, text: String }> = [];
		return renameWalk(cls, source, field, getterSpan, fieldNode, propName, false, edits) ? edits : null;
	}

	/**
	 * Walk `node`, collecting `_field → propName` rename edits; returns false (refuse the whole
	 * fix) on any reference that is not provably the field — a `<other>.<field>` access, a
	 * binding that shadows the name, a case-pattern mention, or a construct whose dropped
	 * binding slot could hide a shadow (`hidesBindingNamed`). The backing field decl and the
	 * getter subtree (both deleted) are skipped. `inPattern` marks a case-pattern subtree.
	 *
	 */
	private static function renameWalk(
		node: QueryNode, source: String, field: String, getterSpan: Span, fieldNode: QueryNode, propName: String, inPattern: Bool,
		out: Array<{ span: Span, text: String }>
	): Bool {
		if (node == fieldNode) return true;
		final span: Null<Span> = node.span;
		if (span != null && span.from >= getterSpan.from && span.to <= getterSpan.to) return true;
		if (hidesBindingNamed(node, span, source, field)) return false;
		final nowPattern: Bool = inPattern || node.kind == 'Plain';
		if (node.name == field) {
			if (nowPattern) return false;
			switch node.kind {
				case 'IdentExpr':
					if (span != null) out.push({ span: span, text: propName });
				case 'FieldAccess':
					if (
						span == null || node.children.length != 1 || node.children[0].kind != 'IdentExpr' || node.children[0].name != 'this'
					)
						return false;
					final off: Int = RefactorSupport.identTokenOffset(source, span, field);
					if (off < 0) return false;
					out.push({ span: new Span(off, off + field.length), text: propName });
				case _:
					return false;
			}
		}
		for (c in node.children) if (!renameWalk(c, source, field, getterSpan, fieldNode, propName, nowPattern, out)) return false;
		return true;
	}

	/** The `(read, write)` accessor-clause span `[open, close]` of a property (`span.from` at `var`), or null. */
	private static function accessorParenSpan(source: String, propSpan: Span): Null<Span> {
		final open: Int = accessorParenOpen(source, propSpan);
		if (open < 0) return null;
		var i: Int = open + 1;
		while (i < source.length && StringTools.fastCodeAt(source, i) != ')'.code) i++;
		return i >= source.length ? null : new Span(open, i + 1);
	}


	/** The trivially-returned backing-field name and getter node for `propName`, or null when the getter is missing, `dynamic`, or non-trivial. */
	private static function resolvedGetterField(
		getters: Map<String, { node: QueryNode, dyn: Bool }>, propName: String
	): Null<{ field: String, getterNode: QueryNode }> {
		final getter: Null<{ node: QueryNode, dyn: Bool }> = getters['get_' + propName];
		if (getter == null || getter.dyn) return null;
		final field: Null<String> = trivialReturnField(getter.node);
		return field == null ? null : { field: field, getterNode: getter.node };
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
	 * Build the member tables of `cls` shared by `considerClass` (report) and
	 * `collectClassFixEdits` (fix): private field nodes by name, `get_` getters by name (with
	 * their `dynamic` flag), and the `(get, never)` / `(get, null)` read-only properties.
	 */
	private static function memberTables(cls: QueryNode, source: String): {
		privateFieldNodes: Map<String, QueryNode>,
		getters: Map<String, { node: QueryNode, dyn: Bool }>,
		properties: Array<{ name: String, node: QueryNode, span: Span }>
	} {
		final privateFieldNodes: Map<String, QueryNode> = [];
		final getters: Map<String, { node: QueryNode, dyn: Bool }> = [];
		final properties: Array<{ name: String, node: QueryNode, span: Span }> = [];
		var mods: Array<String> = [];
		for (child in cls.children) {
			switch child.kind {
				case 'VarMember' | 'FinalMember':
					final name: Null<String> = child.name;
					final span: Null<Span> = child.span;
					if (name != null && span != null) {
						if (!mods.contains('Public')) privateFieldNodes[name] = child;
						if (child.kind == 'VarMember') {
							final access: Null<{ read: String, write: String }> = accessorClause(source, span);
							if (access != null && access.read == 'get' && (access.write == 'never' || access.write == 'null'))
								properties.push({ name: name, node: child, span: span });
						}
					}
					mods = [];
				case 'FnMember' | 'FinalModifiedMember':
					final name: Null<String> = child.name;
					if (name != null && StringTools.startsWith(name, 'get_'))
						getters[name] = { node: child, dyn: mods.contains('Dynamic') };
					mods = [];
				case _:
					mods.push(child.kind);
			}
		}
		return { privateFieldNodes: privateFieldNodes, getters: getters, properties: properties };
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

}
