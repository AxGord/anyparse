package anyparse.grammar.haxe.query;

import anyparse.query.Constructs;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.ParseError;
import haxe.Exception;

using StringTools;
using Lambda;

/** The text around a construct that makes it a whole file of the grammar. */
private typedef Host = { final before: String; final after: String; }
/**
 * The parse-back check of a Haxe construct a `HaxeConstructs` method built: the one answer to "does this text parse back
 * to exactly the Haxe construct asked for". The text is parsed by the grammar inside a host made for its kind and refused
 * unless it parses to one node of the expected kind covering the whole text, not a regrouping of its parts; the kind lists
 * here name the node each construct projects as.
 */
@:nullSafety(Strict)
final class HaxeParseBack {

	public static final CALL: Array<String> = ['Call'];
	public static final FIELD_ACCESS: Array<String> = ['FieldAccess'];
	public static final LAMBDA: Array<String> = ['ThinArrow', 'ThinParenLambdaExpr'];
	public static final RETURN: Array<String> = ['ReturnStmt'];
	public static final IMPORT: Array<String> = ['ImportDecl', 'ImportWildDecl', 'ImportAliasDecl', 'ImportAliasInDecl'];
	public static final USING: Array<String> = ['UsingDecl'];
	public static final CONSTANT: Array<String> = ['FinalMember'];
	public static final VARIABLE: Array<String> = ['VarMember'];
	public static final METHOD: Array<String> = ['FnMember'];
	public static final VOID_RETURN: Array<String> = ['VoidReturnStmt'];
	public static final CONTINUE: Array<String> = ['ContinueStmt'];
	public static final IF: Array<String> = ['IfStmt'];
	public static final FOR: Array<String> = ['ForStmt'];
	public static final BLOCK: Array<String> = ['BlockStmt'];
	public static final EXPRESSION_STATEMENT: Array<String> = ['ExprStmt'];
	public static final ASSIGN: Array<String> = ['Assign'];
	public static final COMPOUND_ASSIGN: Array<String> = ['AddAssign', 'SubAssign', 'MulAssign', 'DivAssign', 'ModAssign'];
	public static final LOCAL_CONSTANT: Array<String> = ['FinalStmt'];
	public static final LOCAL_VARIABLE: Array<String> = ['VarStmt'];
	public static final NAME: Array<String> = ['IdentExpr'];
	public static final INTERVAL: Array<String> = ['Interval'];
	public static final ARRAY: Array<String> = ['ArrayExpr'];
	public static final BOOLEAN: Array<String> = ['BoolLit'];

	private final _plugin: GrammarPlugin;

	public function new(plugin: GrammarPlugin) {
		_plugin = plugin;
	}

	/** `text` as a construct of `kind` when it parses to exactly one: a type the grammar reads whole, else one node covering it. */
	public function whole(text: String, kind: ConstructKind): Null<Built> {
		if (kind == TypeExpr) return _plugin.typeSyntax(text) == null ? null : new Built(text, kind);
		if (kind == Statements) {
			final run: String = text.rtrim();
			return run.trim() != '' && HaxeNodes.countOf(run) != null ? new Built(run, kind) : null;
		}
		final nodes: Null<Array<QueryNode>> = slot(text, kind);
		return nodes != null && nodes.length == 1 ? new Built(text, kind) : null;
	}

	/** `text` as a construct of `kind` when it parses to ONE node of `kinds` covering it, not to a regrouping of its parts. */
	public function rooted(text: String, kind: ConstructKind, kinds: Array<String>): Null<Built> {
		final nodes: Null<Array<QueryNode>> = slot(text, kind);
		return nodes != null && nodes.length == 1 && kinds.contains(nodes[0].kind) ? new Built(text, kind) : null;
	}

