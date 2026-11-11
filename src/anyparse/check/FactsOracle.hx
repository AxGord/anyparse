package anyparse.check;

import anyparse.check.Check.TypeOracle;
import anyparse.runtime.Span;

/**
 * The compiler's typed facts as a check reads them: the one answer to "how does a rule ask a run's compiler facts",
 * what a grammar's `OracleProvider` hands a fix. Each answer holds what every configuration that compiled the code
 * agrees on; code no configuration compiled answers nothing.
 */
@:nullSafety(Strict)
interface FactsOracle extends TypeOracle {

	/**
	 * The simple name of `expr`'s type (or of the parentheses around it) when every configuration typed it with a type no
	 * operator overload can be declared on, or null: `source` is the file's text as the caller reads it.
	 */
	public function nonOverloadingName(file: String, source: String, expr: Null<Span>): Null<String>;

	/** Whether every configuration gave `expr` one type and declared it a class, extern in none. */
	public function compiledClassAt(file: String, expr: Span): Bool;

	/** What the `extends` chain of `owner`, declared in `file`, says of a member called `name`. */
	public function inheritedMember(file: String, owner: String, name: String): InheritedMember;

	/**
	 * The values the builds read of the enum abstract `owner`, declared in `file`, or null when no build typed it there: the
	 * abstract's id and the `CaseValueKey` of every value read anywhere in the typed code, whatever range it was read at.
	 */
	public function enumValueReads(file: String, owner: String): Null<EnumValueReads>;

	/**
	 * The ids of the enum abstracts a value of which the builds read at the range ending where `span` of `file` ends and
	 * holding it — a value's name, bare or qualified — or null when no build typed the code there as the run reads it: a
	 * file or a member no configuration compiled, or one the run rewrote. A conditional branch every build left out
	 * inside typed code answers an empty list like code that reads no value.
	 */
	public function enumValuesReadAt(file: String, span: Span): Null<Array<String>>;

}

/** What the builds typed of a type's supertypes about a member name (`FactsTypeOracle.inheritedMember`). */
enum InheritedMember {

	/** No build typed the type where it is declared, or one of its supertypes. */
	Untyped;

	/** The supertype `supertype` declares a member of the name in some build. */
	Declared(supertype: String);

	/** The supertype `supertype` carries `@:autoBuild`: its macro builds the type as its own `@:build`. */
	AutoBuilt(supertype: String);

	/** No supertype declares the name, and none is `@:autoBuild`. */
	Undeclared;

}

/** The values the builds read of one enum abstract (`FactsOracle.enumValueReads`). */
typedef EnumValueReads = { final type: String; final keys: Array<String>; }
