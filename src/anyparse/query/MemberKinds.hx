package anyparse.query;

using StringTools;
using Lambda;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

/**
 * The grammar's MEMBER vocabulary and the walk that reaches members. Which projected node
 * kinds declare a member, which of those hold data rather than a body, which are enum
 * constructors, which hide their own names; which nodes can HOST a member declaration and how
 * a walk descends to them; and which kinds a modifier / metadata prefix run is made of.
 *
 * The kind SETS are `public static final` on purpose: they are the vocabulary itself, and a
 * consumer that needs to test membership against one of them (rather than ask a predicate)
 * must be able to read it rather than respell it.
 *
 * The tail of the module is the kind-agnostic shape questions over an arbitrary subtree —
 * `subtreeContainsKind`, `structurallyEqual`, `sameSource`, `indexNodesByKind`. They sit here
 * because they are the same layer: a question answered by reading node KINDS and nothing else.
 */
@:nullSafety(Strict)
final class MemberKinds {

	/**
	 * DATA-field member kinds — a member that HOLDS a value rather than a function body.
	 * Separated from the function kinds because several questions are only meaningful for
	 * one half: a language may forbid an instance data field where it allows an instance
	 * method (Haxe's `abstract`), and a move that carries a data field carries its
	 * initializer while a moved method carries none.
	 */
	public static final DATA_FIELD_KINDS: Array<String> = [
		'VarMember',
		'FinalMember',
		'VarField',
		'FinalField'
	];

	/**
	 * Every member kind a type body can declare that is not a constructor — the data
	 * fields above plus the function forms. Built from `DATA_FIELD_KINDS` so the two are
	 * each other's complement by construction: a kind added to one can no longer go
	 * missing from the other. Its name reads narrower than it is; `isDataFieldKind` is
	 * the test for the data half alone.
	 */
	public static final FIELD_MEMBER_KINDS: Array<String> = DATA_FIELD_KINDS.concat([
		'FnMember',
		'FinalModifiedMember',
		'FnField'
	]);

	/**
	 * Function-declaration kinds — class methods (`FnMember`, plus the
	 * `final` method form `FinalModifiedMember`) and named local functions
	 * (`LocalFnStmt`). All expose their parameter list as the leading
	 * `Required` / `Optional` children of the decl node. Shared by
	 * `AddParam`, `ExtractVar`, and `ChangeSig` so the three operations
	 * recognise the same set of function declarations. A `final` method's
	 * name is surfaced by the query projection (off the inner
	 * `HxFinalModifierMember.fn`), so it resolves through `resolveCursorNode`
	 * / `innermostWhere` exactly like a plain method.
	 */
	public static final FN_DECL_KINDS: Array<String> = [
		'FnMember',
		'FinalModifiedMember',
		'LocalFnStmt'
	];

	/**
	 * The grammar decl-node kinds that count as a top-level type
	 * declaration in their PLAIN (non-`final`) shape. A `final class`'s
	 * named node is a `ClassForm` — NOT in this list — so callers that
	 * need to recognise a final class must go through `typeDeclOf`, which
	 * handles the `FinalDecl` wrapper. Shared by `SymbolIndex`,
	 * `CrossRename`, and `MoveSymbol`.
	 */
	public static final TYPE_DECL_KINDS: Array<String> = [
		'ClassDecl',
		'AbstractClassDecl',
		'InterfaceDecl',
		'EnumDecl',
		'EnumAbstractDecl',
		'TypedefDecl',
		'AbstractDecl'
	];

	/**
	 * Expression-list container kinds whose direct children are
	 * comma-separated. When an element's parent is one of these, an insert
	 * joins with a `,` and a remove swallows one. `Call` / `NewExpr` carry a
	 * leading non-element child (callee / constructed type), harmless here
	 * because the targeted element is an actual argument, never the callee.
	 * Shared by `add-element` (insert) and `deleteNode` (remove) so the two
	 * agree on which slots are comma lists.
	 */
	public static final COMMA_CONTAINER_KINDS: Array<String> = ['ArrayExpr', 'ObjectLit', 'Call', 'NewExpr'];

	/**
	 * The sibling node kinds `@:meta` annotations project to: `Meta` for the
	 * paren-less `@:name`, `MetaCall` for `@:name(args)`, `PlainMeta` for the
	 * verbatim raw catch-all (mirrors the grammar's `metaShape().metaKinds`).
	 * Shared by `MODIFIER_META_KINDS` and the ops that must skip a leading meta
	 * run (e.g. MoveMember's visibility promotion).
	 */
	public static final META_KINDS: Array<String> = ['Meta', 'MetaCall', 'PlainMeta'];

