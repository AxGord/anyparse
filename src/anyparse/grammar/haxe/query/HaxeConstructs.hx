package anyparse.grammar.haxe.query;

import anyparse.check.Check.FixEdit;
import anyparse.grammar.haxe.trivia.Pairs.HxClassMemberT;
import anyparse.grammar.haxe.trivia.Pairs.HxExprT;
import anyparse.grammar.haxe.trivia.Pairs.HxFnBodyT;
import anyparse.grammar.haxe.trivia.Pairs.HxStatementT;
import anyparse.grammar.haxe.trivia.Pairs.HxTypeT;
import anyparse.query.Constructs;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;

using StringTools;
using Lambda;

/**
 * The Haxe `Constructs`: a member, a statement and a literal built of parts are typed nodes (`HaxeNodes`) spelled by the
 * generated writer's per-type entries; a call, a lambda, a qualified name, a function type and an import are still one named
 * template here. Each result is parsed back (`HaxeParseBack`) and refused unless it reads as exactly the construct asked for.
 */
@:nullSafety(Strict)
final class HaxeConstructs implements Constructs {

	/** What stands between the parts of a run that do not open on a layout of their own. */
	private static final LINE_BREAK: String = '\n';

	/** The keyword that opens a variable declaration, and the one a constant declaration opens with. */
	private static final VARIABLE_WORD: String = 'var';

	private static final CONSTANT_WORD: String = 'final';

	private final _plugin: GrammarPlugin;
	private final _parseBack: HaxeParseBack;

	public function new(plugin: GrammarPlugin) {
		_plugin = plugin;
		_parseBack = new HaxeParseBack(plugin);
	}

	public function copied(source: String, span: Span, kind: ConstructKind): Null<Built> {
		return _parseBack.whole(source.substring(span.from, span.to), kind);
	}

	public function substituted(source: String, span: Span, part: Span, by: Built, kind: ConstructKind): Null<Built> {
		return part.from < span.from || part.to > span.to
			? null
			: _parseBack.whole(source.substring(span.from, part.from) + by.text + source.substring(part.to, span.to), kind);
	}

	public function typeRef(spelled: String): Null<Built> {
		return _parseBack.whole(spelled, TypeExpr);
	}

	public function functionType(params: Array<Built>, result: Built): Null<Built> {
		return result.kind != TypeExpr || !params.foreach(param -> param.kind == TypeExpr)
			? null
			: _parseBack.whole('(${params.map(param -> param.text).join(', ')}) -> ${result.text}', TypeExpr);
	}

	public function qualified(owner: Built, name: String): Null<Built> {
		return switch owner.kind {
			case TypeExpr: _parseBack.rooted('${owner.text}.$name', Expression, HaxeParseBack.FIELD_ACCESS);
			case Expression:
				_parseBack.rooted('${owner.text}.$name', Expression, HaxeParseBack.FIELD_ACCESS) ?? _parseBack.rooted(
					'(${owner.text}).$name', Expression, HaxeParseBack.FIELD_ACCESS
				);
			case _: null;
		};
	}

	public function call(callee: Built, args: Array<Built>): Null<Built> {
		if (callee.kind != Expression || !args.foreach(arg -> arg.kind == Expression)) return null;
		final list: String = args.map(arg -> arg.text).join(', ');
		return _parseBack.rooted('${callee.text}($list)', Expression, HaxeParseBack.CALL) ?? _parseBack.rooted(
			'(${callee.text})($list)', Expression, HaxeParseBack.CALL
		);
	}

	public function lambda(params: Array<String>, body: Built): Null<Built> {
		if (body.kind != Expression) return null;
		final head: String = params.length == 1 ? params[0] : '(${params.join(', ')})';
		return _parseBack.rooted('$head -> ${body.text}', Expression, HaxeParseBack.LAMBDA);
	}

	public function returning(value: Built): Null<Built> {
		final expr: Null<HxExprT> = value.kind == Expression ? HaxeNodes.valueOf(value.text) : null;
		return expr == null
			? null
			: _parseBack.rooted(HaxeModuleTriviaWriter.writeHxStatementNode(HaxeNodes.returnStmt(expr)), Statement, HaxeParseBack.RETURN);
	}

