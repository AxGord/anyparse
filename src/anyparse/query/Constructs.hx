package anyparse.query;

import anyparse.check.Check.FixEdit;
import anyparse.runtime.Span;

/**
 * A construct a grammar's `Constructs` built: its text and what it is. Only a grammar package makes one, so a String a
 * rule spelled itself never stands where an edit asks for a built construct.
 */
@:nullSafety(Strict)
final class Built {

	public final text: String;
	public final kind: ConstructKind;

	@:allow(anyparse.grammar)
	private function new(text: String, kind: ConstructKind) {
		this.text = text;
		this.kind = kind;
	}

}

/** What a built construct is, by its role in a file. */
enum ConstructKind {

	Expression;
	TypeExpr;
	Statement;

	/**
	 * A run of statements as it stands inside a block, with the comments among them: a copied run keeps the layout that opens
	 * it (a blank line, a comment on the line it opened on), so a fix that puts it after a statement keeps both where they
	 * stood; what closes it belongs to the place it is put.
	 */
	Statements;
	Member;
	Import;
	ModifierSet;

}

/** A declaration modifier, by meaning; the grammar owns its spelling. */
enum Modifier {
	Public;
	Private;
	Static;
	Inline;
	Override;
}

/** An arithmetic operation an assignment can combine its target with, by meaning; the grammar owns its spelling. */
enum Arithmetic {
	Add;
	Subtract;
	Multiply;
	Divide;
	Remainder;
}

/** What a type member holds. */
enum MemberKind {

	/** A value bound once. */
	Constant;

	/** A value that may be reassigned. */
	Variable;

	/** Code taking `params`. */
	Method(params: Array<Parameter>);

}

/** A method parameter: its name and its type. */
typedef Parameter = { final name: String; final type: Built; }

/** The modifier nodes a declaration carries, in source order, and the offset where the declaration itself starts. */
typedef DeclarationHead = { final modifiers: Array<QueryNode>; final start: Int; }

/**
 * A grammar's construct builder: the one answer to "how does a fix get new code of the target language built by meaning".
 * A fix or a refactoring op never spells target syntax itself; it names WHAT it wants (a member, a call, an import, a
 * statement) and the grammar package answers the text, so a rule compiles against this interface alone (invariant 4,
 * `docs/design-principles.md`). Every method answers null when the result does not parse back to the construct it was
 * asked for, or when the grammar has no such construct; a grammar with none at all answers null from
 * `GrammarPlugin.constructs`.
 */
@:nullSafety(Strict)
interface Constructs {

	/** The fragment `span` of `source`, copied verbatim, as a construct of `kind`. */
	public function copied(source: String, span: Span, kind: ConstructKind): Null<Built>;

	/** The fragment `span` of `source` with its sub-span `part` replaced by `by`, as a construct of `kind`. */
	public function substituted(source: String, span: Span, part: Span, by: Built, kind: ConstructKind): Null<Built>;

	/** A type reference that a type printer spelled for the file it goes into. */
	public function typeRef(spelled: String): Null<Built>;

	/** The type of a function taking `params` and answering `result`. */
	public function functionType(params: Array<Built>, result: Built): Null<Built>;

	/** The member `name` of `owner`, a type or a value. */
	public function qualified(owner: Built, name: String): Null<Built>;

	/** A call of `callee` with `args`. */
	public function call(callee: Built, args: Array<Built>): Null<Built>;

	/** An anonymous function binding `params` and answering `body`, an expression. */
	public function lambda(params: Array<String>, body: Built): Null<Built>;

	/** The statement that leaves the enclosing function with `value`. */
	public function returning(value: Built): Null<Built>;

	/** The statement that leaves the enclosing function with no value. */
	public function returningNothing(): Null<Built>;

	/** The statement that goes on to the next iteration of the enclosing loop. */
	public function continuing(): Null<Built>;

	/**
	 * The statement that runs `exit`, a statement leaving the code around
	 * it (a return, a continue, a break, a throw), when `condition` holds.
	 */
	public function guard(condition: Built, exit: Built): Null<Built>;

	/** The statement that runs `body`, a statement, when `condition` holds and nothing otherwise. */
	public function conditional(condition: Built, body: Built): Null<Built>;

	/** The statement giving `target` the value `value`. */
	public function assignment(target: Built, value: Built): Null<Built>;

	/** The statement giving `target` its own value combined with `value` by `op`. */
	public function compoundAssignment(target: Built, op: Arithmetic, value: Built): Null<Built>;

	/** The local declaration of `name`, `kind` a constant or a variable, of `type` and initialised to `value` when given. */
	public function local(kind: MemberKind, name: String, type: Null<Built>, value: Null<Built>): Null<Built>;

	/** The loop running `body` once per element of `iterable`, the element bound to `binder`. */
	public function forEach(binder: String, iterable: Built, body: Built): Null<Built>;

	/** The loop running `body` once per entry of the map `iterable`, its key bound to `key` and its value to `value`. */
	public function forEachPair(key: String, value: String, iterable: Built, body: Built): Null<Built>;

	/** The block holding the statements of `parts`, each a statement or a run of them, in order. */
	public function block(parts: Array<Built>): Null<Built>;

	/**
	 * The run of the statements of `parts`, each a statement or a run of them, in order: each part starts a line of its own,
	 * except a copied run that opens on its own layout, which keeps it right after the part before.
	 */
	public function sequence(parts: Array<Built>): Null<Built>;

	/** The values from `from` up to, not including, `to`. */
	public function range(from: Built, to: Built): Null<Built>;

	/** The array holding `items` in order. */
	public function arrayOf(items: Array<Built>): Null<Built>;

	/** The boolean `value`. */
	public function boolean(value: Bool): Null<Built>;

	/** The declaration that brings the type at `path` into a file's scope. */
	public function importOf(path: String): Null<Built>;

	/** The declaration that brings the static extension methods of the type at `path` into a file's scope. */
	public function usingOf(path: String): Null<Built>;

	/** The modifier set `set`, in the order given. */
	public function modifiers(set: Array<Modifier>): Null<Built>;

	/**
	 * The edit that gives the declaration `head` the modifier `modifier`, in the grammar's canonical modifier order among the
	 * modifiers it already carries; a visibility the declaration carries instead is replaced. Null when it already carries
	 * `modifier`, or the grammar does not rank it.
	 */
	public function withModifier(head: DeclarationHead, modifier: Modifier): Null<FixEdit>;

	/**
	 * The edit that turns the variable declaration starting at `start` in `source` into a constant one: its keyword replaced.
	 * Null when no variable declaration starts there.
	 */
	public function asConstant(source: String, start: Int): Null<FixEdit>;

	/**
	 * A type member `name` carrying `set`. `type` is the value's type, or a method's return type; `value` is the initial value
	 * (an expression), or a method's body (a statement, null for a member with no body).
	 */
	public function member(set: Array<Modifier>, kind: MemberKind, name: String, type: Null<Built>, value: Null<Built>): Null<Built>;

}