	/** The grammar kind a dotted member access projects as — one link of a receiver chain. */
	public static final FIELD_ACCESS_KIND: String = 'FieldAccess';

	/** The grammar kind a bare identifier projects as — the root of a receiver chain. */
	public static final IDENT_EXPR_KIND: String = 'IdentExpr';

	/**
	 * Sibling node kinds a declaration's modifiers and metadata project to — emitted BEFORE the
	 * decl they modify (`public static function` is `(Public)(Static)(FnMember)`; annotations are
	 * the `META_KINDS` forms). `declGroupSpan` folds a run of these plus the decl into one logical
	 * element so a structural edit treats the whole `[@:meta modifiers… decl]` as a unit, not the
	 * decl keyword alone. The member-level `abstract` modifier (Haxe 4.2 abstract classes)
	 * projects as its own `(Abstract)` sibling and IS here. `final` is NOT — it WRAPS its decl
	 * (`FinalDecl` / `FinalModifiedMember` / `FinalMember`) instead of projecting to a separate
	 * sibling.
	 *
	 * The AUTHORITY for the modifier half is the grammar's own `RefShape.modifierKinds`
	 * (`HaxeNamingSupport.MOD_KIND_TO_NAME`'s key set, whose doc calls them "the kinds a
	 * leading-run walk crosses without ending the run"). This list is a hand-copy of it, kept
	 * because neither `declGroupSpan` nor `declRunStart` ACCEPTS a shape — NOT because their
	 * callers lack one: several already hold a `RefShape` or a plugin, and threading one through
	 * is a thirteen-call-site change.
	 *
	 * A hand-copy DRIFTS. `Overload` (`overload function f()`, carried by all three modifier
	 * enums — `HxMemberModifier`, `HxModifier`, `HxCondModPrefix`) was declared by the grammar and
	 * missing here, so a run stopped at the `overload` keyword and every consumer of the folded
	 * span truncated there: `remove-element` on a member left the leftover modifiers standing and
	 * the next declaration silently absorbed them (`extern overload public function keep()`), at
	 * rc 0 with a file that still parses.
	 * `ModifierKindSeamTest.testEveryModifierSeamKindIsADeclPrefixSibling` now re-asserts the
	 * inclusion against the live plugin shape, so the next modifier a grammar enum gains fails a
	 * test rather than a user's file.
	 */
	public static final MODIFIER_META_KINDS: Array<String> = META_KINDS.concat([
		'Public',
		'Private',
		'Static',
		'Inline',
		'Override',
		'Macro',
		'Extern',
		'Dynamic',
		'Abstract',
		'Overload'
	]);

	/** The grammar kind a block-level `#if … #end` region projects as - the host of a conditional-modifier prefix (`isConditionalModifierRegion`). */
	public static final CONDITIONAL_REGION_KIND: String = 'Conditional';

	/**
	 * The bare DECLARATION-STARTING keyword kinds a conditional region may contribute to the
	 * declaration after its `#end`, mirroring `RefShape.condDeclPrefixKeywordKinds` (Haxe `EnumKw`
	 * / `AbstractKw` / `FinalKw`, the `@:kw` arms of `HxCondDeclPrefix`). Each can itself introduce
	 * a type, so the grammar captures it as a bare token INSIDE the region rather than letting the
	 * parser commit to a whole declaration there — which is why it is neither a
	 * `MODIFIER_META_KINDS` sibling nor an annotation, and why an annotation-and-modifier-only test
	 * reads `#if (haxe_ver >= 4.2) enum #else @:enum #end` as a declaration of its own.
	 *
	 * A hand-copy for the same reason `MODIFIER_META_KINDS` above is one — neither
	 * `declGroupSpan` nor `declRunStart` accepts a shape — and guarded the same way, by
	 * `ModifierKindSeamTest.testEveryCondDeclPrefixKeywordIsADeclPrefixSibling`, which asks the
	 * predicate over the live `RefShape` rather than comparing two lists.
	 *
	 * The widening reaches every `declGroupSpan` consumer, and for one of them it is a behaviour
	 * CHANGE rather than a repair: `replace-node --select 'AbstractDecl:E'` overwrites the region
	 * too. That is the documented `replace-node` contract — its span covers the whole declaration
	 * including its leading modifiers — applied to one more shape, and the read now agrees with it:
	 * `Cli.resolveNodeLineBounds` folds the printed window through `declGroupSpan` in `Patch`'s own
	 * order, so a replacement copied out of `source --select` carries the `enum` of `enum abstract`
	 * instead of silently dropping it. `ast --select` / `ast --at` fold the same way now: their
	 * `--source` window is computed in `Cli.sourceWindows` and handed to `SourceSlice`, which keeps
	 * its span-only contract — WHICH span is the caller's decision. `refs` / `uses` `--source`
	 * deliberately stay on the bare hit span, and `SourceSlice`'s own doc says why: a hit is an
	 * occurrence in a listing rather than a node the caller addressed.
	 */
	public static final COND_DECL_PREFIX_KEYWORD_KINDS: Array<String> = ['EnumKw', 'AbstractKw', 'FinalKw'];

