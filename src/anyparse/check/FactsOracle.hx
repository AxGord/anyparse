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
