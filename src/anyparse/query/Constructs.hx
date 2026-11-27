package anyparse.query;

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

	/** The declaration that brings the type at `path` into a file's scope. */
	public function importOf(path: String): Null<Built>;

	/** The declaration that brings the static extension methods of the type at `path` into a file's scope. */
	public function usingOf(path: String): Null<Built>;

	/** The modifier set `set`, in the order given. */
	public function modifiers(set: Array<Modifier>): Null<Built>;

	/**
	 * A type member `name` carrying `set`. `type` is the value's type, or a method's return type; `value` is the initial value
	 * (an expression), or a method's body (a statement, null for a member with no body).
	 */
	public function member(set: Array<Modifier>, kind: MemberKind, name: String, type: Null<Built>, value: Null<Built>): Null<Built>;

}
