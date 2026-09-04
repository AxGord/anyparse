package anyparse.query;

import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * What a node REFERENCES or BINDS, by bare name — the grammar-level recognizers every
 * backing-field rewrite shares, with no opinion about what the caller does with the answer.
 *
 * Split out of `TrivialGetter`, where the same three questions were answered for three
 * different consumers of one 86-member type: the in-class rename walk (`FieldRename`), the
 * cross-file subtype attribution and the external read/write census (`anyparse.check`'s
 * `BackingFieldRefs`). Each is a walk with its OWN policy; all three needed the same
 * primitives, which is what a shared question looks like before it has a home.
 *
 * Three questions, and they are not interchangeable:
 *
 * - `fieldRefName` / `writeTargetField` / `mentionsField` — does this node NAME the field, and
 *   in a read or a write position? Deliberately narrow: only a bare identifier, a simple
 *   `$name` interpolation and a `this.<name>` access resolve. Every other receiver shape
 *   answers null, and each caller treats that as "not provably mine", which is the fail-closed
 *   direction for all three.
 * - `isFnScope` / `functionBindsName` / `bindsNameHere` — does an enclosing function bind this
 *   NAME? A walk asks it to decide whether a bare reference would re-bind to a local rather
 *   than to the member, and over-answering true only costs a `this.` qualifier.
 * - `hidesBindingNamed` — does this node bind the field's own name, so the field is hidden
 *   here? Over-answering true refuses the rewrite, again fail-closed.
 *
 * Kinds are named literally, as they are in `Rename`, `InlineMethod`, `CallSites` and the
 * other query modules that resolve a Haxe reference shape: threading a `RefShape` through
 * would touch 8 signatures and 13 call sites and could not express what these ask anyway
 * (`RefShape` names no pattern kind, no `this` identifier and no interpolation-read kind).
 */
@:nullSafety(Strict)
final class FieldRefScan {

	/**
	 * Every node kind that opens a function scope binding parameters and locals — the function
	 * VALUES `RefactorSupport.nestedFunctionKinds` is the authority for, plus one documented extra:
	 * the two METHOD-declaration kinds. Module-level function declarations (`FnDecl`) are
	 * deliberately NOT here — `this.` / `C.` is what a shadowed reference is rewritten to, and
	 * neither is spellable at module level.
	 *
	 * A hand copy of a derivable set, kept because the alternative is not worth its price: the shape
	 * is reached only in the check's `run`, while `isFnScope` is called from three points inside
	 * walks whose functions carry no context object, so deriving it would add a parameter to eight
	 * signatures and thirteen call sites — re-measured after this module split; the note this
	 * replaces said fourteen — in a module that decides its other node kinds by literal anyway.
	 * `unit.query.FieldRefScanTest.testFnScopeKindsMatchTheGrammarAuthority` pins it against the
	 * plugin in BOTH directions instead, so a grammar that adds or drops a function-value spelling
	 * fails a test rather than silently changing what this rename trusts.
	 */
	private static final FN_SCOPE_KINDS: Array<String> = [
		'FnMember',
		'FinalModifiedMember',
		'LocalFnStmt',
		'LocalInlineFnStmt',
		'FnExpr',
		'NamedFnExpr',
		'ThinParenLambdaExpr',
		'ParenLambdaExpr',
		'ThinArrow'
	];

	/** Whether `node` opens a new function scope (method / local fn / lambda) that binds parameters and locals. */
	public static inline function isFnScope(node: QueryNode): Bool {
		return FN_SCOPE_KINDS.contains(node.kind);
	}

	/**
	 * Whether the subtree `node` binds `name` in ANY form the language offers (`bindsNameHere`).
	 * Scanned subtree-wide from a function scope, so a nested function's binding also trips it —
	 * over-qualifying a backing-field reference with `this.` / `C.` is always semantically
	 * correct, while MISSING a binder silently re-binds the reference to it (a loop variable
	 * named like the property turned `if (color == _color)` into the always-true `color == color`).
	 */
	public static function functionBindsName(node: QueryNode, name: String): Bool {
		return bindsNameHere(node, name) || node.children.exists(c -> functionBindsName(c, name));
	}