	public function returningNothing(): Null<Built> {
		return statement(HaxeNodes.voidReturnStmt(), HaxeParseBack.VOID_RETURN);
	}

	public function continuing(): Null<Built> {
		return statement(HaxeNodes.continueStmt(), HaxeParseBack.CONTINUE);
	}

	public function guard(condition: Built, exit: Built): Null<Built> {
		final node: Null<HxStatementT> = statementOf(exit);
		final exits: Null<Array<QueryNode>> = node == null ? null : _parseBack.slot(exit.text, Statement);
		final flow: Null<ControlFlowSupport> = _plugin.controlFlowSupport();
		final leaves: Bool = exits != null && exits.length == 1 && flow != null && flow.isTerminal(exits[0]);
		return node != null && leaves ? conditionalOf(condition, node) : null;
	}

	public function conditional(condition: Built, body: Built): Null<Built> {
		final node: Null<HxStatementT> = statementOf(body);
		return node == null ? null : conditionalOf(condition, node);
	}

	public function assignment(target: Built, value: Built): Null<Built> {
		return assigned(target, null, value, HaxeParseBack.ASSIGN);
	}

	public function compoundAssignment(target: Built, op: Arithmetic, value: Built): Null<Built> {
		return assigned(target, op, value, HaxeParseBack.COMPOUND_ASSIGN);
	}

	public function local(kind: MemberKind, name: String, type: Null<Built>, value: Null<Built>): Null<Built> {
		final constant: Bool = switch kind {
			case Constant: true;
			case Variable: false;
			case Method(_): return null;
		};
		final typeNode: Null<HxTypeT> = type == null || type.kind != TypeExpr ? null : HaxeNodes.typeOf(type.text);
		if (type != null && typeNode == null) return null;
		final init: Null<HxExprT> = value == null ? null : expression(value);
		return value != null && init == null
			? null
			: statement(
				HaxeNodes.localDecl(constant, name, typeNode, init), constant ? HaxeParseBack.LOCAL_CONSTANT : HaxeParseBack.LOCAL_VARIABLE
			);
	}

	public function forEach(binder: String, iterable: Built, body: Built): Null<Built> {
		return looped(binder, null, iterable, body);
	}

	public function forEachPair(key: String, value: String, iterable: Built, body: Built): Null<Built> {
		return isName(value) ? looped(key, value, iterable, body) : null;
	}

	public function block(parts: Array<Built>): Null<Built> {
		final runs: Array<HxStatementT> = [];
		for (part in parts) {
			final run: Null<HxStatementT> = runOf(part);
			if (run == null) return null;
			runs.push(run);
		}
		final node: Null<HxStatementT> = HaxeNodes.blockOf(runs);
		return node == null ? null : statement(node, HaxeParseBack.BLOCK);
	}

	public function sequence(parts: Array<Built>): Null<Built> {
		var count: Int = 0;
		for (part in parts) {
			final statements: Null<Int> = isStatement(part) ? HaxeNodes.countOf(part.text) : null;
			if (statements == null) return null;
			count += statements;
		}
		final glued: StringBuf = new StringBuf();
		for (i => part in parts) {
			if (i > 0 && !part.text.isSpace(0)) glued.add(LINE_BREAK);
			glued.add(part.text);
		}
		final text: String = glued.toString();
		return parts.length > 0 && HaxeNodes.countOf(text) == count ? new Built(text, Statements) : null;
	}

	public function range(from: Built, to: Built): Null<Built> {
		final low: Null<HxExprT> = expression(from);
		final high: Null<HxExprT> = expression(to);
		return low == null || high == null ? null : expressed(HaxeNodes.intervalExpr(low, high), HaxeParseBack.INTERVAL);
	}

	public function arrayOf(items: Array<Built>): Null<Built> {
		final nodes: Array<HxExprT> = [];
		for (item in items) {
			final node: Null<HxExprT> = expression(item);
			if (node == null) return null;
			nodes.push(node);
		}
		return expressed(HaxeNodes.arrayExpr(nodes), HaxeParseBack.ARRAY);
	}