	/** `text` as a member of `kinds` carrying `modifiers` modifiers when it parses to exactly that. */
	public function declared(text: String, kinds: Array<String>, modifiers: Int): Null<Built> {
		final nodes: Null<Array<QueryNode>> = slot(text, Member);
		if (nodes == null || nodes.length != modifiers + 1 || !kinds.contains(nodes[modifiers].kind)) return null;
		for (i in 0...modifiers) if (!isModifier(nodes[i])) return null;
		return new Built(text, Member);
	}

	public function isModifier(node: QueryNode): Bool {
		return _plugin.refShape().modifierKinds?.contains(node.kind) == true;
	}

	/**
	 * The nodes `text` parses to inside a host for `kind`, when they cover it exactly: the outermost node spanning it alone,
	 * else the children of the deepest node holding it — null when the host does not parse or a node crosses its edge.
	 */
	public function slot(text: String, kind: ConstructKind): Null<Array<QueryNode>> {
		final host: Host = hostOf(kind);
		final tree: QueryNode = try
			_plugin.parseFile(host.before + text + host.after)
		catch (exception: ParseError)
			return null
		catch (exception: Exception)
			return null;
		final from: Int = host.before.length;
		final to: Int = from + text.length;
		var holder: QueryNode = tree;
		while (true) {
			final next: Null<QueryNode> = holder.children.find(child -> startOf(child) <= from && endOf(child) >= to);
			if (next == null) break;
			if (spans(next, from, to)) return [next];
			holder = next;
		}
		final inside: Array<QueryNode> = holder.children.filter(child -> endOf(child) > from && startOf(child) < to);
		return inside.length != 0
			&& inside.foreach(child -> startOf(child) >= from && endOf(child) <= to)
			&& (startOf(inside[0]) == from && endOf(inside[inside.length - 1]) == to)
			? inside
			: null;
	}

	/** The first keyword or delimiter the one node `text` parses to matched, as `text` spells it; null when there is none. */
	public function opening(text: String, kind: ConstructKind): Null<String> {
		final nodes: Null<Array<QueryNode>> = slot(text, kind);
		final tokens: Array<Span> = nodes != null && nodes.length == 1 ? nodes[0].tokenSpans() : [];
		final offset: Int = hostOf(kind).before.length;
		return tokens.length == 0 ? null : text.substring(tokens[0].from - offset, tokens[0].to - offset);
	}

	/** Where the last identifier `name` stands in `text`, a `kind` that parses; null when `text` does not parse or holds none. */
	public function nameSpan(text: String, kind: ConstructKind, name: String): Null<Span> {
		final nodes: Null<Array<QueryNode>> = slot(text, kind);
		final found: Null<Span> = nodes == null ? null : lastNamed(nodes, name);
		final offset: Int = hostOf(kind).before.length;
		return found == null ? null : new Span(found.from - offset, found.to - offset);
	}

	private static inline function startOf(node: QueryNode): Int {
		return node.span?.from ?? -1;
	}

	private static inline function endOf(node: QueryNode): Int {
		return node.span?.to ?? -1;
	}

	/** The text around a construct of `kind` that makes it a whole file. */
	private static function hostOf(kind: ConstructKind): Host {
		return switch kind {
			case Expression: { before: 'class _C { static final _v = ', after: '; }' };
			case Statement, Statements: { before: 'class _C { static function _f() { ', after: ' } }' };
			case Member: { before: 'class _C { ', after: ' }' };
			case ModifierSet: { before: 'class _C { ', after: ' var _v; }' };
			case Import, TypeExpr: { before: '', after: '' };
		};
	}

	private static function spans(node: QueryNode, from: Int, to: Int): Bool {
		return startOf(node) == from && endOf(node) == to;
	}

	/** The span of the last node of `nodes`, or beneath them, that is the identifier `name`, in document order. */
	private static function lastNamed(nodes: Array<QueryNode>, name: String): Null<Span> {
		var found: Null<Span> = null;
		for (node in nodes) {
			final inner: Null<Span> = lastNamed(node.children, name);
			if (inner != null)
				found = inner;
			else if (NAME.contains(node.kind) && node.name == name)
				found = node.span;
		}
		return found;
	}

}
