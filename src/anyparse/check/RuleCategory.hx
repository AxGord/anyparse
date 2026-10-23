package anyparse.check;

using Lambda;

/**
 * The subject a rule is about: the closed set every `Check` names one of, which an `apqlint.json` switches on or off
 * as a whole (`categories`) and `apq lint --category` narrows a run to. A category is a SUBJECT, never a verb — the
 * verb (`prefer-…`, `redundant-…`) is already in the rule id — and each subject exists in any C-family grammar, so a
 * new category is one value here, never a property of one grammar.
 */
enum abstract RuleCategory(String) to String {

	/** Imports, usings and the ambient sources that carry them. */
	var Imports = 'imports';

	/** Comments and doc comments. */
	var Docs = 'docs';

	/** Declaration names and shadowing. */
	var Naming = 'naming';

	/** Null: flow-sensitive and declared proofs, safe navigation, null coalescing. */
	var NullSafety = 'nullsafety';

	/** Type positions, casts, is-checks, `Dynamic`, exception types. */
	var Types = 'types';

	/** Fields, accessors, modifiers, visibility, member order, signatures. */
	var Members = 'members';

	/** Dead declarations and dead code. */
	var Unused = 'unused';

	/** Branching: if / else, ternaries, switch, boolean logic, guards, conditional-compilation regions. */
	var Control = 'control';

	/** Loops and the collection / map idioms they spell. */
	var Loops = 'loops';

	/** Strings, interpolation, magic numbers. */
	var Literals = 'literals';

	/** Locals, statement syntax, lambdas, the shape of a call. */
	var Expressions = 'expressions';

	/** Metrics, duplication, project contracts, concurrency. */
	var Design = 'design';

	/** Every category, in the order a grouped listing prints them. */
	public static final ALL: Array<RuleCategory> = [
		Imports,
		Docs,
		Naming,
		NullSafety,
		Types,
		Members,
		Unused,
		Control,
		Loops,
		Literals,
		Expressions,
		Design
	];

	/** The category spelled `id`, or null when no category has that id. */
	public static function fromId(id: String): Null<RuleCategory> {
		return ALL.find(c -> (c: String) == id);
	}

	/** One line saying what the category's rules are about, for listings and the generated rule index. */
	public function description(): String {
		return switch abstract {
			case Imports: 'imports, usings and the ambient sources that carry them';
			case Docs: 'comments and doc comments';
			case Naming: 'declaration names and shadowing';
			case NullSafety: 'null: flow-sensitive and declared proofs, safe navigation, null coalescing';
			case Types: 'type positions, casts, is-checks, Dynamic, exception types';
			case Members: 'fields, accessors, modifiers, visibility, member order, signatures';
			case Unused: 'dead declarations and dead code';
			case Control: 'branching: if / else, ternaries, switch, boolean logic, guards, conditional-compilation regions';
			case Loops: 'loops and the collection / map idioms they spell';
			case Literals: 'strings, interpolation, magic numbers';
			case Expressions: 'locals, statement syntax, lambdas, the shape of a call';
			case Design: 'metrics, duplication, project contracts, concurrency';
		};
	}

}
