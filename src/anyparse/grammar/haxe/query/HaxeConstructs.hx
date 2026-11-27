package anyparse.grammar.haxe.query;

import anyparse.query.Constructs;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.ParseError;
import haxe.Exception;

using Lambda;

/** The text around a construct that makes it a whole file of the grammar. */
private typedef Host = { final before: String; final after: String; }

/**
 * The Haxe `Constructs`: each construct is one named template here, and each result is parsed back by the grammar inside a
 * host made for its kind and refused unless it parses to exactly the construct asked for: one node of the expected kind
 * covering the whole text, not a regrouping of its parts. A template the grammar rejects so fails a plugin test, never a
 * user's file.
 */
@:nullSafety(Strict)
final class HaxeConstructs implements Constructs {

	private static final CALL: Array<String> = ['Call'];
	private static final FIELD_ACCESS: Array<String> = ['FieldAccess'];
	private static final LAMBDA: Array<String> = ['ThinArrow', 'ThinParenLambdaExpr'];
	private static final RETURN: Array<String> = ['ReturnStmt'];
	private static final IMPORT: Array<String> = ['ImportDecl'];
	private static final USING: Array<String> = ['UsingDecl'];
	private static final CONSTANT: Array<String> = ['FinalMember'];
	private static final VARIABLE: Array<String> = ['VarMember'];
	private static final METHOD: Array<String> = ['FnMember'];

	private final _plugin: GrammarPlugin;

	public function new(plugin: GrammarPlugin) {
		_plugin = plugin;
	}

	public function copied(source: String, span: Span, kind: ConstructKind): Null<Built> {
		return whole(source.substring(span.from, span.to), kind);
	}

	public function substituted(source: String, span: Span, part: Span, by: Built, kind: ConstructKind): Null<Built> {
		return part.from < span.from || part.to > span.to
			? null
			: whole(source.substring(span.from, part.from) + by.text + source.substring(part.to, span.to), kind);
	}

	public function typeRef(spelled: String): Null<Built> {
		return whole(spelled, TypeExpr);
	}

	public function functionType(params: Array<Built>, result: Built): Null<Built> {
		return result.kind != TypeExpr || !params.foreach(param -> param.kind == TypeExpr)
			? null
			: whole('(${params.map(param -> param.text).join(', ')}) -> ${result.text}', TypeExpr);
	}

	public function qualified(owner: Built, name: String): Null<Built> {
		return switch owner.kind {
			case TypeExpr: rooted('${owner.text}.$name', Expression, FIELD_ACCESS);
			case Expression:
				rooted('${owner.text}.$name', Expression, FIELD_ACCESS) ?? rooted('(${owner.text}).$name', Expression, FIELD_ACCESS);
			case _: null;
		};
	}

	public function call(callee: Built, args: Array<Built>): Null<Built> {
		if (callee.kind != Expression || !args.foreach(arg -> arg.kind == Expression)) return null;
		final list: String = args.map(arg -> arg.text).join(', ');
		return rooted('${callee.text}($list)', Expression, CALL) ?? rooted('(${callee.text})($list)', Expression, CALL);
	}

	public function lambda(params: Array<String>, body: Built): Null<Built> {
		if (body.kind != Expression) return null;
		final head: String = params.length == 1 ? params[0] : '(${params.join(', ')})';
		return rooted('$head -> ${body.text}', Expression, LAMBDA);
	}

	public function returning(value: Built): Null<Built> {
		return value.kind == Expression ? rooted('return ${value.text};', Statement, RETURN) : null;
	}

	public function importOf(path: String): Null<Built> {
		return rooted('import $path;', Import, IMPORT);
	}

	public function usingOf(path: String): Null<Built> {
		return rooted('using $path;', Import, USING);
	}

	public function modifiers(set: Array<Modifier>): Null<Built> {
		final text: String = set.map(word).join(' ');
		final nodes: Null<Array<QueryNode>> = slot(text, ModifierSet);
		return nodes != null && set.length > 0 && nodes.length == set.length && nodes.foreach(isModifier)
			? new Built(text, ModifierSet)
			: null;
	}

