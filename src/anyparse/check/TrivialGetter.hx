package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * Flags a read-only property whose getter does nothing but return a private
 * backing field of the same class — `public var x(get, never):T` (or `(get,
 * null)`) paired with `private var _x:T` and `function get_x() return _x;`.
 * The user's rule: don't write a trivial getter that only returns a backing
 * field, use property access instead (`public var x(default, null):T = …`).
 * `Severity.Info`, REPORT-ONLY: the fix renames the backing field into the
 * property across the class (and any file reading it) and deletes the getter —
 * a refactoring beyond a lint's span edit.
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
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree != null) for (cls in classes(tree)) considerClass(out, cls, entry.source, entry.file);
		}
		return out;
	}

	/** Report-only: the backing-field-into-property rewrite is beyond a span edit. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
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
	 * Flag each read-only property of `cls` whose `get_x` trivially returns a
	 * private same-class backing field. One pass builds the member tables —
	 * visibility and `dynamic` come from the modifier siblings that precede each
	 * member — then each property is matched against its getter.
	 */
	private static function considerClass(out: Array<Violation>, cls: QueryNode, source: String, file: String): Void {
		final privateFields: Array<String> = [];
		final getters: Map<String, { node: QueryNode, dyn: Bool }> = [];
		final properties: Array<{ name: String, span: Span }> = [];
		var mods: Array<String> = [];
		for (child in cls.children) {
			switch child.kind {
				case 'VarMember' | 'FinalMember':
					final name: Null<String> = child.name;
					final span: Null<Span> = child.span;
					if (name != null) {
						if (!mods.contains('Public')) privateFields.push(name);
						if (child.kind == 'VarMember' && span != null) {
							final access: Null<{ read: String, write: String }> = accessorClause(source, span);
							if (access != null && access.read == 'get' && (access.write == 'never' || access.write == 'null'))
								properties.push({ name: name, span: span });
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
		for (prop in properties) {
			final getter: Null<{ node: QueryNode, dyn: Bool }> = getters['get_' + prop.name];
			if (getter == null || getter.dyn) continue;
			final field: Null<String> = trivialReturnField(getter.node);
			if (field == null || !privateFields.contains(field)) continue;
			out.push({
				file: file,
				span: prop.span,
				rule: 'trivial-getter',
				severity: Severity.Info,
				message: 'property \'${prop.name}\' has a trivial getter returning backing field \'$field\'; use \'var ${prop.name}(default, null)\' and remove get_${prop.name}'
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
	 * The two accessor identifiers of a property's `(read, write)` clause, read
	 * from the source right after the field name — or null when the member is a
	 * plain field (no `(` clause) or the clause is malformed. `span.from` is at
	 * the `var` keyword (the modifier siblings project as separate nodes).
	 */
	private static function accessorClause(source: String, span: Span): Null<{ read: String, write: String }> {
		final n: Int = source.length;
		final kw: String = 'var';
		if (span.from + kw.length > n || source.substring(span.from, span.from + kw.length) != kw) return null;
		var i: Int = skipSpace(source, span.from + kw.length, n);
		final nameStart: Int = i;
		while (i < n && isIdentChar(StringTools.fastCodeAt(source, i))) i++;
		if (i == nameStart) return null;
		i = skipSpace(source, i, n);
		if (i >= n || StringTools.fastCodeAt(source, i) != '('.code) return null;
		final read: Null<{ id: String, next: Int }> = identAt(source, skipSpace(source, i + 1, n), n);
		if (read == null) return null;
		i = skipSpace(source, read.next, n);
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

}
