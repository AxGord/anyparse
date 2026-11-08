package anyparse.query;

/**
 * The one answer to "which kind and id strings does a typed fact carry": the vocabulary `TypedFactsProbe` writes into
 * its facts and every reader of `CompilerFacts` compares against. A reader spells a kind through these constants,
 * never as a literal of its own, so the producer and its consumers cannot drift apart. No dependency: the probe
 * reads it at macro time, the checks at run time.
 */
@:nullSafety(Strict)
final class FactKinds {

	/** The kind of a typed class (`TypeFact.kind`), and of an instance of a `@:generic` one. */
	public static inline final CLASS: String = 'class';

	/** The kind of a typed interface (`TypeFact.kind`): it declares no code of its own. */
	public static inline final INTERFACE: String = 'interface';

	/** The kind of an abstract's implementation class (`TypeFact.kind`): its statics are the abstract's members. */
	public static inline final IMPL: String = 'impl';

	/** The kind of a typed enum (`TypeFact.kind`). */
	public static inline final ENUM: String = 'enum';

	/** The kind of a typed abstract (`TypeFact.kind`): its methods are its implementation class's statics. */
	public static inline final ABSTRACT: String = 'abstract';

	/** The kind of a typed typedef (`TypeFact.kind`). */
	public static inline final TYPEDEF: String = 'typedef';

	/** The kind of a method's body (`FactNode.kind`), and of a plain method field (`FieldDeclFact.kinds`). */
	public static inline final METHOD: String = 'method';

	/** The kind of a class constructor's body (`FactNode.kind`). */
	public static inline final CTOR: String = 'ctor';

	/** The kind of a function expression's body in a body (`FactNode.kind`): one bound to no local. */
	public static inline final FN: String = 'fn';

	/** The kind of a function bound to a local in a body (`FactNode.kind`). */
	public static inline final LOCAL: String = 'local';

	/** The kind of a field's initializer (`FactNode.kind`). */
	public static inline final VAR: String = 'var';

	/** The kind of a type's static initialization (`FactNode.kind`). */
	public static inline final INIT: String = 'init';

	/** The kind of an inline method field (`FieldDeclFact.kinds`): an extern type's inline method has a body. */
	public static inline final INLINE: String = 'inline';

	/** The kind of a dynamic method field (`FieldDeclFact.kinds`): a variable holding a function. */
	public static inline final DYNAMIC: String = 'dynamic';

	/**
	 * The kind of a macro function's field (`FieldDeclFact.kinds`): its body runs while compiling, in no program, and a
	 * call of it is the code it returns, not a value.
	 */
	public static inline final MACRO: String = 'macro';

	/** What separates a nested function's id from its parent's: `<parent id>@<offset>`. */
	public static inline final NESTED_ID: String = '@';

	/** What separates a further overload's index from its field's node id: `<field id>~<n>`. */
	public static inline final OVERLOAD_ID: String = '~';

	/** The class of `Reflect`, which the probe marks as reflection. */
	public static inline final REFLECT: String = 'Reflect';

	/** The class of `Type`, which the probe marks as reflection. */
	public static inline final TYPE: String = 'Type';

	/** What separates a uniqueness index from a node id that repeats: `<id>#<n>`, the n-th further node of that id. */
	public static inline final UNIQUE_ID: String = '#';

	/** The classes whose members are reflection. */
	public static final REFLECTION_CLASSES: Array<String> = [REFLECT, TYPE];

	/** The typed kinds a value of which is an object of a class: its members are what that class declares. */
	public static final OBJECT_KINDS: Array<String> = [CLASS, INTERFACE];

	/** The typed kinds a name can stand for as a nominal type. */
	public static final NOMINAL_KINDS: Array<String> = [CLASS, INTERFACE, ENUM];

	/** The typed kinds that carry code of their own: a class and an abstract's implementation class. */
	public static final CODE_KINDS: Array<String> = [CLASS, IMPL];

	/** The field kinds that are methods: a read of one is a function value. */
	public static final METHOD_KINDS: Array<String> = [METHOD, INLINE, DYNAMIC];

	/** The node kinds that are the body of a member function, as opposed to a function nested in one. */
	public static final OWN_BODY_KINDS: Array<String> = [METHOD, CTOR];

	/** The node kinds that are the body of a function. */
	public static final FUNCTION_KINDS: Array<String> = [METHOD, CTOR, FN, LOCAL];

	/** The node kinds that are a function written inside a body. */
	public static final NESTED_FUNCTION_KINDS: Array<String> = [FN, LOCAL];

	/** The field kinds of a method whose declared body no code can reassign: a `dynamic` one is a variable. */
	public static final FIXED_METHOD_KINDS: Array<String> = [METHOD, INLINE];

	/** What ends a field node's id before an overload index (`~n`) or a uniqueness index (`#n`). */
	public static final ID_SUFFIXES: Array<String> = [OVERLOAD_ID, UNIQUE_ID];

}