	public function member(set: Array<Modifier>, kind: MemberKind, name: String, type: Null<Built>, value: Null<Built>): Null<Built> {
		if (type != null && type.kind != TypeExpr) return null;
		final prefix: String = set.map(modifier -> '${word(modifier)} ').join('');
		final typed: String = type == null ? '' : ': ${type.text}';
		return switch kind {
			case Constant, Variable:
				if (value != null && value.kind != Expression) return null;
				final init: String = value == null ? '' : ' = ${value.text}';
				kind == Constant
					? declared('${prefix}final $name$typed$init;', CONSTANT, set.length)
					: declared('${prefix}var $name$typed$init;', VARIABLE, set.length);
			case Method(params):
				if (value != null && value.kind != Statement) return null;
				if (!params.foreach(param -> param.type.kind == TypeExpr)) return null;
				final list: String = [ for (param in params) '${param.name}: ${param.type.text}' ].join(', ');
				declared('${prefix}function $name($list)$typed${value == null ? ';' : ' ${value.text}'}', METHOD, set.length);
		};
	}

	/** `text` as a construct of `kind` when it parses to exactly one: a type the grammar reads whole, else one node covering it. */
	private function whole(text: String, kind: ConstructKind): Null<Built> {
		if (kind == TypeExpr) return _plugin.typeSyntax(text) == null ? null : new Built(text, kind);
		final nodes: Null<Array<QueryNode>> = slot(text, kind);
		return nodes != null && nodes.length == 1 ? new Built(text, kind) : null;
	}

	/** `text` as a construct of `kind` when it parses to ONE node of `kinds` covering it, not to a regrouping of its parts. */
	private function rooted(text: String, kind: ConstructKind, kinds: Array<String>): Null<Built> {
		final nodes: Null<Array<QueryNode>> = slot(text, kind);
		return nodes != null && nodes.length == 1 && kinds.contains(nodes[0].kind) ? new Built(text, kind) : null;
	}

	/** `text` as a member of `kinds` carrying `modifiers` modifiers when it parses to exactly that. */
	private function declared(text: String, kinds: Array<String>, modifiers: Int): Null<Built> {
		final nodes: Null<Array<QueryNode>> = slot(text, Member);
		if (nodes == null || nodes.length != modifiers + 1 || !kinds.contains(nodes[modifiers].kind)) return null;
		for (i in 0...modifiers) if (!isModifier(nodes[i])) return null;
		return new Built(text, Member);
	}

	private function isModifier(node: QueryNode): Bool {
		return _plugin.refShape().modifierKinds?.contains(node.kind) == true;
	}

	/**
	 * The nodes `text` parses to inside a host for `kind`, when they cover it exactly: the outermost node spanning it alone,
	 * else the children of the deepest node holding it — null when the host does not parse or a node crosses its edge.
	 */
	private function slot(text: String, kind: ConstructKind): Null<Array<QueryNode>> {
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

	private static inline function startOf(node: QueryNode): Int {
		return node.span?.from ?? -1;
	}

	private static inline function endOf(node: QueryNode): Int {
		return node.span?.to ?? -1;
	}

	/** `modifier` as Haxe spells it. */
	private static function word(modifier: Modifier): String {
		return switch modifier {
			case Public: 'public';
			case Private: 'private';
			case Static: 'static';
			case Inline: 'inline';
			case Override: 'override';
		};
	}

	/** The text around a construct of `kind` that makes it a whole file. */
	private static function hostOf(kind: ConstructKind): Host {
		return switch kind {
			case Expression: { before: 'class _C { static final _v = ', after: '; }' };
			case Statement: { before: 'class _C { static function _f() { ', after: ' } }' };
			case Member: { before: 'class _C { ', after: ' }' };
			case ModifierSet: { before: 'class _C { ', after: ' var _v; }' };
			case Import, TypeExpr: { before: '', after: '' };
		};
	}

	private static function spans(node: QueryNode, from: Int, to: Int): Bool {
		return startOf(node) == from && endOf(node) == to;
	}

}