	/** The grammar kind a `typedef` projects as — the only member host whose members sit under an `Anon`. */
	private static final TYPEDEF_DECL_KIND: String = 'TypedefDecl';

	/** The grammar kind an anonymous structure projects as, in BOTH a typedef body and a type expression. */
	private static final ANON_KIND: String = 'Anon';

	/**
	 * Node kinds an expression subtree may contain and still be
	 * SIDE-EFFECT-FREE: literals, bare identifiers, parenthesised groups, and
	 * the pure binary / unary / ternary operators. The string-payload leaf
	 * `Literal` is included so a plain (non-interpolated) string passes — an
	 * INTERPOLATED string instead nests `Ident` / `Block` children (the
	 * spliced expression / variable), neither of which is whitelisted, so it
	 * is correctly excluded. The increment / decrement ctors are deliberately
	 * absent — they mutate their operand. Shared by `Inline` (inline-var
	 * substitution safety) and the `unused-local` check (delete-fix safety).
	 */
	private static final SAFE_KINDS: Array<String> = [
		// Literals + the plain-string content leaf.
		'IntLit',
		'FloatLit',
		'BoolLit',
		'NullLit',
		'DoubleStringExpr',
		'SingleStringExpr',
		'Literal',
		// Bare identifier + paren group.
		'IdentExpr',
		'ParenExpr',
		// Binary operators (HxExpr Pratt set, mutating assigns excluded).
		'Add',
		'Sub',
		'Mul',
		'Div',
		'Mod',
		'And',
		'Or',
		'Eq',
		'NotEq',
		'Lt',
		'Gt',
		'LtEq',
		'GtEq',
		'BitAnd',
		'BitOr',
		'BitXor',
		'Shl',
		'Shr',
		'UShr',
		'NullCoal',
		// Unary operators + ternary.
		'Neg',
		'Not',
		'BitNot',
		'Ternary'
	];

	/**
	 * Whether `kind` is one of the modifier / metadata siblings a declaration projects BEFORE itself
	 * (`MODIFIER_META_KINDS`). Address resolution asks this to walk a bare line number past a
	 * `public static` prefix onto the declaration the line actually declares.
	 */
	public static inline function isModifierOrMetaKind(kind: String): Bool {
		return MODIFIER_META_KINDS.contains(kind);
	}

	/** Is `kind` a class-member declaration (field / method)? */
	public static inline function isFieldMemberKind(kind: String): Bool {
		return FIELD_MEMBER_KINDS.contains(kind);
	}

	/** Is `kind` a member that HOLDS a value — a data field rather than a method? */
	public static inline function isDataFieldKind(kind: String): Bool {
		return DATA_FIELD_KINDS.contains(kind);
	}

	/**
	 * Whether `kind` declares a member. `isFieldMemberKind` plus the enum constructors and
	 * the three conditional member forms `HxClassMember` dispatches BEFORE their plain
	 * twins (`var x … #if … ;`, `function #if a f #else g #end`, a `#if` splice at member
	 * scope). Each of those carries a signature and a body like any member, so a walk
	 * looking for member HOSTS has to recognise them or it descends into one.
	 */
	public static inline function isMemberDeclKind(kind: String): Bool {
		return isFieldMemberKind(kind) || isEnumConstructorKind(kind) || kind == 'VarSemiCondInitMember' || isOpaqueMemberKind(kind);
	}