	public function boolean(value: Bool): Null<Built> {
		return expressed(HaxeNodes.boolExpr(value), HaxeParseBack.BOOLEAN);
	}

	public function importOf(path: String): Null<Built> {
		return _parseBack.rooted('import $path;', Import, HaxeParseBack.IMPORT);
	}

	public function usingOf(path: String): Null<Built> {
		return _parseBack.rooted('using $path;', Import, HaxeParseBack.USING);
	}

	public function modifiers(set: Array<Modifier>): Null<Built> {
		final text: String = set.map(word).join(' ');
		final nodes: Null<Array<QueryNode>> = _parseBack.slot(text, ModifierSet);
		return nodes != null && set.length > 0 && nodes.length == set.length && nodes.foreach(_parseBack.isModifier)
			? new Built(text, ModifierSet)
			: null;
	}

	public function withModifier(head: DeclarationHead, modifier: Modifier): Null<FixEdit> {
		final spelled: Null<Built> = modifiers([modifier]);
		final shape: RefShape = _plugin.refShape();
		final order: Array<String> = shape.modifierOrderKinds ?? [];
		final kind: String = kindOf(modifier);
		final rank: Int = order.indexOf(kind);
		if (spelled == null || rank < 0) return null;
		final carried: Array<QueryNode> = head.modifiers.filter(_parseBack.isModifier);
		if (carried.exists(node -> node.kind == kind)) return null;
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final other: Null<Span> = visibility.contains(kind) ? carried.find(node -> visibility.contains(node.kind))?.span : null;
		if (other != null) return { span: other, text: spelled.text };
		var after: Int = -1;
		var first: Int = head.start;
		for (node in carried) {
			final span: Null<Span> = node.span;
			if (span == null) continue;
			if (span.from < first) first = span.from;
			final carriedRank: Int = order.indexOf(node.kind);
			if (carriedRank >= 0 && carriedRank <= rank && span.to > after) after = span.to;
		}
		return after >= 0
			? { span: new Span(after, after), text: ' ${spelled.text}' }
			: { span: new Span(first, first), text: '${spelled.text} ' };
	}

	public function asConstant(source: String, start: Int): Null<FixEdit> {
		final end: Int = start + VARIABLE_WORD.length;
		return source.substring(start, end) == VARIABLE_WORD && member([], Constant, '_v', null, null) != null
			? { span: new Span(start, end), text: CONSTANT_WORD }
			: null;
	}

	public function member(set: Array<Modifier>, kind: MemberKind, name: String, type: Null<Built>, value: Null<Built>): Null<Built> {
		if (type != null && type.kind != TypeExpr) return null;
		final typeNode: Null<HxTypeT> = type == null ? null : HaxeNodes.typeOf(type.text);
		if (type != null && typeNode == null) return null;
		final node: Null<HxClassMemberT> = switch kind {
			case Constant, Variable:
				if (value != null && value.kind != Expression) return null;
				final init: Null<HxExprT> = value == null ? null : HaxeNodes.valueOf(value.text);
				if (value != null && init == null) return null;
				kind == Constant ? HaxeNodes.constant(name, typeNode, init) : HaxeNodes.variable(name, typeNode, init);
			case Method(params): methodOf(name, params, typeNode, value);
		};
		if (node == null) return null;
		final kinds: Array<String> = switch kind {
			case Constant: HaxeParseBack.CONSTANT;
			case Variable: HaxeParseBack.VARIABLE;
			case Method(_): HaxeParseBack.METHOD;
		};
		return _parseBack.declared(HaxeModuleTriviaWriter.writeHxMemberDeclNode(HaxeNodes.memberDecl(set, node)), kinds, set.length);
	}