	/**
	 * Whether `node` BINDS `field`, hiding the backing field from the by-name shadow refusal in
	 * `renameWalk`. A loop binds its iterator (`ForStmt` / `ForExpr`) or, in the key-value form
	 * `for (k => _x in m)` / `[for (k => _x in m) …]`, a second name on a `KeyValueBinder` child.
	 * A multi-variable declaration's later bindings project as `VarMore`, so the multi-var arm ASKS
	 * THE TREE for one: a text-level comma scan cannot tell `var a = 1, b = 2` from the comma inside
	 * a `Map<K, V>` annotation, and refused the latter. In that one arm any word-match of `field` in
	 * the declaration refuses the fix (conservative: a multi-var INIT reading the real field also
	 * refuses). A missing span refuses everywhere — an unreadable construct binds everything.
	 */
	public static function hidesBindingNamed(node: QueryNode, span: Null<Span>, source: String, field: String): Bool {
		switch node.kind {
			case 'VarStmt', 'FinalStmt':
				if (span == null) return true;
				return node.children.exists(c -> c.kind == 'VarMore') && SourceText.identTokenOffset(source, span, field) >= 0;
			case 'ForStmt', 'ForExpr', 'KeyValueBinder':
				return span == null || node.name == field;
			case _:
				return false;
		}
	}

	/**
	 * The field name a node references as a bare `IdentExpr <name>`, a simple `$<name>` string-interpolation `Ident`, or a `this.<name>` `FieldAccess`, else null.
	 */
	public static function fieldRefName(node: QueryNode): Null<String> {
		return switch node.kind {
			case 'IdentExpr', 'Ident': node.name;
			case 'FieldAccess':
				node.children.length == 1 && node.children[0].kind == 'IdentExpr' && node.children[0].name == 'this' ? node.name : null;
			case _: null;
		}
	}

	/** The field targeted by an assignment / compound-assignment / incr / decr node (bare or `this.`), else null. */
	public static function writeTargetField(node: QueryNode): Null<String> {
		return isWriteNodeKind(node.kind) && node.children.length >= 1 ? fieldRefName(node.children[0]) : null;
	}

	/** Whether `node`'s subtree references `field` (bare `IdentExpr` / `this.<field>`, read or write target). */
	public static function mentionsField(node: QueryNode, field: String): Bool {
		return fieldRefName(node) == field || node.children.exists(child -> mentionsField(child, field));
	}

	/** Whether `kind` is an assignment / compound-assignment / increment / decrement whose first child is its write target. */
	public static function isWriteNodeKind(kind: String): Bool {
		return switch kind {
			case 'Assign', 'AddAssign', 'SubAssign', 'MulAssign', 'DivAssign', 'ModAssign', 'BitAndAssign', 'BitOrAssign', 'BitXorAssign',
				'ShlAssign', 'ShrAssign', 'UShrAssign', 'PreIncr', 'PostIncr', 'PreDecr', 'PostDecr': true;
			case _: false;
		}
	}

	/**
	 * Whether `node` ITSELF binds `name`. Every binding form the grammar projects as a named
	 * node: a parameter (`Required` / `Optional` / `Rest` / `LambdaParam`), a local declaration
	 * (`VarStmt` / `FinalStmt`, their expression twins, and the `VarMore` continuation of a
	 * multi-var list), a local function, a catch variable, the self-scoped `for` iterator
	 * (`ForStmt` / `ForExpr` — the array-comprehension form is a `ForExpr`) and the `KeyValueBinder`
	 * carrying the VALUE of a key-value `for (k => v in m)`, whose KEY is the loop node's own name.
	 *
	 * One shape carries no named binding node and is recovered here: a case PATTERN (`Plain`)
	 * projects its captures as bare identifiers, so ANY mention of `name` inside one counts (a
	 * constructor name that happens to match only over-qualifies).
	 *
	 * A single-parameter thin arrow `v -> ...` used to need a second recovery arm here, reading
	 * child-0 of a `ThinArrow` for a bare `IdentExpr`. It no longer does:
	 * `HxArrowParamProjection` re-labels that child `Required` in the query tree, so the
	 * parameter arrives through the first arm like every other parameter. That private arm was
	 * the tell — four `Refs`-based checks were one gap away from needing their own copy.
	 */
	private static function bindsNameHere(node: QueryNode, name: String): Bool {
		return switch node.kind {
			case 'Required', 'Optional', 'Rest', 'LambdaParam', 'VarStmt', 'FinalStmt', 'VarExpr', 'FinalExpr', 'VarMore',
				'StaticVarStmt', 'StaticFinalStmt', 'LocalFnStmt', 'LocalInlineFnStmt', 'NamedFnExpr', 'CatchClause', 'ForStmt',
				'ForExpr', 'KeyValueBinder', 'Capture': node.name == name;
			case 'Plain': mentionsField(node, name);
			case _: false;
		}
	}

}