	/**
	 * Is `kind` an ENUM CONSTRUCTOR — a member whose NAME the enum's declaration binds into every
	 * scope the enum itself reaches, so that `case A(x)` names it with the enum nowhere in sight?
	 *
	 * The distinction a member-name scan cannot make for itself once the constructors are in the
	 * index (`isMemberDeclKind` above is what puts them there, so that `unused-import` keeps a bare
	 * `import pkg.Enum;` alive for a file that only uses them). `MoveSymbol` needs the other half:
	 * a file that only ever spells `A` still loses the type when the enum leaves the module it
	 * imported, so the constructors have to join the name scan that decides whether a module
	 * statement still owes that file anything (`Unknown identifier : A` on
	 * `Pony/pony/ServiceProvider.hx` after `OrState` left `pony.Or`, compile-proved both ways).
	 */
	public static inline function isEnumConstructorKind(kind: String): Bool {
		return kind == 'SimpleCtor' || kind == 'ParamCtor';
	}

	/**
	 * Whether `kind` is a member form whose declared NAMES the projected tree does not carry: a `#if`
	 * region spliced at member scope (`CondSpliceMember`) and a `function` whose name is itself a
	 * region (`CondNameFnMember`). The two lose their names for DIFFERENT reasons — `CondSpliceMember`
	 * is raw in the grammar itself (`HxCondSharedBodyMember` swallows the whole region as
	 * `HxCondSpliceRaw`), while `CondNameFnDecl` models the region structurally as
	 * `HxConditionalFnName {cond, name, elseifs, elseName}` and only the QUERY PROJECTION drops it to a single
	 * child, keeping the then-name and losing every `#else` / `#elseif` name. Either way the member
	 * node answers no `name`, so a scan collecting declared names reads the region as declaring
	 * nothing. `VarSemiCondInitMember` is deliberately NOT here: only its INITIALIZER is guarded, its
	 * name sits outside the region and IS exposed.
	 *
	 * The blindness is invisible to a re-parse gate, because a duplicate declaration is a SEMANTIC
	 * error — so `AddMember` refuses a host carrying one of these, and refuses a member text that is
	 * one, rather than trusting the empty answer. The other member-writing ops do NOT yet: the ops
	 * routed through `MemberBranchScan.declaresMemberNamed` (`CrossRenameMember`, `EncapsulateField`,
	 * `ExtractConstant`) filter on `isFieldMemberKind` alone and stay blind to both kinds.
	 */
	public static inline function isOpaqueMemberKind(kind: String): Bool {
		return kind == 'CondNameFnMember' || kind == 'CondSpliceMember';
	}

	/**
	 * Whether a walk looking for member declarations should descend from a `parentKind`
	 * node into a `childKind` one. Split out of `eachMemberHost` for a walk that threads
	 * its own state down the tree (`unused-private` carries an `extends` flag) and so
	 * cannot delegate the recursion itself — the pruning knowledge still lives here.
	 */
	public static inline function descendsToMemberHost(parentKind: String, childKind: String): Bool {
		return !isMemberDeclKind(childKind) && (parentKind == TYPEDEF_DECL_KIND || childKind != ANON_KIND);
	}

	/**
	 * A node kind that contributes no side effect on its own: an enumerated
	 * `SAFE_KINDS` member, or any leaf whose kind ends with `Lit` / `StringExpr`
	 * (a literal payload not separately enumerated).
	 */
	public static inline function isSafeKind(kind: String): Bool {
		return SAFE_KINDS.contains(kind) || kind.endsWith('Lit') || kind.endsWith('StringExpr');
	}

	/**
	 * Whether a member of a `declKind` type is static WITHOUT saying so — the grammar's
	 * `RefShape.implicitStaticFieldHostKinds` answer, narrowed to data members because an
	 * abstract's METHODS may be either and there the modifier still decides.
	 *
	 * Shared by the member operations, because a MODIFIER-only read routes an `enum abstract`
	 * value to the INSTANCE path — whose receiver resolution looks for a binding holding a
	 * VALUE of the type, and so never matches the type used as a namespace.
	 *
	 * OVER-REPORTS THE PROPERTY FORM, compiler-probed: `abstract A(Int) { public var
	 * length(get, never): Int; }` is legal and `length` is an INSTANCE member (`a.length`
	 * compiles; `A.length` errors `Cannot access non-static abstract field statically`), yet
	 * the query projection drops the accessor clause — it emits a bare `(VarMember length)`,
	 * indistinguishable from an `enum abstract` value. A caller that only picks a resolution
	 * path over-approximates harmlessly; a caller that WRITES must refuse the shape instead of
	 * trusting the answer (`MoveMember.resolveMovedMembers` does).
	 */
	public static function implicitlyStaticMember(declKind: String, memberKind: String, refShape: RefShape): Bool {
		final hosts: Null<Array<String>> = refShape.implicitStaticFieldHostKinds;
		return hosts != null && hosts.contains(declKind) && isDataFieldKind(memberKind);
	}

