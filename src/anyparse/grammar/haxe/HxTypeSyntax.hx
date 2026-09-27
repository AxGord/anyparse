package anyparse.grammar.haxe;

import anyparse.grammar.haxe.spans.Pairs;
import anyparse.query.TypeSyntax;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Reads a Haxe type written as text into a `TypeSyntax` — this grammar's `GrammarPlugin.typeSyntax`
 * answer. The text is parsed by the generated span parser as the right-hand side of a typedef, so
 * every spelling the grammar accepts in type position is read exactly as a declaration's type
 * would be, and anything it rejects answers null. The parse accepting the whole text is the proof
 * that nothing but trivia stands around the type.
 *
 * ## How the arrow forms map
 *
 * The curried chain `A -> ?B -> R` is ONE function (`HxType.Arrow` is right-associative, so the
 * chain's right spine is walked: every left operand is a parameter, an `OptionalArg` on the spine
 * marks the next one optional, the last operand is the result), exactly as Haxe reads it. A
 * parenthesised right operand, `A -> (B -> R)`, ends the chain there: it is a result that is a
 * function. The parenthesised form `(a: A, ?B) -> R` is one function per list, so `(A) -> (B) -> R`
 * returns `(B) -> R`.
 */
@:nullSafety(Strict)
final class HxTypeSyntax {

	private static inline final PREFIX: String = 'typedef _ = ';

	private final _text: String;

	private function new(text: String) {
		_text = text;
	}

	private function type(t: HxTypeS): TypeSyntax {
		return switch t {
			case Named(ref, span):
				node(span, Nominal(ref.name, [for (a in ref.params ?? []) argument(a)]));
			case Parens(inner, span):
				node(span, type(inner).shape);
			case Arrow(_, _, span), OptionalArg(Arrow(_, _, _), span):
				node(span, curried(t));
			case ArrowFn(fn, span):
				node(span, Function([for (a in fn.args) param(a)], type(fn.ret), false));
			case Anon(members, span):
				node(span, Structure([for (m in members) for (f in field(m)) f]));
			case DollarType(_, span), OptionalArg(_, span), ConstStringType(_, span), BracketExprListType(_, span), ConditionalType(_, span):
				node(span, Other);
		};
	}

	/** A type argument — `Other` when it carries an intersection (`A & B`), whose span runs to the last member. */
	private function argument(a: HxTypeArgS): TypeSyntax {
		final head: TypeSyntax = type(a.type);
		if (a.intersections.length == 0) return head;
		final last: TypeSyntax = type(a.intersections[a.intersections.length - 1].type);
		return new TypeSyntax(new Span(head.span.from, last.span.to), _text.substring(head.span.from, last.span.to), Other);
	}

	/** The curried chain whose head is `t`: one parameter per left operand on the right spine, the last operand the result. */
	private function curried(t: HxTypeS): TypeShape {
		final params: Array<TypeParam> = [];
		var at: HxTypeS = t;
		while (true) {
			switch at {
				case Arrow(left, right, _):
					params.push({ name: null, optional: false, type: type(left) });
					at = right;
				case OptionalArg(Arrow(left, right, _), _):
					params.push({ name: null, optional: true, type: type(left) });
					at = right;
				case _:
					return Function(params, type(at), true);
			}
		}
	}

	private function param(p: HxArrowParamS): TypeParam {
		return switch p {
			case Positional(OptionalArg(inner, _), _): { name: null, optional: true, type: type(inner) };
			case Positional(t, _): { name: null, optional: false, type: type(t) };
			case NamedParam(body, _): { name: body.name, optional: false, type: type(body.type) };
			case OptionalNamedParam(body, _): { name: body.name, optional: true, type: type(body.type) };
		};
	}

	/** The typed field a structure member declares — none for a method, an `> Extension`, a conditional region or an untyped `var`. */
	private function field(m: HxAnonMemberS): Array<TypeField> {
		final f: Null<HxAnonFieldS> = m.field;
		if (f == null) return [];
		return switch f {
			case Required(body, _): [{ name: body.name, optional: false, type: type(body.type) }];
			case Optional(body, _): [{ name: body.name, optional: true, type: type(body.type) }];
			case VarField(Plain(decl, _), _), FinalField(Plain(decl, _), _): declared(decl, false);
			case VarField(Optional(decl, _), _), FinalField(Optional(decl, _), _): declared(decl, true);
			case _: [];
		};
	}

	private function declared(decl: HxVarDeclS, optional: Bool): Array<TypeField> {
		final t: Null<HxTypeS> = decl.type;
		return t == null ? [] : [{ name: decl.name, optional: optional, type: type(t) }];
	}

	/**
	 * A node over `span`, shifted from the parsed typedef back onto the caller's text. A span may run
	 * on over the whitespace the parser skipped after its last token (`(Int) -> Int ` before a `=`);
	 * that tail is not part of the type, so it is cut off.
	 */
	private function node(span: Span, shape: TypeShape): TypeSyntax {
		final from: Int = span.from - PREFIX.length;
		final text: String = _text.substring(from, span.to - PREFIX.length).rtrim();
		return new TypeSyntax(new Span(from, from + text.length), text, shape);
	}

	/** `text` read as one type, or null when it does not parse as exactly one — see `GrammarPlugin.typeSyntax`. */
	public static function of(text: String): Null<TypeSyntax> {
		final root: HxModuleS = try HaxeModuleSpanParser.parse(PREFIX + text + '\n;') catch (exception: Exception) return null;
		if (root.decls.length != 1) return null;
		final type: Null<HxTypeS> = switch root.decls[0].decl {
			case TypedefDecl({ typeParams: null, type: t, intersections: [] }, _): t;
			case _: null;
		};
		return type == null ? null : new HxTypeSyntax(text).type(type);
	}

}