	/** The method `name` taking `params` and answering `result` with `body`, a statement, or with none when `body` is null. */
	private function methodOf(name: String, params: Array<Parameter>, result: Null<HxTypeT>, body: Null<Built>): Null<HxClassMemberT> {
		if (body != null && body.kind != Statement) return null;
		final typed: Array<{ name: String, type: HxTypeT }> = [];
		for (param in params) {
			final paramType: Null<HxTypeT> = param.type.kind == TypeExpr ? HaxeNodes.typeOf(param.type.text) : null;
			if (paramType == null) return null;
			typed.push({ name: param.name, type: paramType });
		}
		final bodyNode: Null<HxFnBodyT> = body == null ? HaxeNodes.noBody() : HaxeNodes.bodyOf(body.text);
		return bodyNode == null ? null : HaxeNodes.method(name, typed, result, bodyNode);
	}

	/** The `if` running `body` when `condition`, an expression, holds. */
	private function conditionalOf(condition: Built, body: HxStatementT): Null<Built> {
		final cond: Null<HxExprT> = expression(condition);
		return cond == null ? null : statement(HaxeNodes.ifStmt(cond, body), HaxeParseBack.IF);
	}

	/** The statement assigning `value` to `target`, combined by `op` when given, when it parses back to an assignment of `kinds`. */
	private function assigned(target: Built, op: Null<Arithmetic>, value: Built, kinds: Array<String>): Null<Built> {
		final left: Null<HxExprT> = expression(target);
		final right: Null<HxExprT> = expression(value);
		if (left == null || right == null) return null;
		final text: String = HaxeModuleTriviaWriter.writeHxStatementNode(HaxeNodes.exprStmt(HaxeNodes.assignExpr(left, op, right)));
		final nodes: Null<Array<QueryNode>> = _parseBack.slot(text, Statement);
		return nodes != null && nodes.length == 1
			&& HaxeParseBack.EXPRESSION_STATEMENT.contains(nodes[0].kind)
			&& nodes[0].children.length == 1
			&& kinds.contains(nodes[0].children[0].kind)
			? new Built(text, Statement)
			: null;
	}

	/** The loop over `iterable` binding `binder`, and `valueBinder` when given, running `body`. */
	private function looped(binder: String, valueBinder: Null<String>, iterable: Built, body: Built): Null<Built> {
		final over: Null<HxExprT> = expression(iterable);
		final node: Null<HxStatementT> = statementOf(body);
		return over == null || node == null || !isName(binder)
			? null
			: statement(HaxeNodes.forStmt(binder, valueBinder, over, node), HaxeParseBack.FOR);
	}

	/** Whether `text` is one name the grammar reads as such, so a binder cannot carry code of its own. */
	private function isName(text: String): Bool {
		return _parseBack.rooted(text, Expression, HaxeParseBack.NAME) != null;
	}

	/** `node` written alone as a statement, when it parses back to one node of `kinds`. */
	private function statement(node: HxStatementT, kinds: Array<String>): Null<Built> {
		return _parseBack.rooted(HaxeModuleTriviaWriter.writeHxStatementNode(node), Statement, kinds);
	}

	/** `node` written alone as an expression, when it parses back to one node of `kinds`. */
	private function expressed(node: HxExprT, kinds: Array<String>): Null<Built> {
		return _parseBack.rooted(HaxeModuleTriviaWriter.writeHxExprNode(node), Expression, kinds);
	}

	private static inline function isStatement(part: Built): Bool {
		return part.kind == Statement || part.kind == Statements;
	}

	/** The expression `part` holds as a typed node; null when it is no expression. */
	private static function expression(part: Built): Null<HxExprT> {
		return part.kind == Expression ? HaxeNodes.valueOf(part.text) : null;
	}

	/** The one statement `part` holds as a typed node; null when it is no statement. */
	private static function statementOf(part: Built): Null<HxStatementT> {
		return part.kind == Statement ? HaxeNodes.statementOf(part.text) : null;
	}

	/** The block whose interior is `part`, a statement or a run of them; null when it is neither. */
	private static function runOf(part: Built): Null<HxStatementT> {
		return isStatement(part) ? HaxeNodes.runOf(part.text.ltrim()) : null;
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

	/** The node kind the grammar projects `modifier` as. */
	private static function kindOf(modifier: Modifier): String {
		return switch modifier {
			case Public: 'Public';
			case Private: 'Private';
			case Static: 'Static';
			case Inline: 'Inline';
			case Override: 'Override';
		};
	}

}