	/**
	 * Visit `node` and every descendant that can HOST a member declaration, so a caller can
	 * scan each host's direct children. Descends through wrappers — a `#if` region puts a
	 * member one level down, a typedef puts its fields under an `Anon` — but stops at the
	 * two places an anonymous structure is written as a TYPE rather than as a member list:
	 * inside a member (its annotation or its body) and in a declaration's own header (a
	 * type-parameter constraint, a heritage type argument, an abstract's underlying). An
	 * `{ var x:Int; }` there projects the very kinds a member does (`VarField` /
	 * `FinalField`), so descending reports its fields as members of the enclosing type —
	 * a phantom that has bitten the symbol index and `remove-member` alike.
	 *
	 * For a TYPE's members prefer `MemberBranchScan.eachTypeMember`, which additionally recovers
	 * the branch boundaries a flattened region loses, so each member sees the modifier run of its
	 * OWN branch. Either beats iterating a type node's `children` directly: that shortcut sees no
	 * member a `#if` region declares, and the miss is silent — the op reports success on a rewrite
	 * that omits the guarded declaration, or refuses a member that plainly exists.
	 */
	public static function eachMemberHost(node: QueryNode, visit: QueryNode -> Void): Void {
		visit(node);
		for (child in node.children) if (descendsToMemberHost(node.kind, child.kind)) eachMemberHost(child, visit);
	}

	/**
	 * Whether a `macro` modifier (kind `macroKind`) precedes the sibling at `index`
	 * within its modifier run. A member's modifiers project as separate childless,
	 * nameless sibling nodes immediately before it (`public static macro function f`
	 * → `(Public)(Static)(Macro)(FnMember f)`), so the run is scanned BACKWARD from
	 * `index`: a `macroKind` sibling means the member is macro-modified; a sibling for
	 * which `isResetBoundary` holds ends the run — the previous member or annotation,
	 * whose modifiers are not this one's. Pure modifier nodes (childless, nameless,
	 * non-boundary) are skipped over. `macroKind` null → always false.
	 *
	 * The reset boundary is the caller's, because it differs by intent: the call graph
	 * ends a run at ANY named or child-bearing node, the void-return check at a member
	 * declaration. Both agree for every valid Haxe modifier arrangement (the macro
	 * modifier always sits in a contiguous childless run right before its function), so
	 * the parameter preserves each caller's exact policy rather than unifying them.
	 */
	public static function macroModifierPrecedes(
		siblings: Array<QueryNode>, index: Int, macroKind: Null<String>, isResetBoundary: QueryNode -> Bool
	): Bool {
		if (macroKind == null) return false;
		var i: Int = index - 1;
		while (i >= 0) {
			final sib: QueryNode = siblings[i];
			if (sib.kind == macroKind) return true;
			if (isResetBoundary(sib)) return false;
			i--;
		}
		return false;
	}

	/**
	 * Is every node kind in `node`'s subtree side-effect-free per `SAFE_KINDS`?
	 * A strict WHITELIST: an unknown kind fails the walk, so the verdict is
	 * conservative — a missed-but-safe kind costs a spurious `false`, never an
	 * unsafe `true`. Calls, field / index access, object / array / map literals,
	 * lambdas, `new`, assignments, increment / decrement, and interpolated
	 * strings embedding any of these all fall outside the whitelist and yield
	 * `false`.
	 */
	public static function isSideEffectFree(node: QueryNode): Bool {
		var safe: Bool = true;
		function walk(n: QueryNode): Void {
			if (!safe) return;
			if (!isSafeKind(n.kind)) {
				safe = false;
				return;
			}
			for (c in n.children) walk(c);
		}
		walk(node);
		return safe;
	}

	/**
	 * Whether spanned nodes `a` and `b` cover the same (trimmed) source text. Both
	 * must carry a span — a null span yields `false`, since the texts cannot be
	 * compared.
	 */
	public static function sameSource(a: QueryNode, b: QueryNode, source: String): Bool {
		final sa: Null<Span> = a.span;
		final sb: Null<Span> = b.span;
		return sa != null && sb != null && source.substring(sa.from, sa.to).trim() == source.substring(sb.from, sb.to).trim();
	}

	/** Whether the subtree rooted at `node` contains any node of kind `kind`. */
	public static function subtreeContainsKind(node: QueryNode, kind: String): Bool {
		return node.kind == kind || node.children.exists(c -> subtreeContainsKind(c, kind));
	}

	/**
	 * Whether the subtree rooted at `node` contains — within the same scope — any node
	 * whose kind is in `kinds`, descending through children but STOPPING at (and not
	 * matching) a node whose kind is in `stopKinds`. The root `node` itself is not
	 * tested; only its descendants. The kind-set + stop-set generalization of
	 * `subtreeContainsKind`: the stop-set bounds the walk to one scope — e.g. a
	 * value-return / throw search that must not cross into a nested function or lambda.
	 */
	public static function subtreeContainsKindStopping(node: QueryNode, kinds: Array<String>, stopKinds: Array<String>): Bool {
		return node.children.exists(
			child -> !stopKinds.contains(child.kind) && (kinds.contains(child.kind) || subtreeContainsKindStopping(child, kinds, stopKinds))
		);
	}

	/**
	 * Index every node of one of `kinds` by its `from:to` span key — the lookup table
	 * a span-keyed-violation `fix` uses to recover the AST node behind a stored span.
	 * Shared by the `redundant-cast` / `redundant-null-coalescing` autofixes.
	 */
	public static function indexNodesByKind(node: QueryNode, kinds: Array<String>, out: Map<String, QueryNode>): Void {
		if (kinds.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexNodesByKind(c, kinds, out);
	}

	/**
	 * Recursive kind / name / arity equality over two subtrees — the shared SHAPE-identity
	 * predicate. Spans and source formatting are ignored, so two nodes compare equal when
	 * they project the same tree regardless of where they sit or how they are laid out.
	 * `Matcher` uses it to enforce a reused metavariable (`$x` twice in one pattern must
	 * capture the same shape); `tail-merge` uses it as one half of its tail-identity test
	 * (paired with a whitespace-normalized source comparison, since shape equality alone
	 * cannot see a comment sitting INSIDE a statement's span).
	 */
	public static function structurallyEqual(a: QueryNode, b: QueryNode): Bool {
		if (a.kind != b.kind) return false;
		if (a.name != b.name) return false;
		// The type SLOT is not a child, so a walk over `children` alone reported
		// `(e : String)` and `(e : Bytes)` — and `final x:Int = 1` and `final x:String = 1` —
		// as the SAME shape: the annotation is the only thing telling them apart. Both null
		// is equal (an unannotated pair); one null is not. Inlined rather than given its own
		// helper: this type is already an `oversized-type`, and the test is two lines.
		final aType: Null<QueryNode> = a.type;
		final bType: Null<QueryNode> = b.type;
		if (aType == null || bType == null) {
			if (aType != bType) return false;
		} else if (!structurallyEqual(aType, bType))
			return false;
		if (a.children.length != b.children.length) return false;
		for (k in 0...a.children.length) if (!structurallyEqual(a.children[k], b.children[k])) return false;
		return true;
	}

	/**
	 * The class-like container kinds — `visibilityContainerKinds` minus the
	 * abstract-without-instance-fields kinds (`AbstractDecl` / `EnumAbstractDecl`),
	 * whose members share one underlying `this` rather than declared instance fields.
	 * The scope in which a constructor-initialised field can be moved to its declaration.
	 */
	public static function classLikeContainerKinds(shape: RefShape): Array<String> {
		final all: Array<String> = shape.visibilityContainerKinds ?? [];
		return [for (k in all) if (k != 'AbstractDecl' && k != 'EnumAbstractDecl') k];
	}

	/**
	 * EVERY kind that projects a function VALUE nested inside code — the lambdas in every
	 * spelling (`lambdaKinds`, which already carries the anonymous `fnExprKind`), the NAMED
	 * function literal (`namedFnExprKind`), and the local function declarations in both the
	 * plain (`localFunctionKinds`) and the `inline` (`inlineFunctionKinds`) form.
	 *
	 * THE authority for that question. Five checks used to answer it by hand and only two of
	 * the five hand sets were complete: the named literal is declared in no other kind-set, so
	 * `return-reassign-ternary` and `shadowing-local` had each silently omitted it, and a
	 * grammar adding a sixth spelling would have re-opened the same hole in all five at once.
	 * Derived rather than declared, so it can never fall behind the pieces it unions —
	 * a plugin that adds a lambda spelling to `lambdaKinds` widens this set with it.
	 *
	 * It is NOT the same question as "does this node open a new scope": a method declaration
	 * (`functionKinds`) opens one and is not a function value, so a consumer asking the scope
	 * question unions this set with its own, and documents the extra (`shadowing-local`,
	 * `trivial-getter`).
	 */
	public static function nestedFunctionKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		inline function add(kinds: Null<Array<String>>): Void {
			if (kinds != null) for (k in kinds) if (!out.contains(k)) out.push(k);
		}
		add(shape.lambdaKinds);
		add(shape.fnExprKind == null ? null : [shape.fnExprKind]);
		add(shape.namedFnExprKind == null ? null : [shape.namedFnExprKind]);
		add(shape.localFunctionKinds);
		add(shape.inlineFunctionKinds);
		return out;
	}

	/**
	 * Span starts of the member declarations of `container` that carry a `static` modifier.
	 *
	 * Member-position `#if` regions are descended into: a guarded `static var` read as an instance
	 * field is the unsafe direction (its constructor assignment does not mean what a declaration
	 * initializer means). Branches are read as ONE flat run, and a `static` reaching a region from
	 * before it, or carried out of one, marks the members on both sides — over-marking is the safe
	 * direction here, since a member the reading calls static is one no caller will move.
	 */
	public static function staticMemberFroms(container: QueryNode, shape: RefShape): Array<Int> {
		final staticKind: Null<String> = shape.staticModifierKind;
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final out: Array<Int> = [];
		if (staticKind == null) return out;
		collectStaticFroms(container, staticKind, members, false, out);
		return out;
	}

	/**
	 * The member host whose DIRECT children hold `member` — `container` itself, or the
	 * member-position conditional region one level down that actually declares it.
	 *
	 * Every sibling-run walk needs the real parent. Handed the container for a guarded member,
	 * `declGroupSpan` finds no sibling index and degrades to the bare node span, so a deletion built
	 * from it leaves the member's `private` / `@:meta` run behind — dangling text that does not parse.
	 * Falls back to `container` when `member` is not found under it at all, which keeps every
	 * pre-existing caller's behaviour byte for byte.
	 */
	public static function memberHostOf(container: QueryNode, member: QueryNode): QueryNode {
		var found: QueryNode = container;
		eachMemberHost(container, host -> if (host.children.contains(member)) found = host);
		return found;
	}

	/**
	 * Collect the `from` of every static member under `host` into `out`, returning the modifier-run
	 * state the host's children leave behind. Descends into every nested member host — a
	 * member-position `#if` region above all — carrying `incoming` in, because a `static` written
	 * before the `#if` modifies the first member of whichever branch compiles, and carrying the
	 * region's own leftover out, because a region ending on `static` modifies the member after
	 * `#end`. Branches are read as one flat run: the question is only WHICH members are static, and
	 * a member the flat reading calls static is one no caller will move.
	 */
	private static function collectStaticFroms(
		host: QueryNode, staticKind: String, members: Array<String>, incoming: Bool, out: Array<Int>
	): Bool {
		var pending: Bool = incoming;
		for (child in host.children) {
			if (child.kind == staticKind)
				pending = true;
			else if (members.contains(child.kind)) {
				if (pending) {
					final sp: Null<Span> = child.span;
					if (sp != null) out.push(sp.from);
				}
				pending = false;
			} else if (descendsToMemberHost(host.kind, child.kind))
				// OR, not assignment: a `#if A static #end` region leaves `static` pending for the
				// member after `#end` in the A build, and a region that consumed it leaves nothing —
				// but `incoming` still reaches that member in the build where A is false. Over-marking
				// is the safe direction for this function (a member the flat reading calls static is
				// one no caller will move); dropping `incoming` was the unsafe one.
				pending = collectStaticFroms(child, staticKind, members, pending, out) || pending;
		}
		return pending;
	}

}
