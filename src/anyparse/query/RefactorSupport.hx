package anyparse.query;

import anyparse.format.comment.CommentLossException;
import anyparse.query.MemberBranchScan;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

import anyparse.query.GrammarPlugin.RefShape;

/**
 * Outcome of a source-mutation operation: `Ok` carries the rewritten
 * source, `Err` a human-readable diagnostic. Shared by the structural
 * INSERT / REPLACE ops (`AddMember` / `AddImport` / `ReplaceNode`),
 * which all funnel their finalize through `RefactorSupport.canonicalize`
 * and therefore return the same shape.
 */
enum EditResult {

	Ok(text: String);
	Err(message: String);

}

/**
 * What a declaration's HEAD says about its type, as `RefactorSupport.declaredType` reads it off the
 * source text (the tree carries no type child for a local or a field).
 *
 * Three cases, not two, because the reader can FAIL. `Absent` is a positive statement — the head
 * holds no annotation, so the initializer's own type is the declared one — and a consumer may act
 * on it; `Unreadable` says only that the scan could not attribute an annotation, and a consumer
 * that would treat absence as a PROOF must refuse there instead. The distinction is load-bearing:
 * `final stack:pkg.stack = []` puts a standalone occurrence of the declared name in the TYPE's own
 * tail, so the naive "no `:` after the name" test reads the annotation as absent and would hand a
 * caller a proof it never had. A consumer that only TRANSCRIBES an annotation (there is nothing to
 * copy either way) may collapse the two.
 */
enum DeclaredType {

	/** The head writes no type annotation — the initializer types the binding. */
	Absent;

	/** The head writes `: <text>`; `text` is the annotation's verbatim source, trimmed. */
	Written(text: String);

	/** The head carries a type the scan could not attribute to the declared name — nothing is proven. */
	Unreadable;

}

/**
 * One resolved top-level type declaration, normalised across the plain
 * and `final`-wrapped grammar shapes so every consumer compares uniformly.
 *
 *  - A plain `class C {}` parses as a single `ClassDecl C` node — `name`
 *    and `kind` come from the node, both `nameNode` and `declNode` ARE the
 *    node, and `fullSpan` is the node's own span.
 *  - A `final class C {}` parses as `FinalDecl(ClassForm C …)` — the OUTER
 *    `FinalDecl` carries NO name and a span that INCLUDES the `final `
 *    keyword; the INNER `ClassForm` carries the name `C` and a span that
 *    EXCLUDES `final `. For this shape `kind` is normalised to `ClassDecl`
 *    (a final class IS a class), `nameNode` is the inner `ClassForm` (it
 *    holds the name token, so `identTokenContains` and the decl-name
 *    occurrence anchor on it), `declNode` is the OUTER `FinalDecl`, and
 *    `fullSpan` is that node's span so a move cuts `final class C {…}` WITH
 *    its `final ` keyword.
 *
 * `final` is the only modifier that WRAPS a decl (it is legal in Haxe
 * only on `class` — `final interface` / `final abstract` are parse
 * errors). Every other modifier (`private` / `public` / `extern`) is a
 * SEPARATE preceding sibling node (`Private` / `Extern`) that leaves the
 * named decl node a plain `ClassDecl` / … — those already resolve through the
 * node-on-node branch, so no wrapper handling is needed for them. They are NOT
 * in `fullSpan` either: a caller that must cover them (a cut, a replace) folds
 * the group with `declGroupSpan(declNode, …)`, which is what `declNode` is for.
 */
typedef TypeDeclMatch = {
	var name: String;
	var kind: String;
	var nameNode: QueryNode;
	var declNode: QueryNode;
	var fullSpan: Span;
}

/**
 * The MODULE a type is declared in, in the three shapes a qualified reference needs.
 *
 *  - `path` — the module's full dotted path (`pkg.Mod`, or bare `Mod` in the root package).
 *  - `pkg` — the module's package (`''` in the root package).
 *  - `base` — the module's basename, i.e. the name its MAIN type must carry.
 *
 * A dotted reference names a type THROUGH this path, so a cross-file rewrite compares the
 * receiver's WHOLE path against what `qualifiedPaths` makes legal — never against the
 * reference's last segment, which a same-named module in another package also satisfies.
 */
typedef ModulePath = {
	final path: String;
	final pkg: String;
	final base: String;
}

/**
 * Lexical classification of one word-boundary occurrence of an identifier. Drives the naming
 * completeness gate: `ActiveCode`, `ConditionalRaw`, `StringLiteral` and `DirectiveComment` block
 * the rename; `StringWord` is ignored; `CommentTrivia` renames along when the name is distinctive
 * enough to be worth rewriting in prose, and is otherwise ignored too.
 *
 * Only a class that can carry a REFERENCE blocks. `StringLiteral` vs `StringWord` draws that line
 * inside a string: a literal that NAMES the identifier can be a by-name lookup
 * (`Reflect.field(o, 'edit')`), a literal that merely contains the word cannot (`t('Can edit')`).
 * A comment is on the far side of the same line — it does not execute at all, so no form of it can
 * make a rename unsafe; the worst case is a sentence that ages. A `noqa` is the exception, and it
 * is not `CommentTrivia` but `DirectiveComment`: it addresses the TOOL, and the tool must obey.
 */
enum abstract OccurrenceClass(Int) {

	final ActiveCode = 0;
	final ConditionalRaw = 1;
	final CommentTrivia = 2;
	final StringLiteral = 3;
	final DirectiveComment = 4;
	final StringWord = 5;

}

/**
 * One classified word-boundary occurrence: the span of the matched identifier
 * and its lexical class.
 */
typedef ClassifiedOccurrence = {
	final span: Span;
	final kind: OccurrenceClass;
};

/**
 * Kind of a lexically-scanned non-code source region (comment, string or regex literal).
 */
private enum abstract LexRegionKind(Int) {

	final LineComment = 0;
	final BlockComment = 1;
	final StringLit = 2;
	final RegexLit = 3;

}

/** A lexically-scanned non-code region: `[from, to)` and its kind. */
private typedef LexRegion = {
	final from: Int;
	final to: Int;
	final kind: LexRegionKind;
};

/**
 * The declaration side of a null-guarded constructor-default fold: the field name and
 * its declaration span, the `(default, null)` property head to drop (null for a plain
 * `var`), the default expression, and the ` = <default>` region the fold deletes.
 */
private typedef FoldableDecl = {
	final name: String;
	final span: Span;
	final dropped: Null<Span>;
	final initSpan: Span;
	final initDrop: Span;
};
/**
 * The constructor side of a null-guarded constructor-default fold: the whole
 * `if (p != null) x = p;` statement to replace, the assignment target and the guarded
 * parameter to rebuild it from, and the bytes the assignment ended with.
 */
private typedef GuardedCtorInit = {
	final stmt: Span;
	final target: Span;
	final param: String;
	final terminator: String;
};
/**
 * Cursor-resolution and identifier/span primitives shared by the scope-correct refactoring
 * operations (`Rename`, `Inline`). Every member is `public static` and behaviour-preserving: the
 * bodies were lifted verbatim out of `Rename` once a second consumer (`Inline`) needed the same
 * cursor-to-binding resolution and word-boundary identifier-token logic. Keeping them here means
 * the two operations cannot drift apart.
 *
 * Coordinate convention: callers feed `cursor` as a raw UTF-16 offset (the operations invert the
 * `apq refs` printed column before calling). The helpers never re-implement scope analysis — they
 * ride on top of the `Refs.find` resolver and operate on `QueryNode` spans only.
 */
@:nullSafety(Strict)
final class RefactorSupport {

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
		'FinalField',
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
		'FnField',
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
		'LocalFnStmt',
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
		'AbstractDecl',
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

	/**
	 * Class-member declaration kinds (fields / methods). A binding whose
	 * decl node carries one of these kinds is a class member, not a local
	 * — used to gate `this.<name>` augmentation in `Rename` and to refuse
	 * inlining a free identifier that may be a property getter in
	 * `Inline`. `FinalModifiedMember` is the `final` METHOD form
	 * (`final function f()`); the query projection surfaces its name off
	 * the inner `HxFinalModifierMember.fn`, so it is a member like
	 * `FnMember` for `this.<name>` purposes.
	 * The doc-comment opener — what distinguishes documentation from a plain `/* … *\/` banner.
	 */
	private static final DOC_OPEN: String = '/**';

	/** The grammar kind a `typedef` projects as — the only member host whose members sit under an `Anon`. */
	private static final TYPEDEF_DECL_KIND: String = 'TypedefDecl';

	/**
	 * How many characters of an unparsed conditional-compilation region a refusal diagnostic quotes
	 * back — enough to recognise the region in the file, short enough to keep the message one line.
	 */
	private static inline final REGION_EXCERPT_CHARS: Int = 60;


	/** The grammar kind an anonymous structure projects as, in BOTH a typedef body and a type expression. */
	private static final ANON_KIND: String = 'Anon';

	/** The grammar kind a dotted member access projects as — one link of a receiver chain. */
	public static final FIELD_ACCESS_KIND: String = 'FieldAccess';

	/** The grammar kind a bare identifier projects as — the root of a receiver chain. */
	public static final IDENT_EXPR_KIND: String = 'IdentExpr';

	/** The numeric escapes that spell the interpolation trigger `$` (see `interpolationEscapeBefore`). */
	private static final DOLLAR_ESCAPES: Array<String> = ['\\x24', '\\u0024'];

	/**
	 * Sibling node kinds a declaration's modifiers and metadata project to —
	 * emitted BEFORE the decl they modify (`public static function` is
	 * `(Public)(Static)(FnMember)`; annotations are the `META_KINDS` forms).
	 * `declGroupSpan` folds a run of these plus the decl into one logical
	 * element so a structural edit treats the whole `[@:meta modifiers… decl]`
	 * as a unit, not the decl keyword alone. The member-level `abstract`
	 * modifier (Haxe 4.2 abstract classes) projects as its own `(Abstract)`
	 * sibling and IS here. `final` is NOT — it WRAPS its decl (`FinalDecl` /
	 * `FinalModifiedMember` / `FinalMember`) instead of projecting to a
	 * separate sibling.
	 */
	private static final MODIFIER_META_KINDS: Array<String> = META_KINDS.concat([
		'Public',
		'Private',
		'Static',
		'Inline',
		'Override',
		'Macro',
		'Extern',
		'Dynamic',
		'Abstract'
	]);

	/**
	 * Whether `kind` is one of the modifier / metadata siblings a declaration projects BEFORE itself
	 * (`MODIFIER_META_KINDS`). Address resolution asks this to walk a bare line number past a
	 * `public static` prefix onto the declaration the line actually declares.
	 */
	public static inline function isModifierOrMetaKind(kind: String): Bool {
		return MODIFIER_META_KINDS.contains(kind);
	}

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
		'Ternary',
	];

	/**
	 * Simple names of stdlib value / container types whose methods never reassign an
	 * abstract `this`, so a method call on a binding of one is not a write that blocks
	 * `final`: `String` is immutable; `Array` / `Map` and the others mutate their
	 * contents, not the binding. The `final`-conversion checks keep suggesting `final`
	 * for such bindings even when their type is not resolvable in the lint scope.
	 *
	 * This MUTABILITY fact is NOT derivable from a declaration — a method signature
	 * never states whether it reassigns `this` — so, unlike the extension-method and
	 * static-return tables now derived from the std sources via `StdResolver`, this
	 * list is intrinsic semantic knowledge and stays hand-maintained.
	 */
	private static final finalSafeStdlibTypes: Array<String> = [
		'String',
		'Array',
		'Map',
		'List',
		'Vector',
		'StringBuf',
		'StringMap',
		'IntMap',
		'ObjectMap',
		'EnumValueMap',
		'Bytes',
		'BytesBuffer',
		'EReg',
		'Date',
		'Xml'
	];

	/** Is `kind` a class-member declaration (field / method)? */
	public static inline function isFieldMemberKind(kind: String): Bool {
		return FIELD_MEMBER_KINDS.contains(kind);
	}

	/** Is `kind` a member that HOLDS a value — a data field rather than a method? */
	public static inline function isDataFieldKind(kind: String): Bool {
		return DATA_FIELD_KINDS.contains(kind);
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
	 * Whether `kind` declares a member. `isFieldMemberKind` plus the enum constructors and
	 * the three conditional member forms `HxClassMember` dispatches BEFORE their plain
	 * twins (`var x … #if … ;`, `function #if a f #else g #end`, a `#if` splice at member
	 * scope). Each of those carries a signature and a body like any member, so a walk
	 * looking for member HOSTS has to recognise them or it descends into one.
	 */
	public static inline function isMemberDeclKind(kind: String): Bool {
		return isFieldMemberKind(kind) || kind == 'SimpleCtor' || kind == 'ParamCtor' || kind == 'VarSemiCondInitMember'
			|| isOpaqueMemberKind(kind);
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
	 * The last dotted segment of `dotted` — the simple name a plain import binds
	 * (`pkg.sub.Foo` -> `Foo`), and the whole string when it carries no dot at all.
	 *
	 * Purely textual: it splits on the LAST `.` and asks nothing of the tree, so it
	 * is equally correct for an import payload, a canonical type path, a `using`
	 * target and a dotted field path. Callers that need the module-vs-sub-type
	 * distinction (`pkg.Mod.Sub`) must resolve that themselves — this returns `Sub`.
	 */
	public static inline function lastSegment(dotted: String): String {
		final dot: Int = dotted.lastIndexOf('.');
		return dot < 0 ? dotted : dotted.substring(dot + 1);
	}

	/** A name is renameable when it is a valid identifier and not `this`. */
	public static inline function isRenameableName(name: Null<String>): Bool {
		return name != null && name != 'this' && isIdentifier(name);
	}

	public static inline function isIdentStartChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	/** Does `s` begin with an upper-case ASCII letter — the Haxe convention a type name follows, distinguishing a type reference from a lower-case value / package segment? */
	public static inline function isUpperInitial(s: String): Bool {
		final c: Int = s.fastCodeAt(0);
		return c >= 'A'.code && c <= 'Z'.code;
	}

	public static inline function isIdentChar(c: Int): Bool {
		return isIdentStartChar(c) || (c >= '0'.code && c <= '9'.code);
	}

	/** Is `c` an ASCII space / tab / newline / carriage return? */
	public static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/**
	 * Does `name` occur as a word-boundary identifier token within
	 * `source[from, end)` at an offset that lies inside none of `excluded`?
	 * The conservative "is this name referenced" primitive shared by the
	 * dead-code checks: `unused-import` scans the whole file excluding the
	 * import statements; `unused-local` scans a declaration's enclosing scope
	 * excluding the declaration itself. Word-boundary = a non-identifier char on
	 * both sides, so `name` does not match inside `nameSuffix`. A textual scan
	 * (not an AST projection) is deliberate: it catches reference forms the
	 * grammar hides under non-obvious ctors (`'$name'` simple interpolation,
	 * macro reification) at the cost of also counting the name in comments /
	 * strings — which only ever keeps a binding, never wrongly deletes one.
	 * `end` is clamped to the source length. A dotted path's tail counts too
	 * (`this.name` IS a read of member `name`); the callers for which it is not —
	 * `unused-import`, since an import binds a SIMPLE name — take
	 * `referencedUnqualifiedInRange` instead.
	 *
	 * One boundary is not spelled with a boundary CHARACTER: a numeric escape
	 * (`\x24`, `$`) that decodes to the interpolation trigger `$` ends in a
	 * hex digit, so a plain word-boundary test reads `'\x24name'` as one long
	 * token and misses a real read (see `interpolationEscapeBefore`).
	 */
	public static inline function referencedInRange(source: String, name: String, from: Int, end: Int, excluded: Array<Span>): Bool {
		return scanReference(source, name, from, end, excluded, null);
	}

	/**
	 * `referencedInRange` restricted to occurrences that stand as a SIMPLE name —
	 * an occurrence whose preceding non-whitespace character is a qualification
	 * `.` does not count. The test `unused-import` needs: a Haxe import binds a
	 * simple name, while a dotted path resolves from its ROOT
	 * (`haxe.macro.Context.currentPos()` needs no import at all), so a tail
	 * segment never goes through one. The ROOT of a path is not dot-preceded and
	 * still counts — `Mod.VALUE` is exactly what `import pkg.Mod;` provides.
	 *
	 * A SINGLE dot qualifies. `...` is the range / rest operator, not a
	 * qualifier: in `for (i in 0...Limit.MAX)` the name IS dot-preceded, yet it
	 * is a bare reference — reading that as qualification would delete an import
	 * the build needs. Safe navigation (`o?.f`) and a field access inside string
	 * interpolation (`'${o.f}'`) are single-dot field accesses and are correctly
	 * skipped by the same test.
	 *
	 * A SEPARATE method rather than a tightening of `referencedInRange`: the
	 * shared predicate's over-counting is load-bearing for its other callers —
	 * `unused-private` reads `this.field` as a genuine reference, and a stricter
	 * answer there would delete a live member.
	 *
	 * `commentRegions` (`collectCommentRegions`, hoisted once per file by the
	 * caller) is REQUIRED, not a convenience: a line comment ending in a sentence
	 * period puts a `.` directly before the next line's first token, and reading
	 * that as qualification deletes an import the build needs. It is the only
	 * inert construct that can end in a bare `.` — a string / regex / block
	 * comment closes with its own delimiter — but the mask is exact for all of
	 * them and costs one scan per file.
	 */
	public static inline function referencedUnqualifiedInRange(
		source: String, name: String, from: Int, end: Int, excluded: Array<Span>, commentRegions: Array<Span>
	): Bool {
		return scanReference(source, name, from, end, excluded, commentRegions);
	}

	/**
	 * Whether `text` holds a `//` or `/*` comment marker. The primitive under
	 * `hasCommentMarker` and under `CheckScan.hasCommentMarker`, exposed separately for the
	 * callers whose subject is not a contiguous source range — a concatenation of trivia
	 * gaps, or one already-trimmed line.
	 *
	 * Deliberately STRING-BLIND: a marker inside a string literal (`'http://x'`) answers yes.
	 * See `hasCommentMarker` for why that stays.
	 */
	public static inline function textHasCommentMarker(text: String): Bool {
		return text.indexOf('//') >= 0 || text.indexOf('/*') >= 0;
	}

	/**
	 * Whether `[from, to)` of `source` holds a `//` or `/*` comment marker — the "don't
	 * delete a comment" guard every rewriting check consults before regenerating a region.
	 * An empty or reversed range answers no; the guard is load-bearing, since
	 * `String.substring` SWAPS a reversed pair and would otherwise scan the wrong text.
	 *
	 * ## Why it stays string-blind
	 *
	 * The scan cannot tell a real marker from one inside a string literal, so `'http://x'`
	 * reads as a comment. Teaching it about literals would make it answer `false` on inputs
	 * where it now answers `true` — a TIGHTENING, and a shared predicate may only be
	 * tightened when every caller's conservative direction points the same way.
	 *
	 * It does not. For nearly every consumer a spurious `true` REFUSES a rewrite (report-only
	 * instead of autofixed) — harmless, and the direction that never deletes a comment. The
	 * exceptions are `CheckScan`'s negation machinery — `negateConditionText`,
	 * `negationIsClean` and the `eqFlipText` it dispatches through — where the answer is not
	 * a refusal but a TIER SELECTOR: a `true` routes the rewrite to the verbatim text
	 * fallback, and `negationIsClean` then reports the site as clean precisely BECAUSE that
	 * tier declines nothing. Making the scan literal-aware moves such a condition onto the
	 * De Morgan tier, which can decline — flipping a finding off — and changes the text
	 * `eqFlipText` emits. That is a real behaviour change, not extra safety, so the
	 * string-blind answer is the shared contract and any caller that needs precision must
	 * ask the lexical regions (`scanLexicalRegions`) rather than tighten this.
	 */
	public static inline function hasCommentMarker(source: String, from: Int, to: Int): Bool {
		return from < to && textHasCommentMarker(source.substring(from, to));
	}

	/**
	 * The part of `isPrivateMemberConfined` that NO precise gate can refine: no file
	 * skip-parsed (one could hide any writer at all) and no `@:allow` in the member's own
	 * file (which hands its privates to a type the index cannot name from here). The other
	 * two vetoes — subtype and `@:access` grant — name a REACHABLE file each, so a caller
	 * that can scan those files for what it actually fears pairs this with its own gates
	 * instead: `prefer-final-field` asks only whether such a file WRITES the member, since
	 * a read survives `final`.
	 */
	public static inline function privateMemberScanIsSound(source: String, index: SymbolIndex): Bool {
		return index.skippedFiles().length <= 0 && source.indexOf('@:allow') < 0;
	}

	/**
	 * The report + resolution-scope `SymbolIndex` the plugin host carries — a subtype declared in a
	 * configured resolution library, or in the implicitly-scoped Haxe std, is indexed there too — or
	 * null when the plugin is not a resolution host or no scope reached it at all (the caller falls
	 * back to the report index). The eager counterpart of `lazySymbolIndex`, for a check that already
	 * holds a report index and only needs to know whether a WIDER one exists:
	 * `resolutionIndexOf(plugin) ?? index`.
	 *
	 * The null return is now the RARE case rather than the default. A `Cli` run reaches it only when
	 * the project declares no resolution key AND no Haxe std is discoverable — a machine without Haxe,
	 * or one that declined the std via `APQ_NO_STD` / `"resolutionStd": false`. It is still the plain
	 * answer for a direct `check.run` with a bare plugin, which is what the unit tests that pin the
	 * report-only behaviour use.
	 */
	public static inline function resolutionIndexOf(plugin: GrammarPlugin): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		return host != null && host.hasAnyResolutionScope() ? host.resolutionIndex() : null;
	}

	/**
	 * The resolution scope's RAW sources (report UNION the library roots) when `plugin` hosts one, else
	 * null. The text counterpart of `resolutionIndexOf`, for a scan that needs no parse: the index drops
	 * a skip-parsed file from both `allFiles` and `sourceOf`, so a whole-scope TEXT proof read off the
	 * index would treat that file as holding nothing at all.
	 */
	public static inline function resolutionSourcesOf(plugin: GrammarPlugin): Null<Array<{ file: String, source: String }>> {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		return host != null && host.hasAnyResolutionScope() ? host.resolutionFiles() : null;
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
	 * Whether a projected node kind denotes a `#if...#end` region — a block
	 * `Conditional`, an expression `ConditionalExpr`, or any `CondSplice*`
	 * mid-expression / statement splice. An unrecognised conditional kind
	 * degrades to `ActiveCode`, which still blocks — fail-closed.
	 */
	public static inline function isConditionalKind(kind: String): Bool {
		return kind == 'Conditional' || kind == 'ConditionalExpr' || kind.startsWith('CondSplice');
	}

	/**
	 * Resolve the cursor to the named occurrence node it sits on, in two
	 * tiers (innermost-wins within each):
	 *
	 *  1. A named node whose IDENTIFIER TOKEN contains the cursor — the
	 *     precise case (reads / writes whose span is the bare identifier,
	 *     params whose span starts at the name, a cursor placed directly
	 *     on a decl's name).
	 *  2. Failing that, a decl-host-shaped named node whose `span.from`
	 *     EQUALS the cursor — the `apq refs --decls` convention, where the
	 *     printed column maps to the decl's span start (the `var` / `for`
	 *     keyword), not the identifier inside it.
	 *
	 * Returns null when neither tier matches — a cursor on whitespace, a
	 * delimiter, or any non-identifier byte.
	 */
	public static function resolveCursorNode(tree: QueryNode, cursor: Int, source: String): Null<QueryNode> {
		final tokenHit: Null<QueryNode> = innermostWhere(tree, cursor, node -> identTokenContains(node, cursor, source));
		return tokenHit ?? innermostWhere(tree, cursor, node -> {
			final span: Null<Span> = node.span;
			return span != null && span.from == cursor && isRenameableName(node.name);
		});
	}

	/**
	 * Innermost (deepest, last-starting) named node satisfying `pred`
	 * whose span contains `cursor`. Descends the whole tree, keeping the
	 * last match in pre-order — a tighter enclosing node is visited after
	 * its ancestors, so the final assignment is the innermost. `module` /
	 * receiver `this` nodes are excluded via `isRenameableName`.
	 */
	public static function innermostWhere(tree: QueryNode, cursor: Int, pred: QueryNode -> Bool): Null<QueryNode> {
		var best: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && cursor >= span.from && cursor < span.to && isRenameableName(node.name) && pred(node)) best = node;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * Does the identifier token of `node` (the first word-boundary
	 * occurrence of its name within its span) contain `cursor`?
	 */
	public static function identTokenContains(node: QueryNode, cursor: Int, source: String): Bool {
		final span: Null<Span> = node.span;
		final name: Null<String> = node.name;
		if (span == null || name == null) return false;
		final identFrom: Int = identTokenOffset(source, span, name);
		return identFrom >= 0 && cursor >= identFrom && cursor < identFrom + name.length;
	}

	/**
	 * Resolve which binding the cursor node belongs to, as the `from`
	 * offset of that binding's declaration:
	 *
	 *  - The cursor node sits on a Decl hit (`span.from` matches) → the
	 *    decl binds itself.
	 *  - It sits on a Read / Write hit → follow the hit's `bindingSpan`.
	 *  - It is a `this.<field>` field access (no matching ref hit) → the
	 *    member decl of the same name.
	 *
	 * Returns null when nothing resolves (e.g. an unbound cross-file
	 * read).
	 */
	public static function resolveBindingFrom(node: QueryNode, hits: Array<RefHit>): Null<Int> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final nodeFrom: Int = span.from;

		final hit: Null<RefHit> = hits.find(h -> h.span.from == nodeFrom);
		if (hit != null) {
			if (hit.kind == RefKind.Decl) return hit.span.from;
			final boundTo: Null<Span> = hit.bindingSpan;
			return boundTo?.from;
		}

		// Cursor is on a node that the resolver does not emit as a ref
		// hit — the `this.<field>` field-access case. Bind it to the sole
		// member decl of the same name.
		if (node.kind != FIELD_ACCESS_KIND) return null;
		final memberDecl: Null<RefHit> = hits.find(h -> h.kind == RefKind.Decl);
		return memberDecl?.span.from;
	}

	/**
	 * The node in `tree` whose `span.from == from` (first in pre-order).
	 * Drives "what kind of declaration does this binding offset name?" —
	 * `Inline` reads the kind (must be a local `var` / `final`) and the
	 * initializer child off the returned node. Null when no node starts
	 * exactly at `from`.
	 */
	public static function nodeAtFrom(tree: QueryNode, from: Int): Null<QueryNode> {
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			if (found != null) return;
			final span: Null<Span> = node.span;
			if (span != null && span.from == from) {
				found = node;
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
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
	 * Recognise `node` as a top-level type declaration, normalised across
	 * the plain and `final`-wrapped shapes (see `TypeDeclMatch`). Returns
	 * null when `node` is neither a plain type-decl nor a `final class`
	 * wrapper, or when the resolved decl has no name / no span.
	 *
	 *  - `node.kind` ∈ `TYPE_DECL_KINDS` with a name → the node names
	 *    itself (`kind` = the node kind, `fullSpan` = the node's span).
	 *  - `node.kind == 'FinalDecl'` wrapping a named `ClassForm` first
	 *    child → the inner `ClassForm` names the decl; `kind` normalises to
	 *    `ClassDecl` and `fullSpan` is the OUTER span (includes `final `).
	 */
	public static function typeDeclOf(node: QueryNode): Null<TypeDeclMatch> {
		final span: Null<Span> = node.span;
		if (span == null) return null;

		final name: Null<String> = node.name;
		if (name != null && TYPE_DECL_KINDS.contains(node.kind)) return {
			name: name,
			kind: node.kind,
			nameNode: node,
			declNode: node,
			fullSpan: span
		};

		if (node.kind == 'FinalDecl' && node.children.length > 0) {
			final inner: QueryNode = node.children[0];
			final innerName: Null<String> = inner.name;
			if (inner.kind == 'ClassForm' && innerName != null) return {
				name: innerName,
				kind: 'ClassDecl',
				nameNode: inner,
				declNode: node,
				fullSpan: span
			};
		}
		return null;
	}

	/**
	 * The type declaration named `typeName` in `tree`, or null when the module declares none or more
	 * than one — a name that is ambiguous within one file cannot address a single declaration, so
	 * every caller wants the same refusal rather than an arbitrary first match. An empty or omitted
	 * `kinds` filters nothing; a non-empty one keeps only matches whose `TypeDeclMatch.kind` it lists
	 * (a caller that may only address, say, a CLASS).
	 */
	public static function uniqueTypeDeclNamed(tree: QueryNode, typeName: String, ?kinds: Array<String>): Null<TypeDeclMatch> {
		final allow: Array<String> = kinds ?? [];
		final matches: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final match: Null<TypeDeclMatch> = typeDeclOf(node);
			if (match != null && match.name == typeName && (allow.length == 0 || allow.contains(match.kind))) matches.push(match);
			for (child in node.children) walk(child);
		}
		walk(tree);
		return matches.length == 1 ? matches[0] : null;
	}

	/**
	 * Resolve the cursor to the type declaration it sits on: the
	 * innermost (deepest pre-order) decl whose `fullSpan` contains the
	 * cursor and whose name identifier-token contains the cursor OR whose
	 * `fullSpan.from == cursor` (the `apq refs --decls` convention, where
	 * the printed column maps to the decl's span start — the `final` /
	 * `class` / `enum` keyword). Final-aware via `typeDeclOf`. Returns
	 * null when the cursor is not on a type declaration.
	 */
	public static function resolveTypeDeclAtCursor(tree: QueryNode, cursor: Int, source: String): Null<TypeDeclMatch> {
		var best: Null<TypeDeclMatch> = null;
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = typeDeclOf(node);
			if (m != null) {
				final span: Span = m.fullSpan;
				// Three accepted anchors, because a `final class` splits the two spans: the name
				// token, the start of the whole declaration (`final`), and the start of the NAMED
				// node - which for that shape is the inner `ClassForm` at `class`, and is exactly
				// the coordinate `apq refs --decls` prints. Without the third, the documented
				// "copy the position from refs --decls" convention resolved no type declaration
				// for a `final class` and the caller fell through to the value-namespace rename.
				final nameSpan: Null<Span> = m.nameNode.span;
				final onNameStart: Bool = nameSpan != null && nameSpan.from == cursor;
				if (
					cursor >= span.from && cursor < span.to
					&& (identTokenContains(m.nameNode, cursor, source) || span.from == cursor || onNameStart)
				)
					best = m;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/** File basename: the path tail after the last `/`, with a `.hx` suffix removed. */
	public static function baseNameOf(file: String): String {
		final slash: Int = file.lastIndexOf('/');
		final tail: String = slash < 0 ? file : file.substr(slash + 1);
		return tail.endsWith('.hx') ? tail.substr(0, tail.length - '.hx'.length) : tail;
	}


	/**
	 * Every DOTTED path by which a file in package `filePkg` may legally name `typeName`
	 * declared in `module` — the whole set a qualified reference is matched against.
	 *
	 * For `T` in module `pkg.Mod` (file `pkg/Mod.hx`) Haxe accepts:
	 *
	 *  - `T` — from `pkg`, or after an import. Not dotted, so not listed here.
	 *  - `pkg.Mod.T` — from anywhere.
	 *  - `Mod.T` — ONLY from a file in `pkg`; `import pkg.Mod;` does NOT make it legal
	 *    elsewhere. Hence the `filePkg == module.pkg` gate: a ROOT-package module is visible
	 *    as `Mod.T` from every package, so the same text in two packages can name two
	 *    different types, and only the gate keeps a rename off the foreign one.
	 *  - `pkg.Mod` — the MAIN type alone (its name equals the basename); it has no
	 *    `<module>.<type>` form, and in the root package no dotted form at all.
	 */
	public static function qualifiedPaths(typeName: String, module: ModulePath, filePkg: String): Array<String> {
		if (typeName == module.base) return module.path == module.base ? [] : [module.path];
		final out: Array<String> = ['${module.path}.$typeName'];
		if (filePkg == module.pkg && module.path != module.base) out.push('${module.base}.$typeName');
		return out;
	}

	/**
	  * The ONE dotted path that names `typeName` in `module` from every file, whatever its package
	 * or imports: `pkg.Mod` for a module's main type, `pkg.Mod.T` for a sub-module type, and the
	 * basename alone (`Mod` / `Mod.T`) for a root-package module, which is visible everywhere.
	 * The single exception is a ROOT-package module shadowed by a same-named module in the reading
	 * file's own package — Haxe can spell only the near one, so no path reaches the root one.
	 *
	 * The root-anchored counterpart of `qualifiedPaths`: that one lists every spelling a reference
	 * MAY already use, this one is the spelling a rewrite SHOULD emit when it cannot prove which
	 * shorter form is legal at the reading site.
	 */
	public static function rootQualifiedPath(typeName: String, module: ModulePath): String {
		return typeName == module.base ? module.path : '${module.path}.$typeName';
	}

	/**
	 * Whether a BARE `typeName` needs no import to resolve from a file in `filePkg` — which only a
	 * module's MAIN type read from that module's OWN package ever does. A SUB-MODULE type is
	 * invisible bare outside its own module, a sibling file in the same package included.
	 *
	 * The proof every import decision owes before it omits an import. "The two files share a
	 * package" is not that proof, and reading it as one leaves the file naming a type the compiler
	 * cannot find.
	 *
	 * Deliberately conservative in one place: a ROOT-package main type IS visible bare from every
	 * package, but only until the reading file's own package declares the same name, and nothing
	 * here can see out of scope to rule that out — so the answer stays `false` and the caller emits
	 * an `import Mod;` that is redundant rather than a bare name that could bind to the wrong type.
	 * The same-MODULE case (both types in one file, where the bare name always resolves) is not
	 * expressible from `filePkg` alone and is the caller's to exclude.
	 */
	public static inline function bareNameResolves(typeName: String, module: ModulePath, filePkg: String): Bool {
		return typeName == module.base && filePkg == module.pkg;
	}

	/** The dotted path a receiver chain spells (`a.b.C`), or `''` when a link is not a plain name. */
	public static function flattenPath(node: QueryNode): String {
		final name: Null<String> = node.name;
		if (name == null) return '';
		if (node.kind == IDENT_EXPR_KIND) return name;
		if (node.kind != FIELD_ACCESS_KIND || node.children.length == 0) return '';
		final head: String = flattenPath(node.children[0]);
		return head == '' ? '' : '$head.$name';
	}

	/**
	 * Whether `recv` names the type `typeName` used as a NAMESPACE — the receiver half of a
	 * static access the rename owns.
	 *
	 * A bare `IdentExpr` qualifies unless the resolver bound it to a value (`valueResolved`
	 * holds those receiver offsets): an unresolved bare name is the type. A DOTTED receiver
	 * qualifies only when its WHOLE path is one of `qualified` (`qualifiedPaths`); matching its
	 * last segment instead would accept `other.Mod.T` for a rename of `pkg.Mod.T`.
	 */
	public static function receiverIsTypeNamespace(
		recv: QueryNode, typeName: String, qualified: Array<String>, valueResolved: Array<Int>
	): Bool {
		final recvSpan: Null<Span> = recv.span;
		if (recv.name != typeName || recvSpan == null) return false;
		return recv.kind == IDENT_EXPR_KIND
			? !valueResolved.contains(recvSpan.from)
			: recv.kind == FIELD_ACCESS_KIND && qualified.contains(flattenPath(recv));
	}

	/**
	 * Offset of the LAST segment of the dotted `pathName` within `span` — where a rewrite of the
	 * TYPE half of `a.b.C.member` must land. `pathName` is the node's name slot: an `import` /
	 * `using` declaration and a QUALIFIED type reference each carry the whole dotted path there.
	 *
	 * Exact by construction: it finds the path text and steps past its final `.`, where
	 * `identTokenOffset` takes the FIRST word-boundary occurrence of the name in the span and so
	 * mis-lands whenever an earlier segment spells it too (`import Foo.sub.Foo;`). -1 when
	 * `pathName` is null, its last segment is not `typeName`, or the path does not start in `span`.
	 */
	public static function lastSegmentOffset(source: String, span: Span, pathName: Null<String>, typeName: String): Int {
		if (pathName == null || lastSegment(pathName) != typeName) return -1;
		final pathStart: Int = pathOffset(source, span, pathName);
		return pathStart < 0 ? -1 : pathStart + pathName.lastIndexOf('.') + 1;
	}

	/**
	  * Offset at which the dotted `pathName` starts inside `span`, or -1 when `span` does not hold
	 * the whole path contiguously (whitespace around a dot) or `pathName` is null. Both ends are
	 * checked, because the caller turns this into a REPLACEMENT span `[at, at + pathName.length)`.
	 *
	 * Where `lastSegmentOffset` finds the TYPE half of `a.b.C.member`, this finds the whole
	 * receiver: a rewrite that repoints a reference at a type reachable under a DIFFERENT module
	 * must replace the entire path, not its final segment.
	 */
	public static function pathOffset(source: String, span: Span, pathName: Null<String>): Int {
		if (pathName == null) return -1;
		final at: Int = source.indexOf(pathName, span.from);
		return at < 0 || at + pathName.length > span.to ? -1 : at;
	}

	/**
	 * Offset of the first word-boundary occurrence of `name` within
	 * `[span.from, span.to)`, or -1 when not found. A word boundary
	 * requires the characters immediately before and after the match to
	 * be non-identifier characters (or the span edge), so renaming `x`
	 * inside `var x = xs[0]` matches the binding `x`, not the `x` inside
	 * `xs`.
	 */
	public static function identTokenOffset(source: String, span: Span, name: String): Int {
		final from: Int = span.from < 0 ? 0 : span.from;
		final to: Int = span.to <= source.length ? span.to : source.length;
		var i: Int = from;
		while (i + name.length <= to) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + name.length > to) return -1;
			final beforeOk: Bool = at == 0 || !isIdentChar(source.fastCodeAt(at - 1));
			final afterIdx: Int = at + name.length;
			final afterOk: Bool = afterIdx >= source.length || !isIdentChar(source.fastCodeAt(afterIdx));
			if (beforeOk && afterOk) return at;
			i = at + 1;
		}
		return -1;
	}

	/**
	 * Offset of the first word-boundary occurrence of `name` within
	 * `[span.from, span.to)` that lives in code the compiler sees, or -1
	 * when the window holds none. Identical to `identTokenOffset` except
	 * that a match inside COMMENT trivia is skipped, so a comment sitting
	 * between a receiver and its member never wins the race for the member
	 * token (the window a caller derives from two AST spans also contains
	 * every byte of trivia between them).
	 *
	 * String literals and `#if` bodies are deliberately NOT skipped: a
	 * `${obj.member}` interpolation and a conditionally compiled access are
	 * both live references a rename has to reach.
	 */
	public static function activeCodeIdentTokenOffset(source: String, span: Span, name: String): Int {
		final regions: Array<LexRegion> = scanLexicalRegions(source);
		var from: Int = span.from;
		while (from < span.to) {
			final at: Int = identTokenOffset(source, new Span(from, span.to), name);
			if (at < 0 || !offsetWithinComment(at, regions)) return at;
			from = at + 1;
		}
		return -1;
	}

	/**
	 * Whether the type annotation ending at `typeEnd` is a function's RETURN type rather than a
	 * TYPE-PARAMETER CONSTRAINT. The two project into the SAME slot — the child immediately before the
	 * function body — under the same node kind, so `function f<T: Colour>()` and `function f(): Colour`
	 * give byte-identical trees and the slot alone proves nothing. What separates them is the PARAMETER
	 * LIST: a constraint always has one between itself and the body, a return type never does, so a gap
	 * holding no `(` is the discriminator.
	 *
	 * COMMENTS in the gap are skipped through the shared `commentRegionEnd` scan, because a `(` written
	 * inside one cannot be a parameter list. Without that, a block comment or a trailing line comment
	 * between the annotation and the body carried the whole function out of the proof — measured on
	 * both, each a silent refusal.
	 *
	 * A conditional-compilation directive needs no such arm: probed on `function f(): Colour #if
	 * (myflag) return X; #else return X; #end`, the conditional BODY node opens AT the `#if`, so the
	 * directive and its parentheses fall inside the body rather than in the gap. Metadata behaves the
	 * same way — `@:meta("(")` before the body opens at the `@`.
	 *
	 * Every OTHER unknown is answered `false`, which is the direction both callers want: a comment
	 * that does not close before the body, an offset pair that arrives reversed, a `bodyStart` past
	 * the end of the source. That keeps a `(` the scan cannot attribute from ever reading as absent,
	 * and it bounds the scan to the window it was handed. Note what the arm does NOT buy: a comment
	 * can only ever flip a RETURN-type slot, never a constraint slot, because a constraint's `(`
	 * precedes any comment that could follow it. And this project's own writer refuses to round-trip
	 * a comment in that gap at all ("the writer round trip would drop the comment"), so the shapes
	 * the arm accepts are ones no anyparse tool could have produced — a real writer gap, recorded
	 * here because it is what makes the arm look unreachable on this tree.
	 */
	public static function isReturnTypeSlot(source: String, typeEnd: Int, bodyStart: Int): Bool {
		if (typeEnd > bodyStart || bodyStart > source.length) return false;
		var i: Int = typeEnd;
		while (i < bodyStart) {
			final c: Int = source.fastCodeAt(i);
			if (c == '('.code) return false;
			if (c != '/'.code || i + 1 >= bodyStart) {
				i++;
				continue;
			}
			final commentEnd: Int = commentRegionEnd(source, i);
			if (commentEnd < 0)
				i++;
			else if (commentEnd > bodyStart)
				return false;
			else
				i = commentEnd;
		}
		return true;
	}

	/**
	 * The span of the first standalone `name` token within `source[from, stop)` that a `$`
	 * does NOT precede, or null when the window holds none — the BINDER a self-scoped
	 * construct spells first (`for (item in …)`, `var name = …`).
	 *
	 * Word-boundary matching rides on `identTokenOffset`, so the token model stays in one
	 * place; the only thing this adds is the `$` rejection. That one gate is what separates a
	 * binder scan from a REFERENCE scan: `'$name'` is a simple interpolation READ, and a
	 * caller that accepted it would place the binder token inside a string literal — claiming
	 * a shadowed region the declaration never owns (`unused-local`) or renaming an occurrence
	 * that is not the declaration (`guard-continue`'s de-nest). The opposite direction is
	 * `referencedInRange`, which deliberately COUNTS `$name` (and even the `\x24name` escape
	 * spelling) because there a missed read costs a wrongly deleted binding.
	 */
	public static function binderTokenSpan(source: String, from: Int, stop: Int, name: String): Null<Span> {
		var at: Int = from;
		while (at < stop) {
			final hit: Int = identTokenOffset(source, new Span(at, stop), name);
			if (hit < 0) return null;
			if (hit == 0 || source.fastCodeAt(hit - 1) != '$'.code) return new Span(hit, hit + name.length);
			at = hit + 1;
		}
		return null;
	}

	/**
	 * Apply a set of source edits, end-to-start. Edits are sorted
	 * descending by `span.from` and spliced from the highest offset down,
	 * so each splice leaves all lower offsets valid. The caller guarantees
	 * the edits do not overlap. Each edit replaces `[span.from, span.to)`
	 * with `text` (empty `text` deletes the range). Generalises the
	 * splice loop both refactoring operations need.
	 */
	public static function applyEdits(source: String, edits: Array<{ span: Span, text: String }>): String {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var result: String = source;
		for (edit in sorted) result = result.substring(0, edit.span.from) + edit.text + result.substring(edit.span.to);
		return result;
	}

	/**
	 * Finalize a structural mutation through the WRITER, so inserted /
	 * replaced code is formatted by the grammar's own rules rather than
	 * kept as-is. The shared tail of `AddMember` / `AddImport` /
	 * `ReplaceNode`:
	 *
	 *  1. Canonical gate — unless `reformat`, the source must already be
	 *     writer-canonical (`writeRoundTrip(source) == source`). A
	 *     non-canonical file is refused, because a whole-file rewrite would
	 *     also reflow its unrelated hand-wrapping into a surprise diff. The
	 *     mutation commands' `--reformat` opts into that canonicalisation;
	 *     `lint --fix` — which shares this gate — has no such flag, so the
	 *     refusal message leads with `apq fmt --write`, the remedy every
	 *     caller's user can reach.
	 *  2. Splice the caller's edits (raw text) into the source.
	 *  3. Re-emit the WHOLE spliced file through `writeRoundTrip` (the
	 *     trivia / comment-preserving pipeline). This BOTH validates (an
	 *     unparseable splice throws → `Err`) AND canonically formats the
	 *     inserted code together with the rest of the file.
	 *
	 * The caller supplies only the edit position + raw text; indentation
	 * and layout of the result are the writer's job. Requires a grammar
	 * with a writer (`writeRoundTrip` non-null); a writer-less grammar is
	 * refused.
	 *
	 * `optsJson` is the project's writer-config JSON (an `hxformat.json`
	 * discovered near the edited file); passed to BOTH `writeRoundTrip`
	 * calls so the canonical gate and the result agree on the project
	 * style. `null` → the plugin's compiled defaults.
	 */
	public static function canonicalize(
		source: String, edits: Array<{ span: Span, text: String }>, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		if (!reformat) {
			final canon: Null<String> =
				try plugin.writeRoundTrip(
					source, optsJson
				) catch (exception: ParseError) return Err('source does not parse: ${exception.toString()}')
				catch (exception: CommentLossException) return Err(
					'this file cannot be rewritten without losing the comment `${exception.comment}`'
				)
				catch (exception: Exception) return Err('source does not parse: ${exception.message}');
			if (canon == null) return Err('the "${plugin.langName()}" grammar has no writer — cannot writer-format the result');
			// The remedy names `apq fmt --write` FIRST and `--reformat` only as a
			// conditional: this gate is shared with `lint --fix`, which has no
			// `--reformat` flag, and an unconditional "re-run with --reformat" sent that
			// user after a flag their command rejects.
			if (canon != source)
				return Err(
					'file is not in canonical form — format it first (`apq fmt --write <file>`); a command that accepts `--reformat` can canonicalise the whole file in place instead'
				);
		}

		final spliced: String = applyEdits(source, edits);
		final result: Null<String> =
			try plugin.writeRoundTrip(
				spliced, optsJson
			) catch (exception: ParseError) return Err('result does not parse: ${exception.toString()}')
			catch (exception: CommentLossException) return Err(
				'the edit cannot be applied without losing the comment `${exception.comment}` (it may sit anywhere in the file)'
			)
			catch (exception: Exception) return Err('result does not parse: ${exception.message}');
		return result == null ? Err('the "${plugin.langName()}" grammar has no writer — cannot writer-format the result') : Ok(result);
	}

	/**
	 * Stage a cross-file rename all-or-nothing: canonicalize each file's edit
	 * `slice` through `canon` and return every file's rewritten source ONLY when
	 * EVERY slice canonicalizes to a genuinely-changed result. Any `Err`, any
	 * missing source (`sourceOf` returns null), or any no-op slice reverts the
	 * WHOLE set (returns null) — the multi-file counterpart of a single
	 * `canonicalize`, so a partial application can never reach disk. Pure:
	 * `sourceOf` supplies each file's current source and `canon` performs the
	 * per-file canonicalization (`file, source, edits`), both injected by the
	 * caller.
	 */
	public static function stageCrossFileRename(
		slices: Array<{ file: String, edits: Array<{ span: Span, text: String }> }>, sourceOf: (String) -> Null<String>,
		canon: (String, String, Array<{ span: Span, text: String }>) -> EditResult
	): Null<Array<{ file: String, source: String }>> {
		final out: Array<{ file: String, source: String }> = [];
		for (slice in slices) {
			final src: Null<String> = sourceOf(slice.file);
			if (src == null) return null;
			switch canon(slice.file, src, slice.edits) {
				case Ok(text):
					if (text == src) return null;
					out.push({ file: slice.file, source: text });
				case Err(_):
					return null;
			}
		}
		return out.length == 0 ? null : out;
	}

	/** Whole-string check: a non-empty identifier (`[A-Za-z_][A-Za-z0-9_]*`). */
	public static function isIdentifier(s: String): Bool {
		if (s.length == 0) return false;
		final first: Int = s.fastCodeAt(0);
		if (!isIdentStartChar(first)) return false;
		for (i in 1...s.length) if (!isIdentChar(s.fastCodeAt(i))) return false;
		return true;
	}

	/**
	 * The offset just past the whitespace run starting at `from`, bounded by `stop`.
	 * Whitespace ONLY — a comment stops the scan, which is what a caller reading tokens
	 * out of source text wants: `skipForwardTrivia` swallows comments and so hides them
	 * from a comment guard. The canonical home for the hand-scan of a declaration head;
	 * `redundant-property-access` is its first caller, and the private copies still in
	 * `trivial-getter` / `redundant-map-iter-key` / `map-keys-lookup` belong here too.
	 */
	public static function skipSpaces(source: String, from: Int, stop: Int): Int {
		var i: Int = from;
		while (i < stop && isSpace(source.fastCodeAt(i))) i++;
		return i;
	}

	/**
	 * Parse a non-negative decimal integer, returning null when the string
	 * has any non-digit character — so a coordinate like `3:1x` or a
	 * permutation index `2x` is rejected rather than silently resolving to
	 * the leading digits. Shared by the CLI coordinate parser and the
	 * change-signature permutation parser.
	 */
	public static function parseStrictInt(s: String): Null<Int> {
		if (s.length == 0) return null;
		for (j in 0...s.length) {
			final c: Int = s.fastCodeAt(j);
			if (c < '0'.code || c > '9'.code) return null;
		}
		return Std.parseInt(s);
	}

	/**
	 * Push a `[from, from+length)` span into `out`, deduped by `from`: a
	 * non-negative `from` not already in `seen` is recorded and appended.
	 * The dedup-and-collect idiom shared by the occurrence collectors of
	 * `Rename` and `CrossRename` (the same identifier-token offset can be
	 * surfaced by more than one walker).
	 */
	public static function pushUniqueSpan(out: Array<Span>, seen: Array<Int>, from: Int, length: Int): Void {
		if (from < 0 || seen.contains(from)) return;
		seen.push(from);
		out.push(new Span(from, from + length));
	}

	/**
	 * The source span of the LOGICAL declaration at `node` — a decl together
	 * with the modifier / metadata sibling nodes that precede it. Modifiers
	 * (`public` / `private` / `static` / `inline` / `override` / `macro` /
	 * `extern` / `dynamic`) and `@:meta` project to separate siblings BEFORE
	 * the decl they modify, so an edit on the whole declaration must span from
	 * the FIRST of them, and a cursor that resolves to a modifier sibling
	 * targets the decl that follows it. Any element that is not part of a
	 * modifier-decl group (a statement, an array / call element, a package
	 * decl) keeps its own span.
	 *
	 * Shared by `add-element` (insert OUTSIDE the group) and `replace-node`
	 * (replace the WHOLE declaration, modifiers included).
	 */
	public static function declGroupSpan(node: QueryNode, parent: Null<QueryNode>, nodeSpan: Span): Span {
		if (parent == null) return nodeSpan;
		final siblings: Array<QueryNode> = parent.children;
		final i: Int = siblings.indexOf(node);
		if (i < 0) return nodeSpan;

		// The decl is the cursor node, or — when the cursor is on a modifier /
		// meta sibling — the first following sibling that is not one.
		var declIndex: Int = i;
		while (declIndex < siblings.length && MODIFIER_META_KINDS.contains(siblings[declIndex].kind)) declIndex++;
		if (declIndex >= siblings.length) return nodeSpan;

		// Walk back over the modifier / meta run that precedes the decl.
		var startIndex: Int = declIndex;
		while (startIndex > 0 && MODIFIER_META_KINDS.contains(siblings[startIndex - 1].kind)) startIndex--;

		// No modifier / meta run AND the cursor is the decl itself → not a
		// group; leave the span untouched (statements, list elements).
		if (startIndex == declIndex && declIndex == i) return nodeSpan;

		final startSpan: Null<Span> = siblings[startIndex].span;
		final declSpan: Null<Span> = siblings[declIndex].span;
		return startSpan == null || declSpan == null ? nodeSpan : new Span(startSpan.from, declSpan.to);
	}


	/**
	 * Remove `node` (with its modifier / meta group, via `declGroupSpan`)
	 * from `source` — the shared DELETE core, the structural inverse of
	 * `AddElement`. `parent` gives the sibling context `declGroupSpan` and
	 * the comma check need. The deletion span is the decl group, extended to
	 * swallow ONE separating comma when the slot is a comma list (a comma
	 * adjacent in source, or `parent` is a `COMMA_CONTAINER_KINDS`) — else
	 * (statement / case / member / import lists) just the group, since each
	 * element is self-terminated and the whole-file re-emit fixes residual
	 * whitespace. Funnels through `canonicalize` with an empty replacement,
	 * so the result is writer-formatted and re-parse-validated exactly like
	 * the insert ops; the source is canonical-gated unless `reformat`.
	 */
	public static function deleteNode(
		source: String, node: QueryNode, parent: Null<QueryNode>, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = true,
		?optsJson: String
	): EditResult {
		return deleteNodes(source, [{ node: node, parent: parent }], reformat, plugin, withDoc, optsJson);
	}

	/**
	 * Extend a declaration's span back over its leading doc comment, so a replace / remove
	 * can carry (or rewrite) the documentation. Scans back over whitespace from `span.from`;
	 * the block comment immediately above the node is absorbed, then the walk keeps
	 * going back ONLY across further `/**` docs — a stray duplicate left by an earlier
	 * edit — so a stacked duplicate is cleaned up as one unit while a DISTINCT preceding
	 * block comment (a licence header or section banner above the doc) is left intact.
	 * Returns the span unchanged when only whitespace or a non-comment token precedes.
	 * Line-comment (double-slash) doc runs are not handled (v1); the re-parse gate
	 * validates the result either way.
	 *
	 * Two rules decide what that FIRST block is allowed to be. A comment that does not
	 * START its own line trails the PREVIOUS declaration and is never absorbed, for any
	 * caller. And `docOnly` — passed by every caller that DELETES the region rather than
	 * carrying or replacing it — requires the first block to be a `/**` doc as well:
	 * directly above a declaration a plain block comment is a licence header or a section
	 * banner at least as often as it is documentation, and a caller that carries one loses
	 * nothing by guessing wrong while a caller that deletes it cannot get it back.
	 *
	 * Each comment's START comes from `collectCommentTokens` — the lexer's own tokenisation —
	 * never from scanning the text for an opener sequence. A block comment does not nest, so
	 * an opener written INSIDE a doc's text (a backticked example, say) is content; a scan
	 * that searched backwards for one used to cut the doc there, leaving an unterminated
	 * fragment that swallowed the next member's doc, and the same defect made `set-doc`
	 * splice its replacement mid-comment and never converge.
	 */
	public static function docExtendedSpan(source: String, span: Span, docOnly: Bool = false): Span {
		final tokens: Array<{ from: Int, to: Int, isLine: Bool }> = collectCommentTokens(source);
		var from: Int = span.from;
		var first: Bool = true;
		while (true) {
			var i: Int = from - 1;
			while (i >= 0 && isSpace(source.fastCodeAt(i))) i--;
			if (i < 0) break;
			// The preceding token must be a BLOCK comment ending exactly here. Asking the
			// lexer which token that is (rather than scanning back for a `/*`) is what keeps
			// an opener written inside the doc's own TEXT from being mistaken for its start.
			final open: Int = commentEndingAt(tokens, i + 1, true);
			if (open < 0) break;
			// A comment sharing its line with preceding CODE trails THAT declaration —
			// `var keep:Int; /* about keep */` reads as keep's note, however adjacent it
			// looks from below — so attribution follows the line the reader sees it on.
			if (!startsItsLine(source, open)) break;
			// A caller that DELETES what it absorbs passes `docOnly` and gets `/**` as the
			// proof, because the block directly above a declaration is a licence header or a
			// section banner at least as often as it is documentation, and deleting one of
			// those is unrecoverable. A caller that CARRIES the region (`move-member`) or
			// REPLACES it (`set-doc`) loses nothing by the generous reading and keeps it: for
			// them the first block is the declaration's own comment whatever its opener.
			// Further back the rule is `/**` for everyone — that arm exists to sweep up a
			// stacked duplicate, and a distinct block above the doc is somebody else's.
			if ((docOnly || !first) && !isDocOpener(source, open)) break;
			from = open;
			first = false;
		}
		return from == span.from ? span : new Span(from, span.to);
	}

	/**
	 * Cut a declaration's TRAILING trivia — whitespace and whole comment tokens —
	 * off the end of `span`, so a replace / remove / patch covers only the bytes the
	 * declaration owns.
	 *
	 * A ctor annotated `@:trailOpt` whose optional trail token is ABSENT (a `typedef`
	 * or a `final class` written without the `;`, a brace-terminated statement) ends
	 * its parse span where the parser stopped looking for that token — past the blank
	 * line and past the NEXT declaration's doc comment. The parser re-stashes that
	 * run as the following node's LEADING trivia, so the bytes belong to the
	 * neighbour; splicing over the raw span silently deleted a doc block nobody
	 * addressed, and left `Patch` able to match a fragment inside it.
	 *
	 * Each comment's start comes from `collectCommentTokens` — the lexer's own
	 * tokenisation — for the same reason `docExtendedSpan` reads it there: a `/*`
	 * written inside a comment's TEXT is content, not an opener.
	 */
	public static function trailingTrimmedSpan(source: String, span: Span): Span {
		final tokens: Array<{ from: Int, to: Int, isLine: Bool }> = collectCommentTokens(source);
		var to: Int = span.to;
		while (true) {
			var i: Int = to - 1;
			while (i >= span.from && isSpace(source.fastCodeAt(i))) i--;
			if (i < span.from) break;
			to = i + 1;
			final open: Int = commentEndingAt(tokens, to, false);
			// A comment reaching back to (or past) the span's own start is the node
			// itself, not trailing trivia — leave the span alone.
			if (open <= span.from) break;
			to = open;
		}
		return to >= span.to ? span : new Span(span.from, to);
	}

	/**
	 * Extend `span` to the whole physical line when the element is ALONE on
	 * it — swallow the leading indentation (same-line whitespace back to the
	 * line start) and the trailing newline. Without this, deleting a
	 * statement / member / import leaves its line as blank whitespace, which
	 * the trivia-preserving writer keeps as an empty line. When the element
	 * shares its line with other content (it does not start AND end the line)
	 * the span is returned unchanged, so a sibling on the same line is not
	 * touched — the writer re-emit then tidies the residual spacing.
	 *
	 * See `lineDeletionSpan` below for the BACKWARD-only variant, which the case-arm deletions use.
	 */
	public static function lineExtendedSpan(source: String, span: Span): Span {
		var from: Int = span.from;
		while (from > 0) {
			final c: Int = source.fastCodeAt(from - 1);
			if (c == ' '.code || c == '\t'.code)
				from--
			else
				break;
		}
		final startsLine: Bool = from == 0 || source.fastCodeAt(from - 1) == '\n'.code;

		var to: Int = span.to;
		while (to < source.length && isHorizontalSpace(source.fastCodeAt(to))) to++;
		final endsLine: Bool = to >= source.length || source.fastCodeAt(to) == '\n'.code;
		if (endsLine && to < source.length) to++;

		return startsLine && endsLine ? new Span(from, to) : span;
	}

	/**
	 * Give back ONE blank line when a whole-line deletion is flanked by a blank line on
	 * BOTH sides — the separator the removed declaration owned. Every member of a
	 * writer-canonical type is flanked that way, because the writer blank-separates
	 * members, so without this a member deletion turns the single blank the author wrote
	 * into a doubled run. Nothing downstream reports that: the writer re-emits the run up
	 * to `emptyLines.maxAnywhereInFile`, so the result stays writer-canonical and
	 * `fmt --list` stays clean, and no check reads blank lines. Under a config that caps
	 * the run at one the writer collapses it and the same wrong span is merely hidden —
	 * which is why the span, not the writer, is where this belongs.
	 *
	 * Flanked on ONE side only, nothing is given back, and that asymmetry is the point: a
	 * lone blank on one side is a GROUP boundary, and consuming it would move the survivor
	 * below into the group above — an edit the deletion was never asked to make. A
	 * boundary that is not a blank line counts as no blank for the same test — but do
	 * NOT read that as "the first / last member of a body is left alone". Under a config
	 * whose `classEmptyLines.beginType` / `endType` are 0 it is; under one that sets them
	 * to 1, as this project does, the brace-side gap IS a blank line and IS consumed.
	 * Those two positions come out right because `classEmptyLines` decides that gap and
	 * the writer re-normalises it either way, not because the brace reads as a boundary.
	 *
	 * A run that was ALREADY doubled stays doubled — one line back out of a pair still
	 * leaves a pair once the other side is counted. Collapsing such a run is a different
	 * edit and not a deletion's to make.
	 *
	 * Applies to a PURE deletion only, which is why it is called by `deleteNodes` and
	 * `CheckScan.deletionEdit` rather than folded into `lineExtendedSpan`: most of that
	 * helper's two dozen consumers splice replacement text into the line they widened, and
	 * giving back a separator there would swallow a line the replacement still needs. The
	 * callers are `deleteNodes`, `CheckScan.deletionEdit`, the collapsed-`if` arm of
	 * `CheckScan.ifShapeEdit`, and the three `cutSpanOf` move helpers. That is NOT every
	 * pure deletion in the tree: the statement-level check fixers (`unused-local`,
	 * `dead-code`, `self-assignment` and a dozen more) each build their own
	 * `{ span: lineExtendedSpan(…), text: '' }` inline, with no shared helper to route
	 * through, and still leave the doubled run. Auditing those is a slice of its own —
	 * they differ in what a "separator" means for a statement.
	 */
	public static function blankExtendedSpan(source: String, span: Span): Span {
		// Only a cut that owns whole lines can be flanked by lines at all: `from` must sit at a
		// line start and `to` just past a line end. That is exactly what `lineExtendedSpan`
		// produces when it extended, and never when it declined to, so this is also the test
		// that keeps a mid-line span (a comma-list element, a node sharing its line) out.
		if (span.from <= 0 || source.fastCodeAt(span.from - 1) != '\n'.code) return span;
		if (span.to <= span.from || span.to > source.length || source.fastCodeAt(span.to - 1) != '\n'.code) return span;

		// `span.from - 1` is the newline that ended the line above, so the line itself starts
		// before it; it is blank when only horizontal space separates that newline from the
		// previous one (or from the start of the file).
		var above: Int = span.from - 2;
		while (above >= 0 && isHorizontalSpace(source.fastCodeAt(above))) above--;
		if (above >= 0 && source.fastCodeAt(above) != '\n'.code) return span;

		var below: Int = span.to;
		while (below < source.length && isHorizontalSpace(source.fastCodeAt(below))) below++;
		// End of file is not a blank line — there is no separator left to give back.
		return below < source.length && source.fastCodeAt(below) == '\n'.code ? new Span(span.from, below + 1) : span;
	}

	/** Whether `code` is whitespace that does NOT end a line — space, tab, carriage return. */
	private static inline function isHorizontalSpace(code: Int): Bool {
		return code == ' '.code || code == '\t'.code || code == '\r'.code;
	}

	/**
	 * The whitespace prefix of the line `from` sits on, or `''` when anything else precedes that
	 * offset on the line. A multi-statement splice re-indents its continuation lines with this, so
	 * the rewritten region still reads as source for the round trip that parses it back; the writer
	 * re-indents the whole file afterwards regardless.
	 */
	public static function lineIndentAt(source: String, from: Int): String {
		final prefix: String = source.substring(source.lastIndexOf('\n', from) + 1, from);
		return prefix.trim() == '' ? prefix : '';
	}

	/**
	 * Extend `span` BACKWARD over its own line's leading indentation and the newline before it, so
	 * deleting the result removes the whole line rather than leaving a blank one. The backward-only
	 * twin of `lineExtendedSpan`, which sweeps in BOTH directions and refuses when the element shares
	 * its line: this one takes the leading blanks unconditionally and never touches what follows, so a
	 * deletion whose caller has already proved the region behind the element is its own can hand the
	 * trailing text to the writer to re-canonicalise.
	 *
	 * It stops at the first non-whitespace, which is why each caller refuses outright when a comment
	 * stands anywhere in the region its deletion disturbs: a comment BEFORE the deleted node would
	 * survive to document whatever follows it, and one TRAILING it is trivia outside the span that the
	 * writer would re-attach elsewhere.
	 */
	public static function lineDeletionSpan(source: String, span: Span): Span {
		var from: Int = span.from;
		while (from > 0) {
			final c: Int = source.fastCodeAt(from - 1);
			if (c != ' '.code && c != '\t'.code) break;
			from--;
		}
		if (from > 0 && source.fastCodeAt(from - 1) == '\n'.code) {
			from--;
			if (from > 0 && source.fastCodeAt(from - 1) == '\r'.code) from--;
		}
		return new Span(from, span.to);
	}

	/**
	 * Is the element at `span` immediately adjacent to a `,` — the next
	 * non-whitespace byte after `span.to`, or the previous before `span.from`,
	 * is a comma? True ⇒ the element sits in a comma-separated list (catches a
	 * comma container not in `COMMA_CONTAINER_KINDS`, for any list with at
	 * least two elements). Shared by `add-element` and `deleteNode`.
	 */
	public static function adjacentToComma(source: String, span: Span): Bool {
		var i: Int = span.to;
		while (i < source.length && isSpace(source.fastCodeAt(i))) i++;
		if (i < source.length && source.fastCodeAt(i) == ','.code) return true;

		var j: Int = span.from - 1;
		while (j >= 0 && isSpace(source.fastCodeAt(j))) j--;
		return j >= 0 && source.fastCodeAt(j) == ','.code;
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
	 * Is the source spanned by `span` — with its first and last byte stripped
	 * (a brace-delimited block's `{` / `}`) — whitespace-only? A block holding
	 * only a comment is non-blank: a comment carries no statement, but it is
	 * source a fix must not silently discard (it may be the only trace of
	 * intent behind an otherwise-empty block). Shared by `empty-block` (an
	 * empty `{}` control-flow body) and `constant-condition` (a dead branch a
	 * fix would eliminate).
	 */
	public static function isBlankSpan(span: Span, source: String): Bool {
		final inner: String = source.substring(span.from + 1, span.to - 1);
		return inner.trim() == '';
	}

	/**
	 * Format `text` into a doc-comment block, one ` * ` line per line. Leading /
	 * trailing blank lines of the payload are trimmed (a stdin / heredoc payload
	 * always carries a trailing newline — an edge blank is a delivery artifact,
	 * never an intended empty doc line); INTERNAL blank lines are kept as
	 * paragraph breaks.
	 */
	public static function docComment(text: String): String {
		final lines: Array<String> = trimBlankEdges(text.split('\n'));
		final buf: StringBuf = new StringBuf();
		buf.add('/**\n');
		for (line in lines) buf.add(line == '' ? ' *\n' : ' * $line\n');
		buf.add(' */');
		return buf.toString();
	}

	/**
	 * The span of the comment at `cursor`, or null if the cursor is not on a
	 * comment. A block comment is returned whole; a full-line line comment is
	 * merged with the contiguous run of full-line line comments directly above
	 * and below it (no blank line, no code between), so a line-comment block is
	 * addressed as one unit; a trailing line comment after code is returned
	 * alone. String literals are skipped, so an opener inside a string is not
	 * mistaken for a comment.
	 */
	public static function commentBlockAt(source: String, cursor: Int): Null<Span> {
		final toks: Array<{ from: Int, to: Int, isLine: Bool }> = collectCommentTokens(source);
		var hitIdx: Int = -1;
		for (k in 0...toks.length) if (cursor >= toks[k].from && cursor < toks[k].to) {
			hitIdx = k;
			break;
		}
		if (hitIdx < 0) return null;
		final hit: { from: Int, to: Int, isLine: Bool } = toks[hitIdx];
		if (!hit.isLine || !isFullLineComment(source, hit.from)) return new Span(hit.from, hit.to);
		var lo: Int = hitIdx;
		while (lo > 0 && contiguousLineComments(source, toks[lo - 1], toks[lo])) lo--;
		var hi: Int = hitIdx;
		while (hi < toks.length - 1 && contiguousLineComments(source, toks[hi], toks[hi + 1])) hi++;
		return new Span(toks[lo].from, toks[hi].to);
	}

	/**
	 * Scan `source` for every comment token (line and block), skipping string
	 * literals so an opener inside a string is not a comment. Mirrors the `apq
	 * lit` comment walker. Each token is `{ from, to, isLine }`.
	 */
	public static function collectCommentTokens(source: String): Array<{ from: Int, to: Int, isLine: Bool }> {
		final out: Array<{ from: Int, to: Int, isLine: Bool }> = [];
		for (region in scanLexicalRegions(source)) switch region.kind {
			case LineComment:
				out.push({ from: region.from, to: region.to, isLine: true });
			case BlockComment:
				out.push({ from: region.from, to: region.to, isLine: false });
			case StringLit | RegexLit:
		}
		return out;
	}

	/**
	 * Every NON-CODE region of `source` — comment, string literal or regex literal — as `[from, to)`
	 * spans in source order. The sibling of `collectCommentTokens` over the same single lexer, for a
	 * caller that only needs to answer "is this offset real code?" (the conditional-compilation
	 * directive reader) and must not grow a lexer of its own. Not memoised: each call re-lexes.
	 */
	public static function collectNonCodeRegions(source: String): Array<Span> {
		return [for (region in scanLexicalRegions(source)) new Span(region.from, region.to)];
	}

	/**
	 * Every COMMENT region of `source` as `[from, to)` spans in source order — the strictly
	 * narrower sibling of `collectNonCodeRegions`, for a caller masking text that cannot possibly
	 * bind or reference a name.
	 *
	 * STRING literals are deliberately NOT included, and the distinction is load-bearing rather
	 * than cosmetic: a single-quoted Haxe string INTERPOLATES, so `'${Foo.x}'` is a genuine
	 * reference to `Foo`, and masking the literal WHOLE would let a name-freeness scan conclude
	 * the name is unbound when it is read right there. A comment carries no such risk. A caller
	 * that wants the inert TEXT of a literal masked too cannot get it from a lexer at all — which
	 * bytes of a literal are text is a question only the parse answers, and `InertRegions` answers
	 * it off the tree. Not memoised: each call re-lexes, so a per-file caller should hoist it.
	 */
	public static function collectCommentRegions(source: String): Array<Span> {
		return [for (token in collectCommentTokens(source)) new Span(token.from, token.to)];
	}

	/**
	 * The spans of every MODULE-PATH declaration in `tree` (`RefShape.modulePathKinds` — Haxe's
	 * `package` / `import`). Their text is a dotted path, so a word-boundary identifier match
	 * inside one is a package segment or a type name, never a use of a local or a member: a
	 * completeness scan excludes these the way it excludes an occurrence already attributed
	 * elsewhere. Empty for a grammar that declares no such kinds.
	 */
	public static function modulePathSpans(tree: QueryNode, shape: RefShape): Array<Span> {
		final kinds: Null<Array<String>> = shape.modulePathKinds;
		if (kinds == null || kinds.length == 0) return [];
		final out: Array<Span> = [];
		collectModulePathSpans(tree, kinds, out);
		return out;
	}

	/**
	 * Whether `tok` is a DOC block — opened with the doc marker and carrying a
	 * non-blank body. A line comment, a plain `/* … *\/` banner (a license header, a
	 * section label) and the empty `/**` `*\/` form are all NOT docs, which is the
	 * discrimination `docExtendedSpan` makes and every doc-aware check needs.
	 */
	public static function isDocBlock(source: String, tok: { from: Int, to: Int, isLine: Bool }): Bool {
		return !tok.isLine && source.substring(tok.from, tok.from + DOC_OPEN.length) == DOC_OPEN && !blockCommentIsBlank(source, tok);
	}

	/**
	 * Whether a CLOSED block comment's interior holds no content — only whitespace and the
	 * `*` gutter characters a doc lays its lines out with, so `/**` `*\/`, `/***\/` and a
	 * marker-only multi-line block all qualify. An unclosed block is never blank: its
	 * interior is whatever runs to end of file.
	 */
	public static function blockCommentIsBlank(source: String, tok: { from: Int, to: Int, isLine: Bool }): Bool {
		if (tok.isLine) return false;
		final closed: Bool = tok.from + 2 <= tok.to - 2 && source.fastCodeAt(tok.to - 2) == '*'.code // noqa: magic-number
			&& source.fastCodeAt(tok.to - 1) == '/'.code;
		if (!closed) return false;
		for (i in tok.from + 2...tok.to - 2) { // noqa: magic-number
			final c: Int = source.fastCodeAt(i);
			if (!isSpace(c) && c != '*'.code) return false;
		}
		return true;
	}

	/** The offset of the start of the line `at` sits on. */
	public static function startOfLine(source: String, at: Int): Int {
		var from: Int = at;
		while (from > 0 && source.fastCodeAt(from - 1) != '\n'.code) from--;
		return from;
	}

	/**
	 * Body span of a comment token — the text between the opener (`//` or the
	 * block opener) and the closer, with a closed block's trailing delimiter
	 * excluded and a line comment running to the newline. Shared by the comment
	 * finder (`Cli.appendCommentHits`) and the comment rewriter (`CommentRewrite`).
	 */
	public static function commentBody(source: String, tok: { from: Int, to: Int, isLine: Bool }): Span {
		final closed: Bool = !tok.isLine && tok.to >= tok.from + 4 && StringTools.fastCodeAt(source, tok.to - 2) == '*'.code // noqa
			&& source.fastCodeAt(tok.to - 1) == '/'.code;
		final bodyEnd: Int = closed ? tok.to - 2 : tok.to;
		return new Span(tok.from + 2, bodyEnd);
	}

	/**
	 * Whether a private member of the type named `owner` is confined to its file —
	 * i.e. unreachable from outside it, so an in-file analysis (rename, unused
	 * detection) sees every possible reference. False when any file skip-parsed (it
	 * could hide a subtype or `@:access` the index never saw), when a subtype or
	 * `@:access` grant names the type, or when the file carries an `@:allow` (which
	 * can expose its privates to another type). Conservative: any doubt is false.
	 */
	public static function isPrivateMemberConfined(owner: String, source: String, index: SymbolIndex): Bool {
		return privateMemberScanIsSound(source, index) && !index.hasSubtype(owner) && !index.hasAccessGrant(owner);
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
		if (node.kind == kind) return true;
		for (c in node.children) if (subtreeContainsKind(c, kind)) return true;
		return false;
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
	 * Drop every edit whose span is fully contained in another edit's span,
	 * keeping the outer (larger) one. Span-deletion edits from independent sources
	 * — several checks batched by `apq lint --fix`, or one check's nested findings
	 * (a dead run inside a dead run) — can nest; applying nested deletions blindly
	 * corrupts the source. Removing the contained edit is correct for deletions:
	 * the outer deletion already subsumes it. Equal spans keep the earliest index.
	 */
	public static function dropContainedEdits(edits: Array<{ span: Span, text: String }>): Array<{ span: Span, text: String }> {
		return [for (i in 0...edits.length) if (!isContainedEdit(edits, i)) edits[i]];
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
		if (a.children.length != b.children.length) return false;
		for (k in 0...a.children.length) if (!structurallyEqual(a.children[k], b.children[k])) return false;
		return true;
	}

	/**
	 * Does `source` reference `name` as a member access — a `.name` with a `.`
	 * immediately before and a word boundary after? This is the form a `using`'s
	 * extension method takes whether it is called (`s.trim()`) or captured as a
	 * value (`var f = s.trim`), so the `unused-import` check uses it to decide a
	 * `using` is live. Deliberately does NOT require a trailing `(`: a captured
	 * function reference is just as much a use, and skipping the check also avoids
	 * missing a call separated from its name by a comment. Like `referencedInRange`
	 * it is a textual scan that also counts the form inside a comment / string —
	 * which only ever keeps a `using`, never wrongly deletes one (the safe
	 * direction for an autofix).
	 *
	 * `skipReceiver`, when given, excludes an occurrence whose receiver is exactly
	 * that simple name. Its caller has already established that the name is not
	 * referenced bare, so every occurrence of it is dot-qualified — which makes
	 * `Limit.MAX` on a `using a.b.Limit` a fully-qualified STATIC access reaching
	 * the type through no import at all, not the extension call the `using` enables.
	 */
	public static function methodCalledInSource(source: String, name: String, ?skipReceiver: String): Bool {
		final len: Int = name.length;
		if (len == 0) return false;
		final skip: String = skipReceiver ?? '';
		inline function qualifiedBySkip(dotAt: Int): Bool {
			final start: Int = dotAt - skip.length;
			return skip.length > 0 && start >= 0 && source.substr(start, skip.length) == skip
				&& (start == 0 || !isIdentChar(source.fastCodeAt(start - 1)));
		}
		var i: Int = 0;
		while (true) {
			final at: Int = source.indexOf(name, i);
			if (at < 0) return false;
			i = at + 1;
			if (at == 0 || source.fastCodeAt(at - 1) != '.'.code) continue;
			final afterIdx: Int = at + len;
			if (afterIdx < source.length && isIdentChar(source.fastCodeAt(afterIdx))) continue;
			if (!qualifiedBySkip(at - 1)) return true;
		}
	}

	/**
	 * Normalize a comment BODY for cross-line literal matching: fold each line
	 * continuation — a `\n` or `\r\n`, the following whitespace, blank lines, and
	 * one ` * ` doc-marker per line — into a single space, so a phrase wrapped
	 * across two ` * ` lines reads as one run. Returns the normalized text plus a
	 * `map` from each normalized index to the original body offset it came from,
	 * with `map[text.length] == body.length`, so a match found in the normalized
	 * text projects back to a span in the original body.
	 */
	public static function normalizeCommentBody(body: String): { text: String, map: Array<Int> } {
		final buf: StringBuf = new StringBuf();
		final map: Array<Int> = [];
		final n: Int = body.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = body.fastCodeAt(i);
			final crlf: Bool = c == '\r'.code && i + 1 < n && body.fastCodeAt(i + 1) == '\n'.code;
			if (c == '\n'.code || crlf) {
				final runStart: Int = i;
				i = skipContinuation(body, (crlf ? i + 1 : i) + 1, n);
				buf.addChar(' '.code);
				map.push(runStart);
			} else {
				buf.addChar(c);
				map.push(i);
				i++;
			}
		}
		map.push(n);
		return { text: buf.toString(), map: map };
	}

	/**
	 * Whether the condition subtree `cond` contains a null-narrowing guard: an
	 * identifier compared against null (`x == null` / `x != null`) that is then
	 * REUSED elsewhere in the same condition (`x.f`, `x[i]`, `x()`, `g(x)`, a bare
	 * `x`, …). Haxe narrows such an `x` only inside a condition, so a check that
	 * flattens the condition into a bare boolean `||` chain loses the narrowing and
	 * the result fails to compile under `@:nullSafety(Strict)` —
	 * `simplify-boolean-ternary` must always skip a guarded finding. A ternary
	 * `cond ? a : b` KEEPS the narrowing (it types like if/else), so the ternary
	 * checks consult this only through `refusesNullNarrowingBoolCollapse` (refusing
	 * just the bool-literal collapse that would hand off to the flattening
	 * `simplify-boolean-ternary`). Conservative: a reuse in ANY position counts (it
	 * over-skips a comparison-only reuse like `x != null && x == y`, which is
	 * actually safe to flatten — never a compile break), and a grammar without the
	 * null/equality kinds yields false.
	 */
	public static function hasNullNarrowingGuard(cond: QueryNode, shape: RefShape): Bool {
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind == null) return false;
		final identCount: Map<String, Int> = [];
		final checkCount: Map<String, Int> = [];
		tallyGuardIdents(cond, shape.identKind, nullKind, shape.eqKind, shape.notEqKind, identCount, checkCount);
		for (name => total in identCount) {
			// Null-checked (`checks != null`) AND reused beyond its own null-comparison
			// operand(s) (`total > checks`): the reuse relies on the in-condition narrowing.
			final checks: Null<Int> = checkCount[name];
			if (checks != null && total > checks) return true;
		}
		return false;
	}

	/**
	 * Whether collapsing an `if`/branch pair with condition `cond` and branch
	 * values `a` / `b` into a ternary must be REFUSED: `cond` carries a
	 * null-narrowing guard (`hasNullNarrowingGuard`) AND a branch value is a bool
	 * literal (`boolLitKind`; an unset kind never refuses). A VALUE ternary keeps
	 * the in-condition narrowing (`cond ? a : b` types exactly like if/else), so a
	 * guarded condition alone is fine — but a bool-literal pair hands off to
	 * `simplify-boolean-ternary`, whose boolean flattening loses the narrowing
	 * (and whose own guard then strands a stuck ternary uglier than the original).
	 * The shared gate of `prefer-ternary-return` / `prefer-ternary-assignment`.
	 */
	public static function refusesNullNarrowingBoolCollapse(a: QueryNode, b: QueryNode, cond: QueryNode, shape: RefShape): Bool {
		final boolLitKind: Null<String> = shape.boolLitKind;
		return boolLitKind != null && (a.kind == boolLitKind || b.kind == boolLitKind) && hasNullNarrowingGuard(cond, shape);
	}

	/**
	 * The local name a top-level statement DECLARES, or null — the `name` of
	 * `topLevelDeclaredNode`'s result. ONE `declKinds` list rather than the node walk's
	 * statement/expression pair: its only caller, `sameBlockRedeclaration`, asks with a
	 * vocabulary that is already a union.
	 */
	public static function topLevelDeclaredName(stmt: QueryNode, declKinds: Array<String>, metaKinds: Array<String>): Null<String> {
		final decl: Null<QueryNode> = topLevelDeclaredNode(stmt, declKinds, [], metaKinds);
		return decl?.name;
	}

	/**
	 * The declaration NODE a top-level statement DECLARES a local in, or null — the
	 * node `topLevelDeclaredName` reads the name off, exposed for callers that also
	 * need its span (`guard-continue`'s collision rename locates the binder token
	 * inside it). Same walk: a `localDeclKinds` statement answers directly, otherwise
	 * the walk descends through single-payload wrappers (`metaKinds` children skipped)
	 * to an expression-position declaration.
	 */
	public static function topLevelDeclaredNode(
		stmt: QueryNode, localDeclKinds: Array<String>, localDeclExprKinds: Array<String>, metaKinds: Array<String>
	): Null<QueryNode> {
		var cur: QueryNode = stmt;
		while (true) {
			if (localDeclKinds.contains(cur.kind) || localDeclExprKinds.contains(cur.kind)) return cur;
			final payload: Array<QueryNode> = [for (c in cur.children) if (!metaKinds.contains(c.kind)) c];
			if (payload.length != 1) return null;
			cur = payload[0];
		}
	}

	/**
	 * Whether any edit in `candidate` overlaps (intersects) any edit in `accepted` —
	 * the cross-check guard the `--fix` loop uses to keep a check's edits atomic. A
	 * check whose edits intersect an already-accepted check's edits is deferred whole
	 * to the next fixed-point pass, so a partial application (e.g. a signature edit
	 * without its matching call-site edit) can never land.
	 */
	public static function editsOverlapAny(
		candidate: Array<{ span: Span, text: String }>, accepted: Array<{ span: Span, text: String }>
	): Bool {
		return candidate.exists(c -> accepted.exists(a -> c.span.from < a.span.to && a.span.from < c.span.to));
	}

	/**
	 * Whether `operand` (parentheses unwrapped) is a provably non-null `Bool` — a node
	 * whose kind is in `boolOpKinds` (a comparison / `&&` / `||` / `!` result). Such a
	 * node can never be `Null<Bool>`, so combining it with boolean logic is sound under
	 * strict null-safety; an identifier, call, field access or literal is not provable
	 * without types. Shared by `comparison-to-boolean` and `prefer-ternary-return`.
	 */
	public static function provablyBoolOperand(operand: QueryNode, boolOpKinds: Array<String>, parenKind: Null<String>): Bool {
		return boolOpKinds.contains(unwrapParens(operand, parenKind).kind);
	}

	/**
	 * `node` with every enclosing parenthesis layer peeled off — `((e))` yields `e`.
	 * The grammar-agnostic paren seam: an UNSET `parenKind` (the grammar declares no
	 * parenthesized-expression kind) returns `node` unchanged, so a caller degrades to
	 * its un-unwrapped behaviour rather than guessing a kind. A paren node that does not
	 * hold exactly one child stops the walk — only a plain single-child wrap is
	 * semantically transparent.
	 */
	public static function unwrapParens(node: QueryNode, parenKind: Null<String>): QueryNode {
		var n: QueryNode = node;
		while (parenKind != null && n.kind == parenKind && n.children.length == 1) n = n.children[0];
		return n;
	}

	/**
	 * Visit every mutable `var` field member of every visibility-bearing type in
	 * `files`, with the enclosing type's simple name, the field node, its source, file,
	 * and whether its preceding modifier run marks it exported (non-default visibility).
	 * The shared container walk behind the field-immutability checks
	 * (`prefer-final-field` private path, `prefer-final-public-field`,
	 * `prefer-read-only-field`) — each filters by `exported` and applies its own proof.
	 * Skip-parse tolerant; a grammar lacking the visibility kind-sets yields nothing.
	 *
	 * A field written inside a member-position `#if` region is visited too: the region is ONE
	 * child of the container holding every branch's fields flattened, so scanning the container's
	 * direct children alone silently exempted every guarded field. `MemberBranchScan.fold` descends
	 * into it branch by branch, and merges the exported flag a branch carries out with OR — the
	 * fail-closed direction here. A field the merge calls exported when some build makes it private
	 * is at worst reported by the public-field rules instead of the private one; the AND reading
	 * would hand `prefer-final-field`'s file-confined write proof a field that is PUBLIC in another
	 * build, where an out-of-file writer it never scans can exist.
	 */
	public static function eachFieldMember(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin,
		visit: (owner:String, field:QueryNode, source:String, file:String, exported:Bool) -> Void
	): Void {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final mutableFields: Array<String> = shape.mutableFieldDeclKinds ?? [];
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final defaultVis: Null<String> = shape.defaultVisibilityModifierText;
		if (containers.length == 0 || members.length == 0 || mutableFields.length == 0 || visibility.length == 0 || defaultVis == null)
			return;
		// Re-bound to a non-null local: a narrowing does not reach into an anonymous struct literal.
		final vis: String = defaultVis;
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree != null) walkFieldContainers(tree, {
				source: entry.source,
				file: entry.file,
				containers: containers,
				members: members,
				mutableFields: mutableFields,
				visibility: visibility,
				defaultVis: vis,
				branch: MemberBranchScan.seamsOf(shape, entry.source),
				visit: visit
			});
		}
	}

	/**
	 * The `var` → `final` keyword-swap edits for each non-null span in `spans` (a field
	 * decl whose span starts at the `var` keyword). Shared by the `prefer-final-field`
	 * and `prefer-final-public-field` autofixes. Each edit fires only when the bytes at
	 * the span start are literally `var`, so an unexpected span is silently skipped.
	 */
	public static function varKeywordToFinalEdits(source: String, spans: Array<Null<Span>>): Array<{ span: Span, text: String }> {
		final keyword: String = 'var';
		final edits: Array<{ span: Span, text: String }> = [];
		for (span in spans) if (span != null) {
			final end: Int = span.from + keyword.length;
			if (source.substring(span.from, end) != keyword) continue;
			edits.push({ span: new Span(span.from, end), text: 'final' });
		}
		return edits;
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
	 * The single constructor (`FnMember` named `new`) directly declared in `container`,
	 * or null when there is not exactly one — a multiple-constructor (macro-generated)
	 * class is skipped so a field's init timing stays a plain single `new`.
	 */
	public static function soleConstructor(container: QueryNode, shape: RefShape): Null<QueryNode> {
		final ctorName: Null<String> = shape.constructorName;
		final members: Array<String> = shape.memberDeclKinds ?? [];
		if (ctorName == null) return null;
		var found: Null<QueryNode> = null;
		var several: Bool = false;
		// Every member host, not just the container's direct children: a constructor written inside a
		// member-position `#if` is one level down, and reading it as absent let a caller treat a
		// SECOND, guarded constructor's assignments as if they did not exist.
		eachMemberHost(container, host -> {
			for (child in host.children) if (members.contains(child.kind) && child.name == ctorName) {
				if (found != null) several = true;
				found = child;
			}
		});
		return several ? null : found;
	}

	/**
	 * The single unconditional top-level constructor statement that assigns `field`
	 * (`field = expr` or `this.field = expr`, a DIRECT child of the constructor's block
	 * body — not nested in a branch / loop / closure), paired with the assignment's
	 * right-hand side and the assignment target's span, or null when there is not
	 * exactly one. `container` scopes binding resolution, so a bare `field =` that
	 * resolves to a shadowing constructor local / parameter does NOT match this field.
	 */
	public static function soleConstructorFieldInit(
		container: QueryNode, ctor: QueryNode, field: QueryNode, shape: RefShape
	): Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> {
		final bodyKind: Null<String> = shape.blockBodyKind;
		final stmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		final fieldSpan: Null<Span> = field.span;
		final fieldName: Null<String> = field.name;
		if (bodyKind == null || stmtKind == null || assignKind == null || fieldSpan == null || fieldName == null) return null;
		final fieldFrom: Int = fieldSpan.from;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == bodyKind);
		if (body == null) return null;
		var match: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = null;
		for (stmt in body.children) if (stmt.kind == stmtKind && stmt.children.length >= 1) {
			final assign: QueryNode = stmt.children[0];
			if (assign.kind != assignKind || assign.children.length < 2) continue;
			final target: QueryNode = assign.children[0];
			final tSpan: Null<Span> = target.span;
			if (tSpan == null) continue;
			if (!ctorTargetIsField(target, fieldFrom, fieldName, container, shape)) continue;
			if (match != null) return null;
			match = { stmt: stmt, rhs: assign.children[1], target: tSpan };
		}
		return match;
	}

	/**
	 * The single assignment to `field` ANYWHERE in `ctor`'s body — `field = expr` /
	 * `this.field = expr` at any expression depth, including one EMBEDDED in a call argument
	 * (`super([_a = new Row(…)])`, the layout-tree idiom) — paired with its right-hand side and
	 * the target's span, or null when there is not exactly one.
	 *
	 * A strict SUPERSET of `soleConstructorFieldInit`, which admits only a direct child of the
	 * body's statement list. A caller whose edit DELETES the statement must keep using that one:
	 * an embedded write's value is consumed in place, so deleting its line deletes live code.
	 * `container` scopes binding resolution, so a bare `field =` resolving to a shadowing
	 * constructor local / parameter does NOT match.
	 *
	 * A write inside a CLOSURE refuses, and that is the one nesting Haxe itself rejects:
	 * `new() { run(() -> _a = 1); }` over a `final _a` fails with `This expression cannot be
	 * accessed for writing` plus `Some final fields are uninitialized in this class` (4.3.7,
	 * `--interp`). Every OTHER nesting — an `if` / `switch` branch, a loop body, a ternary arm, an
	 * `&&` right operand — the compiler ACCEPTS for a `final` field, measured on the same build, so
	 * this predicate admits them: it answers "is this the field's sole assignment", never "does it
	 * run exactly once". A consumer that MOVES the right-hand side therefore owes the separate
	 * `ctorWriteUnconditional` proof; a consumer that only rewrites the declaration's `var` to
	 * `final` does not, since the keyword changes no evaluation.
	 */
	public static function soleConstructorFieldWrite(
		container: QueryNode, ctor: QueryNode, field: QueryNode, shape: RefShape
	): Null<{ assign: QueryNode, rhs: QueryNode, target: Span }> {
		final bodyKind: Null<String> = shape.blockBodyKind;
		final assignKind: Null<String> = shape.assignKind;
		final fieldSpan: Null<Span> = field.span;
		final fieldName: Null<String> = field.name;
		if (bodyKind == null || assignKind == null || fieldSpan == null || fieldName == null) return null;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == bodyKind);
		if (body == null) return null;
		final found: Array<{ assign: QueryNode, inClosure: Bool }> = [];
		collectCtorFieldWrites(body, fieldSpan.from, fieldName, container, shape, assignKind, closureHostKinds(shape), false, found);
		if (found.length != 1 || found[0].inClosure) return null;
		final assign: QueryNode = found[0].assign;
		final targetSpan: Null<Span> = assign.children[0].span;
		return targetSpan == null ? null : {
			assign: assign,
			rhs: assign.children[1],
			target: targetSpan
		};
	}

	/**
	 * Whether the assignment node starting at `writeFrom` sits in an UNCONDITIONALLY EVALUATED
	 * position of `ctor`'s body — every step from one of the body's top-level statements down to it
	 * evaluates its operand exactly once, whatever the data. The question to ask before hoisting
	 * that write's right-hand side into the declaration prologue, which runs always: a write nested
	 * in an `if`, a ternary arm, an `&&` operand or a loop body runs conditionally, and
	 * `soleConstructorFieldWrite` deliberately admits all of those because Haxe accepts them for a
	 * `final` field. The two predicates split on exactly that line.
	 *
	 * Decided as a POSITIVE WHITELIST of transparent node kinds, never as a negative "and not an
	 * `if`, and not a ternary, and not …" list — a negative list leaks by CATEGORY, admitting
	 * whatever lazily-evaluated shape nobody enumerated. Admitted, each read off its own `RefShape`
	 * seam: an expression statement, a local declaration, a parenthesis, a call (callee and every
	 * argument), a `new`, an array literal, an object literal and its fields, and an outer
	 * assignment's right-hand side. Anything else refuses — including any kind whose seam the
	 * grammar leaves unset, so a plugin declaring none of them admits nothing rather than
	 * everything.
	 */
	public static function ctorWriteUnconditional(ctor: QueryNode, writeFrom: Int, shape: RefShape): Bool {
		final bodyKind: Null<String> = shape.blockBodyKind;
		if (bodyKind == null) return false;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == bodyKind);
		if (body == null) return false;
		final transparent: Array<String> = unconditionalOperandKinds(shape);
		for (stmt in body.children) if (transparent.contains(stmt.kind) && reachesThroughOperands(stmt, writeFrom, transparent))
			return true;
		return false;
	}

	/**
	 * Whether the constructor statement starting at `boundary` is UNCONDITIONALLY REACHED:
	 * every top-level statement lexically before it COMPLETES NORMALLY, so control arrives at
	 * `boundary` on every path. The question to ask before hoisting that statement's code into
	 * the declaration PROLOGUE, which runs ahead of the constructor body and therefore ahead of
	 * every guard the body holds — a guarded initialisation moved there becomes an unguarded
	 * one, and nothing downstream notices: the result still type-checks and still parses.
	 *
	 * Decided as a POSITIVE WHITELIST, never as a negative "and not an `if`, and not a
	 * `switch`, and not …" list — a negative list leaks by CATEGORY, letting through whatever
	 * statement shape nobody thought to enumerate. `completesNormally` holds the admitted
	 * kinds, each read off its own `RefShape` seam: an expression statement, a local
	 * declaration (plain or `static`), an `if`, a `switch`, a `try` / `catch`, a local
	 * `function` / `inline function` DECLARATION (it binds a name; its body does not run here),
	 * and a `#if` region. A top-level statement of ANY other kind before `boundary` refuses.
	 * `super(…)` projects as a plain expression statement on the Haxe grammar and stays allowed
	 * — this predicate answers only "is `boundary` reached", so a consumer that moves code
	 * ACROSS a `super(…)` owes its own judgement of that crossing (see
	 * `FieldInitAtDeclaration`'s "Known gaps").
	 *
	 * LOOPS ARE THE ONE DELIBERATE OMISSION, and they are the whitelist's only unique
	 * contribution: a loop cannot be proven to terminate, so it cannot be proven to complete.
	 * `while (true) { }` before `boundary` holds no control-exit node ANYWHERE, so the subtree
	 * scan below finds nothing to object to and only the kind check refuses it. Every other
	 * shape the whitelist used to refuse, the scan refuses too — which is what made widening it
	 * free.
	 *
	 * A kind whitelist alone is not enough, because a statement's KIND does not bound what its
	 * SUBTREE holds, and the subtree scan closes two separate holes:
	 *
	 * - A CONTROL EXIT HIDING INSIDE AN ACCEPTED KIND. A non-block `try` body projects as a
	 *   plain expression statement (`try return catch (e:Dynamic) {}` is
	 *   `ExprStmt(TryExpr(VoidReturnExpr …))`), and an admitted `if` / `switch` is exactly the
	 *   `if (!flag) return;` guard this predicate exists to refuse.
	 * - A LOOP HIDING INSIDE AN ACCEPTED KIND. Admitting `if` / `switch` / `try` / `#if` at top
	 *   level means `if (c) { while (true) {} }` would pass both the whitelist (its kind is an
	 *   `if`) and an exit-only scan (it holds no return or throw) — the loop omission would
	 *   stop holding one level down, and a top-level `for` would be refused while a nested one
	 *   was accepted, which is incoherent.
	 *
	 * The scan therefore runs over `controlExitKinds` UNION `loopStatementKinds`: any node of
	 * either set starting before `boundary` anywhere in the body subtree refuses.
	 *
	 * Three residual gaps, all measured and all accepted:
	 *
	 * - AN EXPRESSION STATEMENT THAT CANNOT RETURN IS ACCEPTED ANYWAY. `Sys.exit(0);`, or a call
	 *   to an always-throwing helper, reads as an ordinary expression statement, so the prefix is
	 *   judged straight-line and the hoist proceeds even though the constructor never reaches
	 *   `boundary`. Nothing short of interprocedural analysis sees through the call, so this one
	 *   is open by construction rather than by choice.
	 * - THE OVER-REFUSAL IS WIDER THAN A RARE SHAPE. The subtree scan is positional, not
	 *   scope-aware, so a `return` that exits NOTHING in the constructor still refuses: inside a
	 *   lambda passed as an argument, inside a local `function` / `inline function` declaration,
	 *   and inside a `macro { … }` block (all probed). A local `inline function` helper is an
	 *   idiom this project's own style prefers, so the cost is real rather than theoretical —
	 *   and doubly so now that such a declaration is an ADMITTED top-level kind, reaching the
	 *   scan only to be refused by its own body. The loop half of the scan inherits the same
	 *   imprecision: a loop inside a lambda before `boundary` refuses too.
	 * - `loopStatementKinds` DOES NOT COVER `do … while`. On the Haxe grammar it is
	 *   `['ForStmt', 'WhileStmt']`; `DoWhileStmt` lives in the separate `doWhileLoopKinds` seam,
	 *   whose consumers read the body off `children[0]`. A TOP-LEVEL `do … while (true)` is still
	 *   refused — no whitelist entry admits it — but one NESTED inside an admitted `if` is
	 *   invisible to the scan, and the prefix is judged to complete.
	 *
	 * Fails closed three ways: with no resolvable block body, with `controlExitKinds` unset (an
	 * empty set would make the subtree scan a silent no-op that accepts every early return,
	 * exactly the reasoning `guardReachedIntact` records for its own use of that seam), and with
	 * a prefix statement carrying no span. `loopStatementKinds` unset does NOT fail closed — it
	 * only makes the loop half of the scan inert, which is the behaviour that held before the
	 * scan learned about loops.
	 */
	public static function ctorPrefixUnconditional(ctor: QueryNode, boundary: Int, shape: RefShape): Bool {
		final bodyKind: Null<String> = shape.blockBodyKind;
		final exitKinds: Array<String> = shape.controlExitKinds ?? [];
		if (bodyKind == null || exitKinds.length == 0) return false;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == bodyKind);
		if (body == null) return false;
		for (stmt in body.children) {
			final span: Null<Span> = stmt.span;
			// A statement whose position is unknown cannot be placed relative to the boundary.
			if (span == null) return false;
			if (span.from < boundary && !completesNormally(stmt.kind, shape)) return false;
		}
		return !kindStartsBefore(body, exitKinds.concat(shape.loopStatementKinds ?? []), boundary);
	}

	/**
	 * Whether every identifier read in `node` is context-independent: a global / type /
	 * imported name (unresolved within the class) or a static member of the class — a
	 * value available at declaration-init time — and the subtree contains no `this`. A
	 * reference that resolves within the class but is not static (a constructor parameter
	 * or local, or a non-static instance member) makes the init order-dependent and thus
	 * unmovable, since a static member is the only in-class binding whose value exists
	 * before the constructor body runs.
	 *
	 * Shared by the two rules that move an expression out of the constructor BODY and into
	 * the declaration prologue — `field-init-at-declaration` hoists a whole right-hand side,
	 * `join-array-pushes` folds a pushed element into an array literal's initializer. Both
	 * need the SAME proof, and it settles two questions at once: the moved text must be
	 * LEGAL at declaration-initializer position (Haxe rejects `this` and a sibling-instance
	 * read there) and INDEPENDENT of the constructor's context (a parameter or local does
	 * not exist yet).
	 *
	 * `allowStatics` false additionally refuses an in-class STATIC read — the stricter form
	 * `field-init-at-declaration`'s prologue-order gate asks for. `mayBeInherited` answers
	 * "could this unresolved lowercase name be a member the container INHERITS?"; a caller
	 * holding no positive evidence passes `_ -> true`, which keeps the closed direction.
	 */
	public static function contextFreeRhs(
		node: QueryNode, container: QueryNode, statics: Array<Int>, shape: RefShape, allowStatics: Bool, mayBeInherited: (String) -> Bool
	): Bool {
		final identKind: String = shape.identKind;
		final selfText: Null<String> = shape.selfReferenceText;
		// `$p` inside a single-quoted string projects as the interp `Ident` kind, not
		// `IdentExpr` - it is a reference all the same, and the resolver binds it by the
		// same scope rules, so the two share one arm (`${p}` blocks carry a regular
		// IdentExpr child and were already reached by the child walk).
		if (node.kind == identKind || node.kind == shape.stringInterpIdentKind) {
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (name == null || span == null) return false;
			if (selfText != null && name == selfText) return false;
			final bf: Null<Int> = TypeResolver.resolveBindingFrom(name, span, container, shape);
			// An unresolved ident is the provably-global case (imports/statics) - UNLESS the
			// container has a supertype clause: an INHERITED member is invisible to the
			// single-file resolver and indistinguishable from a global, so under `extends` /
			// `implements` an unresolved lowercase ident fails closed too (type refs like
			// `Colors.WHITE` keep their uppercase root and stay movable).
			if (bf != null) return allowStatics && statics.contains(bf);
			if (!hasSupertypeClause(container, shape)) return true;
			final c0: Int = StringTools.fastCodeAt(name, 0);
			// An uppercase root is a TYPE reference (`Colors.WHITE`) — never an inherited member, and
			// decided without touching the index. A lowercase one asks the index whether any ancestor
			// could declare it.
			return c0 >= 'A'.code && c0 <= 'Z'.code || !mayBeInherited(name);
		}
		for (child in node.children) if (!contextFreeRhs(child, container, statics, shape, allowStatics, mayBeInherited)) return false;
		return true;
	}

	/**
	 * Whether `container` carries any supertype clause (`extends` / `implements`) — the
	 * condition under which an unresolved bare ident may actually be an inherited member
	 * rather than a global, and the coarse fallback a base-constructor gate degrades to when
	 * the call itself cannot be recognised.
	 *
	 * Answers false when `supertypeClauseKinds` is unset, which degrades OPEN: a grammar
	 * declaring none of the inheritance seams gets no gate rather than a coarse one.
	 * Deliberately not closed by making an undeclared seam refuse every container — that
	 * would disarm the callers for any language with no inheritance concept.
	 */
	public static function hasSupertypeClause(container: QueryNode, shape: RefShape): Bool {
		final clauses: Array<String> = shape.supertypeClauseKinds ?? [];
		if (clauses.length == 0) return false;
		for (c in container.children) if (clauses.contains(c.kind)) return true;
		return false;
	}

	/**
	 * Collect every call in `node`'s subtree whose callee is the bare identifier `superText` —
	 * the explicit base-constructor calls. A `super.foo()` is deliberately NOT one: it is a
	 * base-MEMBER access, whose callee is a field access on `super` rather than `super` itself.
	 */
	public static function collectSuperCalls(
		node: QueryNode, superText: String, callKind: String, identKind: String, out: Array<QueryNode>
	): Void {
		if (node.kind == callKind && node.children.length > 0) {
			final callee: QueryNode = node.children[0];
			if (callee.kind == identKind && callee.name == superText) out.push(node);
		}
		for (child in node.children) collectSuperCalls(child, superText, callKind, identKind, out);
	}

	/**
	 * The class-like container and the field member declared at `fieldFrom`, found by
	 * re-walking `tree` — the fix-side re-derivation from a violation's span (a
	 * violation carries only its file and span, so the container and field are
	 * recovered from the parsed source).
	 */
	public static function classLikeFieldAt(
		tree: QueryNode, fieldFrom: Int, shape: RefShape
	): Null<{ container: QueryNode, field: QueryNode }> {
		return findFieldContainer(tree, fieldFrom, classLikeContainerKinds(shape), shape.fieldDeclKinds ?? []);
	}

	/**
	 * Locate, from a parsed `tree`, the field at `fieldFrom` together with its
	 * class-like container and the single unconditional top-level constructor statement
	 * that initialises it — the shared entry point for `field-init-at-declaration`'s fix
	 * and `prefer-final-field`'s no-initializer case. Null when the field is not in a
	 * class-like container, the container has no single constructor, or the field is not
	 * assigned by exactly one top-level constructor statement.
	 */
	public static function constructorFieldInitAt(tree: QueryNode, fieldFrom: Int, shape: RefShape): Null<{
		container: QueryNode,
		field: QueryNode,
		stmt: QueryNode,
		rhs: QueryNode,
		target: Span
	}> {
		final loc: Null<{ container: QueryNode, field: QueryNode }> = classLikeFieldAt(tree, fieldFrom, shape);
		if (loc == null) return null;
		final ctor: Null<QueryNode> = soleConstructor(loc.container, shape);
		if (ctor == null) return null;
		final init: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = soleConstructorFieldInit(
			loc.container, ctor, loc.field, shape
		);
		return init == null ? null : {
			container: loc.container,
			field: loc.field,
			stmt: init.stmt,
			rhs: init.rhs,
			target: init.target
		};
	}

	/**
	 * The offset just before a field declaration's terminating `;`, where a moved
	 * `= <init>` is spliced. A `VarMember` / `FinalMember` span INCLUDES the trailing
	 * `;`, so the insert goes before it rather than at `span.to`; a span with no
	 * terminating `;` (skip-parse edge) falls back to `span.to`.
	 */
	public static function fieldDeclInitInsertPos(source: String, fieldSpan: Span): Int {
		var i: Int = fieldSpan.to - 1;
		while (i > fieldSpan.from) {
			final c: Int = source.fastCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\r'.code || c == '\n'.code) {
				i--;
				continue;
			}
			break;
		}
		return i > fieldSpan.from && source.fastCodeAt(i) == ';'.code ? i : fieldSpan.to;
	}

	/**
	 * What the head of a declaration whose initializer starts at `initSpan` says about its TYPE. The
	 * tree holds no type child for a local or a field, so it is read off the source: everything
	 * before the LAST `=`, then the first `:` at or after the last STANDALONE occurrence of the
	 * declared name — standalone so a leading `@:meta` cannot be mistaken for the annotation, and so
	 * a type whose own spelling ends in the name (`t:MyToolt`) cannot swallow it.
	 *
	 * The scan can FAIL, and `DeclaredType` keeps that case apart from a genuinely unannotated
	 * declaration, because a consumer may treat absence as a PROOF (see the enum's own doc). The two
	 * are told apart by asking the FIRST standalone occurrence as well: no `:` after either one means
	 * the head really writes no type, while a `:` after the first and none after the last means the
	 * annotation's own text repeats the declared name (`stack:pkg.stack`, `a:Stack<a>`) and the scan
	 * cannot say which occurrence is the binder. A missing `=`, a name that occurs nowhere standalone
	 * and an empty annotation text are `Unreadable` for the same reason.
	 *
	 * Shared by the checks that must know what a `[]` initializer was DECLARED as:
	 * `prefer-comprehension` transcribes the annotation onto the comprehension it emits (and reads
	 * `Unreadable` exactly as `Absent`, since neither gives it anything to copy — that is what
	 * `declaredTypeAnnotation` projects), while `join-array-pushes` asks whether it names an array
	 * type and must refuse an unreadable head.
	 */
	public static function declaredType(source: String, declSpan: Span, initSpan: Span, name: String): DeclaredType {
		final prefix: String = source.substring(declSpan.from, initSpan.from);
		final eq: Int = prefix.lastIndexOf('=');
		if (eq < 0) return Unreadable;
		final head: String = prefix.substring(0, eq);
		final at: Int = lastStandaloneIdentIndex(head, name);
		if (at < 0) return Unreadable;
		final colon: Int = head.indexOf(':', at);
		if (colon >= 0) {
			final text: String = head.substring(colon + 1).trim();
			return text == '' ? Unreadable : Written(text);
		}
		final first: Int = firstStandaloneIdentIndex(head, name);
		return first >= 0 && head.indexOf(':', first) < 0 ? Absent : Unreadable;
	}

	/**
	 * The annotation text `declaredType` read, or null when it read none — the `Null<String>`
	 * projection for a consumer that only TRANSCRIBES the annotation, for which an unreadable head
	 * and an absent one are the same answer: there is nothing to copy either way.
	 */
	public static function declaredTypeAnnotation(source: String, declSpan: Span, initSpan: Span, name: String): Null<String> {
		return switch declaredType(source, declSpan, initSpan, name) {
			case Written(text): text;
			case Absent, Unreadable: null;
		};
	}

	/**
	 * Whether `field` is a plain field with an initializer and is NOT a property — the
	 * shared candidate-shape gate of the `final`-conversion field checks. False when the
	 * field has no initializer (its first child carries no span) or its head before the
	 * initializer contains a `(` (a property accessor clause).
	 */
	public static function isInitializedNonPropertyField(source: String, field: QueryNode): Bool {
		final span: Null<Span> = field.span;
		if (span == null || field.children.length < 1) return false;
		final initSpan: Null<Span> = field.children[0].span;
		return initSpan != null && source.substring(span.from, initSpan.from).indexOf('(') < 0;
	}

	/**
		 * Whether a never-reassigned `var` (field or local) named `name` with declared
		 * simple type `declType` must STAY mutable because a method call on it may reassign
		 * an `abstract`'s underlying `this` — a mutation the assignment-operator write scans
		 * cannot see (`abstract Step(Int) { function next():Void this = this + 1; }` mutated
		 * only via `_s.next()`). Finalizing such a binding produces code the compiler rejects
		 * ("Cannot modify abstract value of final field").
		 *
		 * `index` is forced lazily — only after a method call is found — so most runs never build it. When
		 * the plugin carries a resolution scope, the forced index resolves against the configured libraries
		 * too, so a library abstract (e.g. openfl `ByteArray`) is recognised rather than treated as unknown.
		 *
		 * True (keep the `var`) when `name` has a method call in `source` outside its own declaration
		 * `exclude` AND its type either resolves to an abstract that may REBIND `this`
		 * (`SymbolIndex.abstractRebindsThis`) or is an UNRESOLVED non-stdlib type whose abstractness cannot
		 * be ruled out. False — the `final` suggestion stays sound and useful — for a resolved non-abstract
		 * type, a RESOLVED abstract whose only `this`-writes are in its constructor (the compiler forbids
		 * `this =` outside inline members and `final` rejects an inline this-writer transitively, so a
		 * ctor-only writer like `ByteArray` is final-safe) or that only `@:forward`s to a class underlying
		  * (which mutates the object, never the binding), a stdlib value type, an untyped binding, or no
	 * method call. A `@:build` abstract bails conservative (its members may be macro-generated and
	 * invisible).
	 *
	 * The `finalSafeStdlibTypes` whitelist is the ONE place this can be wrong, and its authority now
	 * extends past the fully-unresolved case: an abstract whose `@:forward` underlying the index cannot
	 * resolve answers `null` (see `SymbolIndex.abstractRebindsThis`), so a WHITELISTED simple name
	 * shadowed by such an abstract is called final-safe on the whitelist's word. Everything else only
	 * ever KEEPS a `var`.
	 */
	public static function abstractMethodMayMutate(
		source: String, name: String, declType: Null<String>, exclude: Span, index: () -> Null<SymbolIndex>, abstractKinds: Array<String>
	): Bool {
		if (declType == null || !methodCalledOn(source, name, exclude)) return false;
		final idx: Null<SymbolIndex> = index();
		final resolvedRebind: Null<Bool> = idx?.abstractRebindsThis(declType, abstractKinds);
		return resolvedRebind ?? !finalSafeStdlibTypes.contains(declType);
	}

	/**
	 * Index of the first byte at or after `pos` that is neither whitespace nor inside a line or block
	 * comment. A comment nothing closes leaves no such byte: the result is then past the source end,
	 * which every caller's own bound test rejects.
	 */
	public static function skipForwardTrivia(source: String, pos: Int): Int {
		final n: Int = source.length;
		var i: Int = pos;
		while (i < n) {
			if (isSpace(source.fastCodeAt(i))) {
				i++;
				continue;
			}
			final commentEnd: Int = commentRegionEnd(source, i);
			if (commentEnd < 0) break;
			i = commentEnd;
		}
		return i;
	}

	/**
	 * The offset just past the comment opening at `at`, or -1 when no comment opens there — the one
	 * comment scan behind `skipForwardTrivia`, `headerScan` and `isReturnTypeSlot`, each of which
	 * used to carry its own copy.
	 *
	 * A comment that NEVER CLOSES yields `source.length + 1`, one past every valid offset, so a
	 * caller's `> bound` test rejects it at ANY bound including the source end. That is what lets
	 * `isReturnTypeSlot` — whose `true` means "rewrite this" — fail closed on an unterminated `/*`
	 * while a cursor-advancing caller reads the same value as "trivia to the end" and stops.
	 *
	 * Bounding is the CALLER's job: the scan reads the whole of `source` and never clamps, because
	 * the three consumers bound it differently (a header range, a body start, the source end) and a
	 * clamp would make "closed exactly at the bound" indistinguishable from "never closed".
	 */
	public static function commentRegionEnd(source: String, at: Int): Int {
		if (at + 1 >= source.length || source.fastCodeAt(at) != '/'.code) return -1;
		final next: Int = source.fastCodeAt(at + 1);
		if (next == '*'.code) {
			final close: Int = source.indexOf('*/', at + 2);
			return close < 0 ? source.length + 1 : close + 2;
		}
		if (next != '/'.code) return -1;
		final nl: Int = source.indexOf('\n', at + 2);
		return nl < 0 ? source.length + 1 : nl + 1;
	}

	/** Extend a member's `span` back over own-line leading comments and forward over a same-line trailing comment, yielding its full source slot. */
	public static function memberTriviaSpan(source: String, span: Span, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Span {
		final from: Int = absorbLeadingComments(source, comments, span.from);
		var to: Int = span.to;
		final t: Null<{ from: Int, to: Int, isLine: Bool }> = firstCommentStartingAfter(comments, to);
		if (t != null && source.substring(to, t.from).trim() == '' && source.substring(to, t.from).indexOf('\n') < 0) to = t.to;
		return new Span(from, to);
	}

	/**
	 * The start offset of the contiguous own-line comment block immediately preceding the
	 * line that contains `pos` (only whitespace between the comments and that line), or that
	 * line's start when none exists. Lets a reorder absorb a doc comment sitting just before
	 * a `#if` directive into the conditional it documents.
	 */
	public static function leadingCommentBlockStart(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, pos: Int): Int {
		return absorbLeadingComments(source, comments, lineStartOf(source, pos));
	}

	/**
	 * The offset just past the first token at `from` — the run of identifier characters
	 * when `from` is on one (a name / keyword), else the single delimiter / operator
	 * character. Lets a cursor land anywhere within a node's opening token and still
	 * resolve the node, matching the forgiving `ast --at` rather than an exact `span.from`.
	 */
	public static function firstTokenEnd(source: String, from: Int): Int {
		if (from < 0 || from >= source.length) return from;
		if (!isIdentChar(source.fastCodeAt(from))) return from + 1;
		var i: Int = from + 1;
		while (i < source.length && isIdentChar(source.fastCodeAt(i))) i++;
		return i;
	}

	/**
	 * The outermost node whose FIRST TOKEN the cursor falls within (the first in pre-order)
	 * together with its parent — the list element / member the cursor's first token
	 * identifies. The bound is EXCLUSIVE of the token's trailing boundary so a container's
	 * single-char delimiter (`[` / `{` / `(`) does not swallow the element beginning right
	 * after it; a column landing inside a name still resolves it. Null when no node's first
	 * token contains `cursor`. The tolerant twin of `nodeAtFrom` for the USER-cursor ops
	 * (`add-element`, `remove-element`); `nodeAtFrom` stays exact for the internal callers
	 * that pass an already-resolved binding span.
	 */
	public static function elementAtFrom(tree: QueryNode, source: String, cursor: Int): Null<{ node: QueryNode, parent: Null<QueryNode> }> {
		var result: Null<{ node: QueryNode, parent: Null<QueryNode> }> = null;
		function walk(node: QueryNode, parent: Null<QueryNode>): Void {
			if (result != null) return;
			final sp: Null<Span> = node.span;
			if (sp != null && cursor >= sp.from && cursor < firstTokenEnd(source, sp.from)) {
				result = { node: node, parent: parent };
				return;
			}
			for (c in node.children) {
				if (result != null) return;
				walk(c, node);
			}
		}
		walk(tree, null);
		return result;
	}

	/**
	 * Every name a case PATTERN binds in `node`'s subtree: each name inside a
	 * `casePatternKind` subtree (a capture projects as a bare identifier there, so the
	 * whole pattern is collected — a constructor name coming along only costs the caller a
	 * report) plus the name of every `binderKinds` node, which carries its binding on the
	 * node itself (`case var x:`). Deduped, one walk.
	 */
	public static function casePatternNames(node: QueryNode, casePatternKind: Null<String>, binderKinds: Array<String>): Array<String> {
		final out: Array<String> = [];
		collectCasePatternNames(node, false, casePatternKind, binderKinds, out);
		return out;
	}

	/**
	 * Whether `text` contains a comma outside any `()`/`[]`/`{}` nesting and outside a
	 * string literal — the multi-declaration separator of `var i, j = n`. `<>` is
	 * deliberately not tracked (a generic type-parameter comma reads as top-level,
	 * which consumers treat conservatively).
	 * Whether `decl` is a MULTI-declarator list (`var a = 1, b = 2` / `var a, b`) rather than a
	 * single binding — every binding after the first projects as a continuation node, so the
	 * question the grammar already answers is asked of the TREE. `continuationKinds` is the
	 * plugin's `localDeclContinuationKinds` (Haxe: `VarMore`). Supersedes scanning the
	 * declaration's source text for a separator comma: no character-level scan can tell
	 * `var a = 1, b = 2` from the comma inside a `Map<K, V>` annotation, and reading the latter
	 * as a separator makes a rewrite refuse a shape it handles perfectly.
	 */
	public static function isMultiDeclarator(decl: QueryNode, continuationKinds: Array<String>): Bool {
		for (child in decl.children) if (continuationKinds.contains(child.kind)) return true;
		return false;
	}

	/**
	 * `lines` without its leading / trailing whitespace-only entries — the shared
	 * edge-trim behind `docComment`, `NewFile`'s `@@`-section bodies and the
	 * `fragmented-doc-comment` fix (internal blanks are kept).
	 */
	public static function trimBlankEdges(lines: Array<String>): Array<String> {
		final out: Array<String> = lines.copy();
		while (out.length > 0 && StringTools.trim(out[0]) == '') out.shift();
		while (out.length > 0 && StringTools.trim(out[out.length - 1]) == '') out.pop();
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
	 * The verbatim declared type SOURCE a BARE identifier carries when it names no value binding at
	 * all but IS a member — declared directly or INHERITED — of the enclosing type declaration: the
	 * implicit-`this` read Haxe resolves without the qualifier. `SymbolIndex`'s import-aware walk
	 * supplies it (`resolvePathFinalMemberTypeSource` over a one-segment member path), so the
	 * extends chain is followed to the SPECIFIC supertype each clause names rather than to any
	 * same-simple-named type elsewhere in the scope.
	 *
	 * Null — the caller keeps its conservative branch — whenever: `ident` is not an identifier node;
	 * it DOES resolve to a value binding; no enclosing type declaration covers it; or the member is
	 * unresolved / ambiguous anywhere along the chain.
	 *
	 * `invisibleBinders` is the gate that is not about resolution but about VISIBILITY, and it is
	 * load-bearing: a binder the scope resolver cannot see looks EXACTLY like an unbound name, so
	 * without it this arm answers the enclosing type's member for a local the author actually wrote
	 * — and a rewrite built on that answer breaks the build. Build the list with
	 * `resolverInvisibleBinderNames`, which is per-file while this is per-site. A NULL list — the
	 * grammar exposes no seam for one of the binder classes — is refused outright: an EMPTY list
	 * means "this file binds nothing invisibly", a null one means the question cannot be asked.
	 */
	public static function implicitThisMemberTypeSource(
		ident: QueryNode, root: QueryNode, shape: RefShape, index: SymbolIndex, file: String, invisibleBinders: Null<Array<String>>
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (identKind == null || ident.kind != identKind || name == null || span == null) return null;
		if (name == shape.selfReferenceText) return null;
		if (invisibleBinders == null || invisibleBinders.contains(name)) return null;
		if (TypeResolver.resolveBindingFrom(name, span, root, shape) != null) return null;
		final enclosing: Null<String> = TypeResolver.enclosingTypeName(root, span);
		return enclosing == null ? null : index.resolvePathFinalMemberTypeSource(file, enclosing, [name]);
	}

	/**
	 * Every name bound in `root` by a construct the SCOPE RESOLVER cannot see — the shadow set a
	 * consumer must subtract before reading an unbound identifier as anything but a local. Null when
	 * the grammar exposes no seam for one of the classes, which a consumer must read as "the shadow
	 * cannot be ruled out" rather than as an empty set.
	 *
	 * Two classes, each confirmed against the Haxe grammar rather than assumed (the parenthesized
	 * lambda param, the `catch` binder and a local function's own parameters all DO resolve, and are
	 * deliberately absent):
	 *
	 *  - CASE PATTERNS (`case Leaf(m):`) — the binder lives inside the pattern subtree.
	 *  - the BARE single-parameter arrow lambda (`m -> m.f()`), whose parameter the grammar projects
	 *    as a plain identifier expression indistinguishable from a read — the model carries no binder
	 *    node to resolve, so the resolver has nothing to bind. Recovering that distinction in the
	 *    projection would close this for every consumer at once and delete this arm; until then the
	 *    name is vetoed wherever it appears in the file.
	 */
	public static function resolverInvisibleBinderNames(root: QueryNode, shape: RefShape): Null<Array<String>> {
		final identKind: Null<String> = shape.identKind;
		final lambdaKinds: Null<Array<String>> = shape.lambdaKinds;
		final binderKinds: Array<String> = shape.casePatternBinderKinds ?? [];
		if (identKind == null || lambdaKinds == null || (shape.plainCasePatternKind == null && binderKinds.length == 0)) return null;
		final names: Array<String> = casePatternNames(root, shape.plainCasePatternKind, binderKinds);
		collectBareLambdaParamNames(root, identKind, lambdaKinds, names);
		return names;
	}

	/**
	 * The OPERAND children of an iteration node — its iterable and its body — with the VALUE binder
	 * of a key-value iteration filtered out. A consumer indexing `children[0]` for the iterable, or
	 * comparing `children.length` against a fixed operand count, reads the binder instead on every
	 * key-value loop.
	 */
	public static function loopOperands(loop: QueryNode, valueBinderKinds: Array<String>): Array<QueryNode> {
		return [for (c in loop.children) if (!valueBinderKinds.contains(c.kind)) c];
	}

	/**
	 * A memoized `SymbolIndex` builder — built at most once, on first call, over `files`. Shared by
	 * checks whose path-receiver type gate needs cross-file resolution only after cheaper structural
	 * gates pass, so most runs never trigger the build. When `plugin` is a `SymbolIndexHost` carrying
	 * ANY resolution scope — a declared one (report files UNION the configured library roots) or the
	 * implicit std-only one — that host's memoised resolution index is preferred, so the check resolves
	 * against libraries and std too.
	 *
	 * The report-only fallback below it is therefore no longer the ordinary path: on a Haxe-equipped
	 * machine a `Cli` run always takes the host branch, and the fallback answers only for a direct
	 * `check.run` with a bare plugin (every unit test that pins report-scope behaviour) or a machine
	 * with no discoverable std. `prebuilt`, when supplied, is an already-built report-scope index that
	 * fallback returns as-is instead of building a second one — `prefer-final-field` passes the eager
	 * index it already holds. It is ignored when a resolution scope is present, since the wider index
	 * must win; that is not a lost optimisation, because the host's index is a DIFFERENT (wider) index
	 * than `prebuilt`, so there is no duplicate build to avoid on that path.
	 */
	public static function lazySymbolIndex(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?prebuilt: SymbolIndex
	): () -> Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		if (host != null && host.hasAnyResolutionScope()) {
			final resolver: SymbolIndexHost = host;
			return () -> resolver.resolutionIndex();
		}
		if (prebuilt != null) {
			final ready: SymbolIndex = prebuilt;
			return () -> ready;
		}
		var index: Null<SymbolIndex> = null;
		var built: Bool = false;
		return () -> {
			if (!built) {
				built = true;
				index = SymbolIndex.build(files, plugin);
			}
			return index;
		};
	}

	/** Is `offset` inside any of `spans` (`from`-inclusive, `to`-exclusive)? */
	public static function offsetWithinAny(offset: Int, spans: Array<Span>): Bool {
		for (s in spans) if (offset >= s.from && offset < s.to) return true;
		return false;
	}

	/**
	 * The offset at which an `extends` / `implements` clause can be spliced into
	 * the header of `decl` (named `typeName`): just past its last header token,
	 * before the body `{`. AST-anchored - each header child node (a type-parameter
	 * constraint, an `extends` / `implements` clause, a conditional block) bounds
	 * the search, and the search itself steps over comments and string literals,
	 * so a `{` written inside a header comment or inside a structural type
	 * constraint is never mistaken for the body brace. Null when no body brace can
	 * be verified before the first body member; a caller that gets null must
	 * refuse the whole operation rather than splice at an unverified offset.
	 *
	 * The name token is located with `activeCodeIdentTokenOffset`, not the raw
	 * scan: a leading block comment that repeats the type name would otherwise
	 * win the race for it, and the whole header search would then run inside that
	 * comment - splicing the clause into comment text. The result still PARSES, so
	 * no downstream reparse gate catches it, while the caller has already staged
	 * the member cut: the members move out and nothing inherits them.
	 */
	public static function typeHeaderInsertOffset(source: String, decl: TypeDeclMatch, typeName: String): Null<Int> {
		final brace: Null<Int> = typeBodyBraceOffset(source, decl, typeName);
		return brace == null ? null : headerScan(source, typeHeaderFrom(source, decl, typeName), brace).tokenEnd;
	}

	/**
	 * The offset of `decl`'s body-opening `{`, or null when it has no brace body (`typedef T = Int;`).
	 * Scanned over the HEADER only — comment- and string-aware (`headerScan`), and cut short at the
	 * first child that starts after a located brace, so a `{` inside a type-parameter constraint or a
	 * header comment cannot be mistaken for the body's.
	 *
	 * The position an insertion takes from here is `brace + 1`: right AFTER the brace, never before
	 * the first member — that position sits past the member's leading doc comment, which the insertion
	 * would then silently steal.
	 */
	public static function typeBodyBraceOffset(source: String, decl: TypeDeclMatch, typeName: String): Null<Int> {
		final nameSpan: Span = decl.nameNode.span ?? decl.fullSpan;
		final limit: Int = nameSpan.to <= source.length ? nameSpan.to : source.length;
		var from: Int = typeHeaderFrom(source, decl, typeName);
		var brace: Int = -1;
		// Children are in document order: the first one that starts after a located
		// brace belongs to the body, every earlier one is part of the header.
		for (child in decl.nameNode.children) {
			final s: Null<Span> = child.span;
			if (s == null) continue;
			brace = headerScan(source, from, s.from < limit ? s.from : limit).brace;
			if (brace >= 0) break;
			if (s.to > from) from = s.to;
		}
		if (brace < 0) brace = headerScan(source, from, limit).brace;
		return brace < 0 || source.fastCodeAt(brace) != '{'.code ? null : brace;
	}

	/**
	 * Classify every word-boundary occurrence of `name` in `source[from...end)`
	 * (offsets inside `excluded` skipped) by lexical context, built on top of the
	 * parse so `#if...#end` regions and trivia are exact. Returns null when
	 * `source` does not parse — the caller then falls back to the raw scan
	 * (fail-closed). See `OccurrenceClass` for what each class means.
	 */
	public static function classifyOccurrences(
		source: String, name: String, plugin: GrammarPlugin, from: Int, end: Int, excluded: Array<Span>
	): Null<Array<ClassifiedOccurrence>> {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return null catch (exception: Exception) return null;
		final out: Array<ClassifiedOccurrence> = [];
		final len: Int = name.length;
		if (len == 0) return out;
		final condSpans: Array<Span> = [];
		collectConditionalSpans(tree, condSpans);
		final regions: Array<LexRegion> = scanLexicalRegions(source);
		final stop: Int = end <= source.length ? end : source.length;
		var i: Int = from;
		while (i + len <= stop) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + len > stop) break;
			i = at + 1;
			final afterIdx: Int = at + len;
			final beforeOk: Bool = at == 0 || !isIdentChar(source.fastCodeAt(at - 1));
			final afterOk: Bool = afterIdx >= source.length || !isIdentChar(source.fastCodeAt(afterIdx));
			if (beforeOk && afterOk && !offsetWithinAny(at, excluded))
				out.push({ span: new Span(at, afterIdx), kind: classifyAt(source, at, len, condSpans, regions) });
		}
		return out;
	}

	/**
	 * Whether the field declared by `field` can become `final` off its CONSTRUCTOR
	 * assignment: it has no declaration initializer (a `final` with one cannot be
	 * reassigned in the constructor) and no `(` in its declaration head (which covers
	 * properties and parenthesised function types), its sole write is exactly one
	 * constructor assignment `x = expr` / `this.x = expr` OUTSIDE a closure
	 * (`soleConstructorFieldWrite`), it is not static (`static final` requires a
	 * declaration initializer), and no other write to its name appears anywhere in
	 * `source` — a conservative text scan (`MemberWriteScan.writtenInRange`) that also
	 * sees `#if` bodies the structural walkers cannot. A `@:build` macro injecting a
	 * writer is the residual blind spot, shared with every other arm of the three
	 * consumers and surfacing as a loud compile error at the injected write.
	 *
	 * The write need NOT be a top-level STATEMENT — an assignment embedded in a call
	 * argument (`super([_a = new Row(…)])`) qualifies, because `var` -> `final` changes
	 * no evaluation and the only nesting Haxe rejects for a `final` field is a closure,
	 * which `soleConstructorFieldWrite` refuses. A shadowing local or parameter that
	 * owns the assignment leaves the field a `var`.
	 *
	 * The shared core of the constructor arms of `prefer-final-field` /
	 * `prefer-final-public-field` AND of `prefer-read-only-field`'s cession of the same
	 * candidates — all three MUST agree on it, or a ctor-assigned field either gets two
	 * conflicting fixes or none. A new single-file soundness gate for the arm therefore
	 * belongs INSIDE this predicate, never in one consumer — and mind its cost:
	 * predicate-false routes the field to `prefer-read-only-field`'s `(default, null)`.
	 * Each check wraps it in its own cross-file write gates; this predicate is
	 * single-file only.
	 */
	public static function ctorSoleAssignmentFinalizable(source: String, field: QueryNode, plugin: GrammarPlugin): Bool {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return false;
		if (field.children.length >= 1) return false;
		if (source.substring(span.from, span.to).indexOf('(') >= 0) return false;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return false;
		final shape: RefShape = plugin.refShape();
		final loc: Null<{ container: QueryNode, field: QueryNode }> = classLikeFieldAt(tree, span.from, shape);
		if (loc == null) return false;
		final ctor: Null<QueryNode> = soleConstructor(loc.container, shape);
		if (ctor == null) return false;
		// `soleConstructorFieldWrite` rather than `soleConstructorFieldInit`: the write need not be a
		// top-level STATEMENT, only the constructor's sole assignment to the field, so an assignment
		// EXPRESSION consumed in place (`super([_a = new Row(…)])`) qualifies.
		final write: Null<{ assign: QueryNode, rhs: QueryNode, target: Span }> = soleConstructorFieldWrite(
			loc.container, ctor, loc.field, shape
		);
		if (write == null) return false;
		final writeSpan: Null<Span> = write.assign.span;
		// Haxe would ALSO accept `final` for a write nested in a branch, a loop or a lazy operand — it
		// runs no definite-assignment analysis — but this predicate keeps demanding an unconditional
		// position, which is what a top-level statement gave it before. Widening that is a separate
		// judgement about whether a conditionally-assigned `final` is worth reporting, not a
		// consequence of admitting the embedded shape, and `testNoInitConditionalNotFlagged` pins the
		// answer the three consumers ship today.
		if (writeSpan == null || !ctorWriteUnconditional(ctor, writeSpan.from, shape)) return false;
		return !staticMemberFroms(loc.container, shape).contains(span.from)
			&& !MemberWriteScan.writtenInRange(source, name, write.target, 0, source.length);
	}

	/**
	 * Whether `name` is BOUND as an identifier anywhere in `source[from...end)`
	 * outside `excluded` - the precise form of the question a COLLISION gate asks:
	 * "is the target name already taken where this rename lands?". Answered from
	 * the parse (`classifyOccurrences`) instead of raw text, so a comment mention,
	 * an inert string literal and the member-name slot of a dotted access
	 * (`o.name`) are correctly none of them bindings.
	 *
	 * NOT a replacement for `referencedInRange`, whose imprecision is
	 * LOAD-BEARING for its other callers: the `unused-*` family reads a `false`
	 * as "nothing uses this, delete it", and the occurrences skipped here - a
	 * dotted `obj.member` above all - are exactly its real uses. The conservative
	 * direction of the question belongs to the CALL SITE, so the two queries
	 * coexist and only a veto-side caller may use this one.
	 *
	 * Deliberately conservative wherever a precise answer would cost another
	 * scan: CODE inside a `#if` body counts (it hosts real declarations), a
	 * single-quoted literal that can interpolate counts wholesale rather than
	 * resolving which of its parts are code, a comment between the dot and the name
	 * leaves the dotted test false, and a parse failure falls back to
	 * `referencedInRange`. Each of those over-reports, which for a veto gate is a
	 * missed fix - never a wrong one.
	 *
	 * A STRUCTURE-FIELD name is not excluded here: it needs the parse tree, which
	 * this signature does not carry, and its safety is caller-dependent (a
	 * `@:structInit` object literal DOES name the class's own fields). The caller
	 * that can cede it passes `structureFieldNameSpans` in `excluded`.
	 */
	public static function nameBoundInRange(
		source: String, name: String, from: Int, end: Int, excluded: Array<Span>, plugin: GrammarPlugin
	): Bool {
		final classified: Null<Array<ClassifiedOccurrence>> = classifyOccurrences(source, name, plugin, from, end, excluded);
		if (classified == null) return referencedInRange(source, name, from, end, excluded);
		final regions: Array<LexRegion> = scanLexicalRegions(source);
		for (occ in classified) switch occ.kind {
			// A word inside a longer literal binds nothing, whatever the literal interpolates.
			case CommentTrivia | DirectiveComment | StringWord:
			case StringLiteral if (!interpolatingLiteralAt(source, occ.span.from, regions)):
			case _:
				if (!isMemberNamePosition(source, occ.span.from)) return true;
		}
		return false;
	}

	/**
	 * The identifier-token span of every STRUCTURE-FIELD name in `tree` — a member of an
	 * anonymous-structure type (`{ x:Float }`), of an object literal (`{ x: 1 }`) or of a
	 * structure PATTERN (`case { x: n }`), per `shape.structureFieldHostKinds`. Such a name
	 * is reachable only through a receiver, so it binds nothing in the surrounding scope and
	 * a collision gate over a LOCAL / PARAMETER rename may subtract it: a module-level
	 * `typedef Zoom = { x:Float }` otherwise vetoes every `_x -> x` in the file.
	 *
	 * Only the NAME token is returned, never the whole field node — an object literal's VALUE
	 * is ordinary code that may well bind the name. Empty for a grammar leaving the slot unset.
	 *
	 * Not for a FIELD rename: under `@:structInit` an object literal's keys ARE the class's
	 * own field names, so subtracting them would silently break the construction site.
	 */
	public static function structureFieldNameSpans(tree: QueryNode, source: String, shape: RefShape): Array<Span> {
		final out: Array<Span> = [];
		final hosts: Array<String> = shape.structureFieldHostKinds ?? [];
		if (hosts.length > 0) collectStructureFieldNames(tree, source, hosts, out);
		return out;
	}

	/**
	 * The two-edit fold of a NULL-GUARDED constructor default: a field declared WITH a
	 * default (`var x:T = D;`, plain or `(default, null)`) whose only write beyond that
	 * initializer is exactly one top-level constructor statement of the shape
	 * `if (p != null) x = p;` (`this.x = p` alike) becomes `final x:T;` plus
	 * `x = p ?? D;`. Returns the edits when the fold applies, `null` otherwise — the
	 * non-null result IS the fix, so a rule's `run` and `fix` can never disagree about a
	 * candidate, and the two edits are one unit that lands together or not at all.
	 *
	 * Fails closed on every doubt. All single-file gates live HERE, never in one
	 * consumer, so the rules claiming these candidates (`prefer-final-field`,
	 * `prefer-final-public-field`) and the one ceding them (`prefer-read-only-field`)
	 * cannot drift apart:
	 *
	 *  - the declaration carries an initializer, is not `static`, and its head is either
	 *    plain or exactly the `(default, null)` accessor pair — `final` reproduces that
	 *    access exactly (readable anywhere, writable nowhere outside the declaration),
	 *    while any other pair (`get, set`, `default, never`, …) it does not;
	 *  - the default expression is MOVE-SAFE (`moveSafeDefault`): a numeric / boolean /
	 *    non-interpolated string literal, a negated numeric literal, or a dotted access
	 *    rooted at a capitalised identifier (a type-qualified constant or enum value).
	 *    An allocation (`new T()`, `[]`), a call, `this`, and a bare identifier — which
	 *    could be another instance field, not yet initialized at constructor position —
	 *    are rejected: moving them would change allocation identity or evaluation order;
	 *  - the enclosing type has exactly one constructor, holding exactly one top-level
	 *    guarded statement of the shape above, whose parameter is optional, `Null<…>`
	 *    wrapped, or `= null`-defaulted (a non-nullable parameter cannot be
	 *    `??`-defaulted);
	 *  - no other write to the field name appears ANYWHERE in the file — the same
	 *    conservative raw-text scan `ctorSoleAssignmentFinalizable` uses, which sees
	 *    `#if` bodies — with the declaration and that one constructor target excluded.
	 *
	 * Cross-file soundness (an external, subtype, or unresolved write; an `@:access`
	 * grantee) stays the CONSUMER's job, exactly as for `ctorSoleAssignmentFinalizable`.
	 * Residual: a mutable static read by the default and written from ANOTHER file could
	 * still differ between declaration and constructor position; the in-file leg of that
	 * check lives in `moveSafeDefault`.
	 */
	public static function ctorConditionalDefaultFinalEdits(
		source: String, declSpan: Span, plugin: GrammarPlugin
	): Null<Array<{ span: Span, text: String }>> {
		final shape: RefShape = plugin.refShape();
		final coalesce: Null<String> = shape.nullCoalesceOperatorText;
		if (coalesce == null || source.substring(declSpan.from, declSpan.to).indexOf('=') < 0) return null;
		final spans: Array<Null<Span>> = [declSpan];
		final edits: Array<{ span: Span, text: String }> = varKeywordToFinalEdits(source, spans);
		if (edits.length != 1) return null;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return null;
		final loc: Null<{ container: QueryNode, field: QueryNode }> = classLikeFieldAt(tree, declSpan.from, shape);
		if (loc == null) return null;
		final decl: Null<FoldableDecl> = foldableDeclaration(source, loc, declSpan, shape);
		final ctor: Null<QueryNode> = soleConstructor(loc.container, shape);
		if (decl == null || ctor == null) return null;
		final guarded: Null<GuardedCtorInit> = soleGuardedCtorFieldInit(source, loc.container, ctor, loc.field, shape);
		if (guarded == null || !ctorParamIsNullable(source, ctor, guarded.param, shape)) return null;
		if (!guardReachedIntact(source, ctor, decl.name, guarded.stmt.from, shape)) return null;
		if (
			MemberWriteScan.writtenInRange(source, decl.name, guarded.target, 0, decl.span.from)
			|| MemberWriteScan.writtenInRange(source, decl.name, guarded.target, decl.span.to, source.length)
		)
			return null;
		final dropped: Null<Span> = decl.dropped;
		if (dropped != null) edits.push({ span: dropped, text: '' });
		edits.push({ span: decl.initDrop, text: '' });
		final targetText: String = source.substring(guarded.target.from, guarded.target.to);
		final defaultText: String = source.substring(decl.initSpan.from, decl.initSpan.to);
		edits.push({ span: guarded.stmt, text: '$targetText = ${guarded.param} $coalesce $defaultText${guarded.terminator}' });
		return edits;
	}

	/**
	 * The edits finalizing a set of flagged field declarations: the two-edit
	 * conditional-default fold (`ctorConditionalDefaultFinalEdits`) where it applies, a
	 * bare `var` -> `final` keyword swap everywhere else. The shared back end of
	 * `prefer-final-field` / `prefer-final-public-field`'s `fix`, so both rules emit the
	 * same shape for the same candidate, and each fold's edits travel as one unit through
	 * the caller's single per-file canonicalize (all of them apply, or the file reverts).
	 */
	public static function finalizeFieldEdits(
		source: String, spans: Array<Null<Span>>, plugin: GrammarPlugin
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		final plain: Array<Null<Span>> = [];
		for (span in spans) if (span != null) {
			final fold: Null<Array<{ span: Span, text: String }>> = ctorConditionalDefaultFinalEdits(source, span, plugin);
			if (fold == null)
				plain.push(span);
			else
				for (edit in fold) edits.push(edit);
		}
		for (edit in varKeywordToFinalEdits(source, plain)) edits.push(edit);
		return edits;
	}

	/**
	 * The span of a braceless `$name` interpolation read of the binding at `binding` that
	 * `occurrences` does NOT rewrite, or null when every one of them is covered.
	 *
	 * Asked over the resolved hits, not by walking the tree for the name: a read bound to a
	 * SHADOWING binding of the same name is none of this rename's business, and matching on
	 * the name alone refuses it as if it were. The read's node span covers the bytes that
	 * SPELL it (the `$` included), so a rewritten one CONTAINS its occurrence. One is
	 * missing exactly when `identTokenOffset` could not locate the identifier token in the
	 * raw source — an escape-spelled `$` or name — and splicing the rest would leave that
	 * read bound to a name the rewrite has removed.
	 */
	public static function unrewrittenInterpRead(hits: Array<RefHit>, binding: Int, occurrences: Array<Span>): Null<Span> {
		for (h in hits) if (h.interpolated) {
			final bound: Null<Span> = h.bindingSpan;
			if (bound == null || bound.from != binding) continue;
			if (!occurrences.exists(o -> h.span.from <= o.from && o.to <= h.span.to)) return h.span;
		}
		return null;
	}

	/**
	 * The span of a `${ … }` interpolation in `node`'s subtree that carries NO parsed
	 * expression, or null. Only the rescan of an escape-spelled `$` synthesizes one
	 * (`HxInterpProjection`): its interior does not exist contiguously in the source, so no
	 * subtree is built and any identifier read inside it is invisible to every reference
	 * scan — a rewrite touching such a name would silently part-apply. Reported
	 * unconditionally rather than by scanning the interior for a name: the interior may
	 * spell that name with escapes too, so a text scan cannot prove absence.
	 */
	public static function unreadableInterpBlock(node: QueryNode, blockKind: String): Null<Span> {
		if (node.kind == blockKind && node.children.length == 0) return node.span;
		for (c in node.children) {
			final found: Null<Span> = unreadableInterpBlock(c, blockKind);
			if (found != null) return found;
		}
		return null;
	}

	/**
	 * The span of an UNPARSED conditional-compilation region inside `scope` whose raw bytes
	 * spell `name` as a standalone identifier, or null when no region there could hold one.
	 *
	 * `RefShape.opaqueCondRegionKinds` names the ctors a grammar falls back to when a
	 * `#if … #end` region is not a balanced subtree. Such a node keeps its CONTINUATION as a
	 * child (the tail operand, the shared body, the statement after `#end`) and drops the
	 * region itself: nothing in it projects. So the unmodelled bytes are exactly the parts of
	 * the node's own span that no child covers, which is what this returns — the region text
	 * a diagnostic quotes back, not the whole node.
	 *
	 * Asked by TEXT because there is no tree to ask. That makes the test conservative in the
	 * one direction that is safe: a mention bound to some OTHER binding of the same name, or
	 * one sitting in a comment or a string literal inside the region, refuses a rename that
	 * would have been fine. Being wrong the other way is a silent miscompile in whichever
	 * build defines the condition, and no scan of a region with no nodes can do better.
	 * Standalone-identifier matching rather than a bare substring: a real reference is a
	 * token, so `tagName` does not count as a mention of `tag`, and an interpolated `$tag`
	 * still does (a `$` is not an identifier character).
	 */
	public static function opaqueCondRegionMentioning(scope: QueryNode, source: String, name: String, shape: RefShape): Null<Span> {
		final kinds: Array<String> = shape.opaqueCondRegionKinds ?? [];
		if (kinds.length == 0 || name.length == 0) return null;
		function walk(node: QueryNode): Null<Span> {
			final span: Null<Span> = node.span;
			if (span != null && kinds.contains(node.kind)) for (gap in unmodelledGaps(node, span)) if (mentionsIdent(source, gap, name))
				return gap;
			for (c in node.children) {
				final found: Null<Span> = walk(c);
				if (found != null) return found;
			}
			return null;
		}
		return walk(scope);
	}

	/**
	 * The fail-closed diagnostic every MUTATING op shares for an unparsed conditional-compilation
	 * region that mentions `name`, or null when `scope` holds none.
	 *
	 * One builder rather than a message per op: the refusal is the same fact everywhere (the model
	 * dropped these bytes, so no rewrite can be complete over them), and a reader who has met it
	 * once should recognise it from any op. `what` is the op's own subject, spelled as its other
	 * diagnostics spell it (`rename of "x"`, `inline of "f"`); `file` is included only when the op
	 * works over more than one, where a bare line:col would not locate the region.
	 */
	public static function opaqueCondRegionDiagnostic(
		source: String, scope: QueryNode, name: String, shape: RefShape, what: String
	): Null<String> {
		final region: Null<Span> = opaqueCondRegionMentioning(scope, source, name, shape);
		if (region == null) return null;
		final at: Position = region.lineCol(source);
		return '$what is unsafe: the unparsed conditional-compilation region at ${at.line}:${at.col} spells "$name" in bytes'
			+ ' the parser captured raw (${regionExcerpt(source, region)}), so no scan can see that occurrence and the'
			+ ' rewrite would leave it on the old name - restructure the region into a balanced #if first';
	}

	/**
	 * The first `opaqueCondRegionDiagnostic` any of `files` yields for `name`, prefixed with the
	 * file it came from, or null when none does.
	 *
	 * The multi-file arm every CROSS-file mutating op needs, as one pre-pass rather than a check
	 * threaded through each op's own rewrite loop: the refusal is atomic — a region anywhere in the
	 * scope defeats the whole edit set — so deciding it before the first edit is both cheaper and
	 * the only order that cannot half-apply. The file prefix is load-bearing here where the
	 * single-file arm's bare line:col is not: one coordinate names no file.
	 */
	public static function opaqueCondRegionInAny(
		files: Array<{ final file: String; final source: String; final tree: QueryNode; }>, name: String, shape: RefShape, what: String
	): Null<String> {
		for (f in files) {
			final opaque: Null<String> = opaqueCondRegionDiagnostic(f.source, f.tree, name, shape, what);
			if (opaque != null) return '${f.file}: $opaque';
		}
		return null;
	}

	/**
	 * A single-line excerpt of `span`'s source text for a diagnostic — whitespace runs collapsed
	 * to one space and the result capped at `REGION_EXCERPT_CHARS`, so a region spanning several
	 * source lines still names itself in one message line.
	 */
	private static function regionExcerpt(source: String, span: Span): String {
		final flat: String = ~/\s+/g.replace(source.substring(span.from, span.to), ' ').trim();
		return flat.length <= REGION_EXCERPT_CHARS ? flat : '${flat.substr(0, REGION_EXCERPT_CHARS)}...';
	}

	/**
	 * The parts of `span` that none of `node`'s direct children cover — the bytes the model
	 * dropped. Children are taken in span order and a child with no span contributes nothing,
	 * which widens the gap rather than narrowing it: the safe direction for a fail-closed gate.
	 */
	private static function unmodelledGaps(node: QueryNode, span: Span): Array<Span> {
		final covered: Array<Span> = [for (c in node.children) if (c.span != null) (c.span: Span)];
		covered.sort((a, b) -> a.from - b.from);
		final out: Array<Span> = [];
		var at: Int = span.from;
		for (c in covered) {
			if (c.from > at) out.push(new Span(at, c.from < span.to ? c.from : span.to));
			if (c.to > at) at = c.to;
		}
		if (at < span.to) out.push(new Span(at, span.to));
		return out;
	}

	/**
	 * Whether `source` spells `name` as a standalone identifier token anywhere inside `span`.
	 *
	 * A `#`-prefixed spelling is skipped: `#end` / `#if` / `#else` are the directive keywords that
	 * DELIMIT the region, not references inside it, and every such region ends in one — counting
	 * them would refuse every rename of a binding called `end` in any file carrying a splice.
	 */
	private static function mentionsIdent(source: String, span: Span, name: String): Bool {
		var at: Int = source.indexOf(name, span.from);
		while (at >= 0 && at + name.length <= span.to) {
			if (standaloneIdentAt(source, name, at) && (at == 0 || source.fastCodeAt(at - 1) != '#'.code)) return true;
			at = source.indexOf(name, at + 1);
		}
		return false;
	}

	/**
	 * The deepest function / lambda subtree containing `cursor`, or the whole tree when none
	 * does — the region a local binding can be referenced from, and therefore the scope a
	 * name-agnostic net (an unreadable interpolation hole, a same-block re-declaration) has
	 * to sweep.
	 *
	 * No containment pruning: the parse root (and other synthesized wrappers) carries NO
	 * span, so a prune at a null-span node would stop at the root and silently widen the
	 * scope to the whole file (false refusals for a same-named local in a SIBLING function).
	 * Gate only the match.
	 */
	public static function enclosingFunctionSubtree(tree: QueryNode, cursor: Int, shape: RefShape): QueryNode {
		final fnKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []);
		var best: QueryNode = tree;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && cursor >= span.from && cursor < span.to && fnKinds.contains(node.kind)) best = node;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * The function subtree the same-name guards sweep - the one that OWNS `binding`.
	 *
	 * Those guards ask a question about the BINDING - is this name declared twice in one block? -
	 * so the anchor is the binding's declaration, never the cursor. A read inside a nested local
	 * function or lambda resolves to a binding declared in the OUTER function, and a cursor anchor
	 * confines the sweep to that nested body, which holds no redeclaration: the guard passes and
	 * the rename silently rebinds every reference that followed the second declaration.
	 *
	 * A local `function g` is declared in its PARENT's block while its own span contains that
	 * declaration offset, so an anchor landing exactly on the function it names steps out one
	 * level. Otherwise renaming `g` from its own declaration would sweep only its body and miss
	 * the sibling `function g` two statements down. That is the climb the cursor anchor also needed,
	 * now gated on the binding's identity instead of on its name.
	 *
	 * A binding no function owns is a TYPE MEMBER, for which `enclosingFunctionSubtree` answers the
	 * whole tree. A block-local redeclaration cannot mis-bind a member's references - the duplicated
	 * locals shadow the member and bind only to each other - so sweeping the module for one would
	 * cost working renames and prove nothing (measured: 433 extra refusals across the installed
	 * haxelib). Such a binding keeps the cursor's own function, which is what shipped.
	 *
	 * Every step widens, which is the safe direction: `sameBlockRedeclaration` recurses through
	 * everything under the scope it is given, so a scope that is too wide can only over-refuse.
	 */
	public static function bindingHostSubtree(tree: QueryNode, cursor: Int, binding: Null<Int>, shape: RefShape): QueryNode {
		final cursorHost: QueryNode = enclosingFunctionSubtree(tree, cursor, shape);
		if (binding == null) return cursorHost;
		final host: QueryNode = enclosingFunctionSubtree(tree, binding, shape);
		if (host == tree) return cursorHost;
		final localFnKinds: Array<String> = (shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		final span: Null<Span> = host.span;
		if (span == null || span.from != binding || !localFnKinds.contains(host.kind)) return host;
		final parentSpan: Null<Span> = TreePath.parentOf(tree, host)?.span;
		return parentSpan == null ? tree : enclosingFunctionSubtree(tree, parentSpan.from, shape);
	}

	/**
	 * The span of a SECOND same-block declaration of `name` within `scope`, or null when every
	 * block there declares it at most once.
	 *
	 * Haxe allows re-declaring a name in one block, and the resolution index mis-binds every
	 * reference that follows the second declaration — each stays bound to the FIRST. Two ops have
	 * to refuse on that shape: `Rename`, whose splice would rewrite the wrong occurrences, and
	 * `ExtractMethod`, which reads the same index to decide whether a range-local escapes the
	 * range. Compared per PARENT node, so a re-declaration in a NESTED block — ordinary shadowing,
	 * which the index resolves correctly — is not reported.
	 *
	 * The vocabulary is `TypeResolver.blockScopedValueDeclarationKinds`, NOT the grammar's local-var
	 * lists alone: a local `function g() …` redeclared in one block is the same blind spot (every
	 * later `g()` stays bound to the first), and it reached both ops as a silent miscompile until the
	 * two vocabularies were derived from one place.
	 */
	public static function sameBlockRedeclaration(scope: QueryNode, name: String, plugin: GrammarPlugin, shape: RefShape): Null<Span> {
		final declKinds: Array<String> = TypeResolver.blockScopedValueDeclarationKinds(shape);
		final metaKinds: Array<String> = plugin.metaShape().metaKinds;
		function walk(node: QueryNode): Null<Span> {
			var seen: Bool = false;
			for (c in node.children) {
				if (topLevelDeclaredName(c, declKinds, metaKinds) == name) {
					if (seen) return c.span;
					seen = true;
				}
				final found: Null<Span> = walk(c);
				if (found != null) return found;
			}
			return null;
		}
		return walk(scope);
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

	/** Whether the occurrence of `name` at `at` in `head` stands alone — no identifier character on either side. */
	private static inline function standaloneIdentAt(head: String, name: String, at: Int): Bool {
		final after: Int = at + name.length;
		return (at == 0 || !isIdentChar(head.fastCodeAt(at - 1))) && (after >= head.length || !isIdentChar(head.fastCodeAt(after)));
	}

	/** Whether `kinds` is set and holds `kind` — an unset seam contributes nothing. */
	private static inline function kindIn(kinds: Null<Array<String>>, kind: String): Bool {
		return kinds != null && kinds.contains(kind);
	}

	/** Increment the integer counter for `key`. */
	private static inline function bumpCount(map: Map<String, Int>, key: String): Void {
		final cur: Null<Int> = map[key];
		map[key] = (cur ?? 0) + 1;
	}

	/** One of the flag letters Haxe accepts after a regex literal's closing `/`. */
	private static inline function isRegexFlag(c: Int): Bool {
		return c == 'g'.code || c == 'i'.code || c == 'm'.code || c == 's'.code || c == 'u'.code;
	}

	/** The index of the LAST occurrence of `name` in `head` that stands alone as an identifier, or -1. */
	private static function lastStandaloneIdentIndex(head: String, name: String): Int {
		var at: Int = head.lastIndexOf(name);
		while (at >= 0) {
			if (standaloneIdentAt(head, name, at)) return at;
			if (at == 0) return -1;
			at = head.lastIndexOf(name, at - 1);
		}
		return -1;
	}

	/** The index of the FIRST occurrence of `name` in `head` that stands alone as an identifier, or -1. */
	private static function firstStandaloneIdentIndex(head: String, name: String): Int {
		var at: Int = head.indexOf(name);
		while (at >= 0) {
			if (standaloneIdentAt(head, name, at)) return at;
			at = head.indexOf(name, at + 1);
		}
		return -1;
	}

	/** The offset just past `decl`'s NAME token — where its header (supertype clauses, type params) begins. */
	private static function typeHeaderFrom(source: String, decl: TypeDeclMatch, typeName: String): Int {
		final nameSpan: Span = decl.nameNode.span ?? decl.fullSpan;
		final nameAt: Int = activeCodeIdentTokenOffset(source, nameSpan, typeName);
		return nameAt < 0 ? nameSpan.from : nameAt + typeName.length;
	}

	/**
	 * Is `offset` inside a COMMENT region? The first lexical region that
	 * contains it decides; a string literal is not a comment, so code
	 * interpolated inside one stays eligible.
	 */
	private static function offsetWithinComment(offset: Int, regions: Array<LexRegion>): Bool {
		for (region in regions) if (offset >= region.from && offset < region.to) return switch region.kind {
			case LineComment | BlockComment: true;
			case StringLit | RegexLit: false;
		};
		return false;
	}

	/** The scan behind `referencedInRange` / `referencedUnqualifiedInRange`; a non-null `commentRegions` drops dot-qualified occurrences. */
	private static function scanReference(
		source: String, name: String, from: Int, end: Int, excluded: Array<Span>, commentRegions: Null<Array<Span>>
	): Bool {
		final len: Int = name.length;
		if (len == 0) return false;
		final stop: Int = end <= source.length ? end : source.length;
		var i: Int = from;
		while (i + len <= stop) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + len > stop) return false;
			final beforeOk: Bool = at == 0 || !isIdentChar(source.fastCodeAt(at - 1)) || interpolationEscapeBefore(source, at);
			final afterIdx: Int = at + len;
			final afterOk: Bool = afterIdx >= source.length || !isIdentChar(source.fastCodeAt(afterIdx));
			if (beforeOk && afterOk && !offsetWithinAny(at, excluded) && !qualifiedBefore(source, at, commentRegions)) return true;
			i = at + 1;
		}
		return false;
	}

	/**
	 * Is the token starting at `at` the TAIL of a dotted path — its preceding
	 * non-whitespace character a qualification `.`? Whitespace is skipped
	 * backwards, since a path may be broken across lines (`haxe.macro\n\t.Context`).
	 * A null `commentRegions` disables the test entirely (the plain
	 * `referencedInRange` scan, which counts every occurrence).
	 *
	 * Two dots are NOT one: a dot preceded by another belongs to `...` (range /
	 * rest), never to a field access, so `0...Limit.MAX` reads `Limit` as the bare
	 * reference it is. And a dot inside a COMMENT qualifies nothing — the period
	 * ending `// … before the process dies.` sits directly before the next line's
	 * first token and would otherwise mark a live call as a qualified tail. Only a
	 * LINE comment can end in a bare `.` that way — every other inert construct
	 * closes with its own delimiter — but the mask is exact for all of them.
	 *
	 * WHITESPACE only, not trivia: a comment spliced between the dot and the name
	 * stops the walk short, so that occurrence reads as unqualified and COUNTS.
	 * The over-counting direction — an import kept, never one deleted.
	 */
	private static function qualifiedBefore(source: String, at: Int, commentRegions: Null<Array<Span>>): Bool {
		if (commentRegions == null) return false;
		var j: Int = at - 1;
		while (j >= 0 && isSpace(source.fastCodeAt(j))) j--;
		return j >= 0 && source.fastCodeAt(j) == '.'.code && (j <= 0 || source.fastCodeAt(j - 1) != '.'.code)
			&& !offsetWithinAny(j, commentRegions);
	}

	/**
	 * Whether the text directly before `at` is a numeric escape spelling the
	 * interpolation trigger `$` — `\x24` or `$`. A string literal's escapes are
	 * DECODED before the interpolation scan runs over the result, so `'\x24name'` is a
	 * read of `name` exactly as `'$name'` is; but the escape ends in a hex digit, which
	 * the word-boundary test above reads as "still the same token" and would report as
	 * NO reference — the one direction that costs a wrongly deleted binding.
	 *
	 * Deliberately spelling-based, not decode-based: this scan runs over raw source
	 * with no idea which regions are string literals, so `'\\x24name'` (a literal
	 * backslash, decoding to no `$` at all) also answers yes. That is the harmless
	 * direction — an extra KEPT binding, the same over-counting the textual scan
	 * already accepts for names inside comments.
	 */
	private static function interpolationEscapeBefore(source: String, at: Int): Bool {
		return DOLLAR_ESCAPES.exists(e -> at >= e.length && source.substr(at - e.length, e.length) == e);
	}

	private static function collectModulePathSpans(node: QueryNode, kinds: Array<String>, out: Array<Span>): Void {
		final span: Null<Span> = node.span;
		if (kinds.contains(node.kind) && span != null) {
			out.push(span);
			return;
		}
		for (child in node.children) collectModulePathSpans(child, kinds, out);
	}

	/**
	 * Whether a top-level constructor statement of `kind` ALWAYS COMPLETES NORMALLY — control
	 * reaches the statement after it, whatever the statement does internally. Membership only:
	 * the KIND is what is decided here, never the subtree, which is `ctorPrefixUnconditional`'s
	 * scan's job. A LOOP is deliberately absent; that entry documents why.
	 *
	 * Each set is read straight off its `RefShape` seam and tested in place rather than folded
	 * into one array: the seams never change during a run, and this is asked once per prefix
	 * statement per candidate FIELD, so building the union per call would allocate for nothing.
	 */
	private static function completesNormally(kind: String, shape: RefShape): Bool {
		return kind == shape.exprStatementKind || isConditionalKind(kind) || kindIn(shape.localDeclKinds, kind)
			|| kindIn(shape.staticLocalDeclKinds, kind) || kindIn(shape.ifStatementKinds, kind) || kindIn(shape.switchKinds, kind)
			|| kindIn(shape.tryStatementKinds, kind) || kindIn(shape.localFunctionKinds, kind) || kindIn(shape.inlineFunctionKinds, kind);
	}

	/** Recursive worker of `casePatternNames`; `inPattern` marks a subtree already inside a pattern. */
	private static function collectCasePatternNames(
		node: QueryNode, inPattern: Bool, casePatternKind: Null<String>, binderKinds: Array<String>, out: Array<String>
	): Void {
		final within: Bool = inPattern || (casePatternKind != null && node.kind == casePatternKind);
		final name: Null<String> = node.name;
		if (name != null && (within || binderKinds.contains(node.kind)) && !out.contains(name)) out.push(name);
		for (child in node.children) collectCasePatternNames(child, within, casePatternKind, binderKinds, out);
	}

	/** Append every bare (unparenthesized) arrow-lambda parameter name in `node`'s subtree to `out`. */
	private static function collectBareLambdaParamNames(
		node: QueryNode, identKind: String, lambdaKinds: Array<String>, out: Array<String>
	): Void {
		if (lambdaKinds.contains(node.kind) && node.children.length > 0) {
			final first: QueryNode = node.children[0];
			final name: Null<String> = first.name;
			if (first.kind == identKind && name != null && !out.contains(name)) out.push(name);
		}
		for (child in node.children) collectBareLambdaParamNames(child, identKind, lambdaKinds, out);
	}

	/** Whether `target` (a constructor assignment's left-hand side) writes the field at `fieldFrom`. */
	private static function ctorTargetIsField(
		target: QueryNode, fieldFrom: Int, fieldName: String, container: QueryNode, shape: RefShape
	): Bool {
		final identKind: String = shape.identKind;
		final faKind: Null<String> = shape.fieldAccessKind;
		final selfText: Null<String> = shape.selfReferenceText;
		if (faKind != null && target.kind == faKind) {
			final recv: Null<QueryNode> = target.children.length > 0 ? target.children[0] : null;
			return target.name == fieldName && recv != null && recv.kind == identKind && selfText != null && recv.name == selfText;
		}
		if (target.kind != identKind) return false;
		final name: Null<String> = target.name;
		final span: Null<Span> = target.span;
		return name != null && span != null && TypeResolver.resolveBindingFrom(name, span, container, shape) == fieldFrom;
	}

	/**
	 * Collect every assignment to the field declared at `fieldFrom` under `fieldName` in `node`'s
	 * subtree, each tagged with whether a closure host encloses it. The walk descends INTO closures
	 * on purpose: a closure write must be COUNTED (else a second writer hides and the caller
	 * concludes "sole assignment") even though the caller then refuses it.
	 */
	private static function collectCtorFieldWrites(
		node: QueryNode, fieldFrom: Int, fieldName: String, container: QueryNode, shape: RefShape, assignKind: String,
		closures: Array<String>, inClosure: Bool, out: Array<{ assign: QueryNode, inClosure: Bool }>
	): Void {
		final enclosed: Bool = inClosure || closures.contains(node.kind);
		if (
			node.kind == assignKind && node.children.length >= 2
			&& ctorTargetIsField(node.children[0], fieldFrom, fieldName, container, shape)
		) out.push({
			assign: node,
			inClosure: enclosed
		});
		for (child in node.children)
			collectCtorFieldWrites(child, fieldFrom, fieldName, container, shape, assignKind, closures, enclosed, out);
	}

	/** The kinds that host a deferred body — a lambda, a local `function`, a local `inline function`. */
	private static function closureHostKinds(shape: RefShape): Array<String> {
		return (shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
	}

	/**
	 * The node kinds through which evaluation of a child operand is UNCONDITIONAL — the whitelist
	 * `ctorWriteUnconditional` walks. Every entry comes from its own `RefShape` seam, so an unset
	 * seam simply contributes nothing.
	 */
	private static function unconditionalOperandKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = [];
		inline function admit(kind: Null<String>): Void if (kind != null && !kinds.contains(kind)) kinds.push(kind);
		admit(shape.exprStatementKind);
		admit(shape.parenKind);
		admit(shape.callKind);
		admit(shape.newExprKind);
		admit(shape.arrayLiteralKind);
		admit(shape.objectLiteralKind);
		admit(shape.objectFieldKind);
		admit(shape.assignKind);
		for (kind in shape.localDeclKinds ?? []) admit(kind);
		return kinds;
	}

	/** Whether `writeFrom` is reachable from `node` through `transparent` kinds only. */
	private static function reachesThroughOperands(node: QueryNode, writeFrom: Int, transparent: Array<String>): Bool {
		final span: Null<Span> = node.span;
		if (span == null) return false;
		if (span.from == writeFrom) return true;
		if (!transparent.contains(node.kind)) return false;
		for (child in node.children) if (reachesThroughOperands(child, writeFrom, transparent)) return true;
		return false;
	}

	/** Recursively find the class-like container whose direct field member starts at `fieldFrom`. */
	private static function findFieldContainer(
		node: QueryNode, fieldFrom: Int, classLike: Array<String>, fields: Array<String>
	): Null<{ container: QueryNode, field: QueryNode }> {
		// Every member host of the container, not just its direct children: a field written inside a
		// member-position `#if` sits one level down, and reading it as absent left the fix side unable
		// to re-find a field its own detection had flagged.
		if (classLike.contains(node.kind)) {
			var found: Null<QueryNode> = null;
			eachMemberHost(node, host -> {
				for (child in host.children) if (fields.contains(child.kind)) {
					final sp: Null<Span> = child.span;
					if (sp != null && sp.from == fieldFrom) found = child;
				}
			});
			final field: Null<QueryNode> = found;
			if (field != null) return { container: node, field: field };
		}
		for (child in node.children) {
			final hit: Null<{ container: QueryNode, field: QueryNode }> = findFieldContainer(child, fieldFrom, classLike, fields);
			if (hit != null) return hit;
		}
		return null;
	}

	/**
	 * Whether a word-bounded occurrence of `name` outside `exclude` is the receiver of a
	 * method call — followed, past whitespace and comments, by `.`, then an identifier,
	 * then `(`. Matches `name.m(...)` and `this.name.m(...)` alike (the `name` token in
	 * `this.name` is bounded by the preceding `.`). A plain field read (`name.x`) or a
	 * method reference without a call (`name.m`) is not a match — only a `this`-mutating
	 * abstract method call is a write the assignment scans miss.
	 */
	private static function methodCalledOn(source: String, name: String, exclude: Span): Bool {
		final n: Int = source.length;
		final len: Int = name.length;
		if (len == 0) return false;
		var from: Int = 0;
		while (true) {
			final idx: Int = source.indexOf(name, from);
			if (idx < 0) return false;
			from = idx + len;
			final boundedBefore: Bool = idx == 0 || !isIdentChar(source.fastCodeAt(idx - 1));
			final boundedAfter: Bool = from >= n || !isIdentChar(source.fastCodeAt(from));
			if (boundedBefore && boundedAfter && (idx < exclude.from || idx >= exclude.to) && callFollows(source, from)) return true;
		}
	}

	/** Whether the tokens starting at `pos` are `.` <identifier> ... `(` — a method call, ignoring interposed whitespace and comments. */
	private static function callFollows(source: String, pos: Int): Bool {
		final n: Int = source.length;
		var i: Int = skipForwardTrivia(source, pos);
		if (i >= n || source.fastCodeAt(i) != '.'.code) return false;
		i = skipForwardTrivia(source, i + 1);
		if (i >= n || !isIdentStartChar(source.fastCodeAt(i))) return false;
		while (i < n && isIdentChar(source.fastCodeAt(i))) i++;
		i = skipForwardTrivia(source, i);
		return i < n && source.fastCodeAt(i) == '('.code;
	}

	/**
	 * Extend `span` to also remove ONE separating comma so a comma list stays
	 * well-formed after the element is cut: the trailing comma (preferred) —
	 * the next non-whitespace byte after `span.to` — else the leading comma
	 * before `span.from` (the element was last). A single-element list has
	 * neither and the span is returned unchanged (`[a]` → `[]`). Surrounding
	 * whitespace is left to the writer re-emit.
	 */
	private static function commaExtendedSpan(source: String, span: Span): Span {
		var i: Int = span.to;
		while (i < source.length && isSpace(source.fastCodeAt(i))) i++;
		if (i < source.length && source.fastCodeAt(i) == ','.code) return new Span(span.from, i + 1);

		var j: Int = span.from - 1;
		while (j >= 0 && isSpace(source.fastCodeAt(j))) j--;
		return j >= 0 && source.fastCodeAt(j) == ','.code ? new Span(j, span.to) : span;
	}

	/** True if only whitespace precedes the byte at `from` on its line. */
	private static function isFullLineComment(source: String, from: Int): Bool {
		var i: Int = from - 1;
		while (i >= 0 && source.fastCodeAt(i) != '\n'.code) {
			if (!isSpace(source.fastCodeAt(i))) return false;
			i--;
		}
		return true;
	}

	/**
	 * True if two comment tokens are full-line line comments separated by a
	 * single line break (no blank line, no code) — members of one contiguous
	 * line-comment block.
	 */
	private static function contiguousLineComments(
		source: String, a: { from: Int, to: Int, isLine: Bool }, b: { from: Int, to: Int, isLine: Bool }
	): Bool {
		if (!a.isLine || !b.isLine) return false;
		if (!isFullLineComment(source, a.from) || !isFullLineComment(source, b.from)) return false;
		var newlines: Int = 0;
		for (k in a.to ... b.from) {
			final c: Int = source.fastCodeAt(k);
			if (c == '\n'.code)
				newlines++;
			else if (!isSpace(c))
				return false;
		}
		return newlines == 1;
	}

	/** True when `edits[i]` is contained in another edit (the outer one is kept). */
	private static function isContainedEdit(edits: Array<{ span: Span, text: String }>, i: Int): Bool {
		final e: Span = edits[i].span;
		// A zero-length edit is an INSERT, not a rewrite of existing bytes. The ONE
		// geometry that composes safely through `applyEdits`' right-to-left splice —
		// verified on neko/js/interp — is an insert AT another edit's `.to` (right
		// after a deleted region: the observed prefer-static-extension `using` insert
		// at the boundary of unused-import's delete, which the old unconditional
		// containment test dropped, breaking the check's atomic edit set). The unsafe
		// geometries keep the old drop: strictly INSIDE a span (the splice corrupts —
		// the insert text vanishes and trailing deleted bytes leak back), AT a span's
		// `.from` (splice order diverges across targets), and a same-point tie with an
		// earlier insert (relative order is sort-stability-dependent).
		if (e.from == e.to) {
			for (j in 0...edits.length) if (j != i) {
				final o: Span = edits[j].span;
				if (o.from < o.to && o.from <= e.from && e.from < o.to) return true;
				if (o.from == o.to && o.from == e.from && j < i) return true;
			}
			return false;
		}
		for (j in 0...edits.length) if (j != i) {
			final o: Span = edits[j].span;
			final contains: Bool = o.from <= e.from && e.to <= o.to;
			final strictlyBigger: Bool = o.from < e.from || e.to < o.to;
			if (contains && (strictlyBigger || j < i)) return true;
		}
		return false;
	}

	/**
	 * Skip a comment line-continuation starting at `from` (just past a `\n`): any
	 * further whitespace and blank lines, plus ONE ` * ` doc-marker per line.
	 * Returns the index of the first content character (or `n`).
	 */
	private static function skipContinuation(body: String, from: Int, n: Int): Int {
		var i: Int = from;
		var markerSeen: Bool = false;
		while (i < n) {
			final c: Int = body.fastCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\r'.code) {
				i++;
			} else if (c == '\n'.code) {
				i++;
				markerSeen = false;
			} else if (c == '*'.code && !markerSeen) {
				i++;
				markerSeen = true;
			} else {
				break;
			}
		}
		return i;
	}

	/** Tally, over `node`, every IdentExpr occurrence and every null-comparison ident operand. */
	private static function tallyGuardIdents(
		node: QueryNode, identKind: String, nullKind: String, eqKind: Null<String>, notEqKind: Null<String>, identCount: Map<String, Int>,
		checkCount: Map<String, Int>
	): Void {
		if (node.kind == identKind) {
			final name: Null<String> = node.name;
			if (name != null) bumpCount(identCount, name);
		}
		if ((eqKind != null && node.kind == eqKind) || (notEqKind != null && node.kind == notEqKind)) {
			final ident: Null<String> = nullComparedIdent(node, identKind, nullKind);
			if (ident != null) bumpCount(checkCount, ident);
		}
		for (c in node.children) tallyGuardIdents(c, identKind, nullKind, eqKind, notEqKind, identCount, checkCount);
	}

	/** The identifier compared against null in `node` (one operand an ident, the other null), or null. */
	private static function nullComparedIdent(node: QueryNode, identKind: String, nullKind: String): Null<String> {
		if (node.children.length != 2) return null;
		final a: QueryNode = node.children[0];
		final b: QueryNode = node.children[1];
		return if (a.kind == identKind && b.kind == nullKind)
			a.name
		else if (b.kind == identKind && a.kind == nullKind)
			b.name
		else
			null;
	}

	/** Recursive worker for `eachFieldMember`: visit a container's mutable fields, tracking exported state. */
	private static function walkFieldContainers(node: QueryNode, ctx: FieldMemberCtx): Void {
		if (ctx.containers.contains(node.kind)) {
			final name: Null<String> = node.name;
			// Re-bound to a non-null local: a narrowing does not survive into the closure below.
			if (name != null) {
				final owner: String = name;
				MemberBranchScan.fold(ctx.branch, node.children, false, (exported, child) -> {
					if (ctx.visibility.contains(child.kind)) {
						final span: Null<Span> = child.span;
						return exported || span != null && StringTools.trim(ctx.source.substring(span.from, span.to)) != ctx.defaultVis;
					}
					if (!ctx.members.contains(child.kind)) return exported;
					if (ctx.mutableFields.contains(child.kind)) ctx.visit(owner, child, ctx.source, ctx.file, exported);
					return false;
				}, (a, b) -> a || b);
			}
		}
		for (child in node.children) walkFieldContainers(child, ctx);
	}

	/** Walk back from `from` over own-line line-comments and block-comments (and the whitespace between) to the first code. */
	private static function lastCommentEndingBefore(
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, pos: Int
	): Null<{ from: Int, to: Int, isLine: Bool }> {
		var best: Null<{ from: Int, to: Int, isLine: Bool }> = null;
		for (c in comments) if (c.to <= pos && (best == null || c.to > best.to)) best = c;
		return best;
	}

	/** Extend `to` forward over a line-comment (or same-line block-comment) trailing on the decl's own line. */
	private static function firstCommentStartingAfter(
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, pos: Int
	): Null<{ from: Int, to: Int, isLine: Bool }> {
		var best: Null<{ from: Int, to: Int, isLine: Bool }> = null;
		for (c in comments) if (c.from >= pos && (best == null || c.from < best.from)) best = c;
		return best;
	}

	/** Index of the first character of the line containing `i` (just past the preceding newline). */
	private static function lineStartOf(source: String, i: Int): Int {
		final nl: Int = source.lastIndexOf('\n', i);
		return nl < 0 ? 0 : nl + 1;
	}

	/** Walk `from` back over own-line leading comments (and the whitespace between) to the first code; returns the new start offset. Shared by `memberTriviaSpan` and `leadingCommentBlockStart`. */
	private static function absorbLeadingComments(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, from: Int): Int {
		var result: Int = from;
		while (true) {
			final c: Null<{ from: Int, to: Int, isLine: Bool }> = lastCommentEndingBefore(comments, result);
			if (c == null || source.substring(c.to, result).trim() != '') break;
			final ls: Int = lineStartOf(source, c.from);
			if (source.substring(ls, c.from).trim() != '') break;
			result = ls;
		}
		return result;
	}

	/**
	 * The first `{` and the end of the last non-whitespace token in
	 * `source[from...to)`, both computed with comments and string literals treated
	 * as invisible. `brace` is -1 when the range holds no brace outside them;
	 * `tokenEnd` falls back to `from` when the range is all trivia.
	 */
	private static function headerScan(source: String, from: Int, to: Int): { brace: Int, tokenEnd: Int } {
		final end: Int = to <= source.length ? to : source.length;
		var brace: Int = -1;
		var tokenEnd: Int = from;
		var i: Int = from;
		while (i < end) {
			final c: Int = source.fastCodeAt(i);
			if (c == '/'.code && i + 1 < end) {
				final commentEnd: Int = commentRegionEnd(source, i);
				if (commentEnd >= 0) {
					i = commentEnd;
					continue;
				}
			}
			if (c == '"'.code || c == "'".code) {
				i = skipStringLiteral(source, i, c) + 1;
				tokenEnd = i;
				continue;
			}
			if (c == '{'.code && brace < 0) brace = i;
			if (!isSpace(c)) tokenEnd = i + 1;
			i++;
		}
		return { brace: brace, tokenEnd: tokenEnd };
	}

	/**
	 * Index of the closing `quote` of the string opened at `open`, honouring
	 * `\`-escapes; the source length minus one if unterminated (the caller's `i++`
	 * then ends the scan).
	 */
	private static function skipStringLiteral(text: String, open: Int, quote: Int): Int {
		final n: Int = text.length;
		var i: Int = open + 1;
		while (i < n) {
			final c: Int = text.fastCodeAt(i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			if (c == quote) return i;
			i++;
		}
		return n - 1;
	}

	/**
	 * Single-pass lexer emitting every non-code region (line/block comment, string
	 * literal, regex literal) with byte offsets. Strings are skipped with
	 * `\`-escape handling, regex literals through `scanRegexLiteral`;
	 * `collectCommentTokens` filters this to its comment tokens.
	 *
	 * The regex arm exists because a regex body may legally contain a comment
	 * opener (`~/[\/*]/`), and without it that opener started a phantom block
	 * comment running to EOF - see `scanRegexLiteral` for what that broke.
	 */
	private static function scanLexicalRegions(source: String): Array<LexRegion> {
		final out: Array<LexRegion> = [];
		final n: Int = source.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = source.fastCodeAt(i);
			if (c == '"'.code || c == "'".code) {
				final start: Int = i;
				i = skipStringLiteral(source, i, c) + 1;
				out.push({ from: start, to: i, kind: StringLit });
				continue;
			}
			if (c == '~'.code && i + 1 < n && source.fastCodeAt(i + 1) == '/'.code) {
				final regexEnd: Int = scanRegexLiteral(source, i, n);
				if (regexEnd >= 0) {
					out.push({ from: i, to: regexEnd, kind: RegexLit });
					i = regexEnd;
					continue;
				}
			}
			if (c == '/'.code && i + 1 < n) {
				final next: Int = source.fastCodeAt(i + 1);
				if (next == '/'.code) {
					final start: Int = i;
					i += 2;
					while (i < n && source.fastCodeAt(i) != '\n'.code) i++;
					out.push({ from: start, to: i, kind: LineComment });
					continue;
				}
				if (next == '*'.code) {
					final start: Int = i;
					i += 2;
					var closed: Bool = false;
					while (i + 1 < n) {
						if (source.fastCodeAt(i) == '*'.code && source.fastCodeAt(i + 1) == '/'.code) {
							i += 2;
							closed = true;
							break;
						}
						i++;
					}
					if (!closed) i = n;
					out.push({ from: start, to: i, kind: BlockComment });
					continue;
				}
			}
			i++;
		}
		return out;
	}

	/** Collect the span of every `#if...#end` region node into `out` (recursive). */
	private static function collectConditionalSpans(node: QueryNode, out: Array<Span>): Void {
		if (isConditionalKind(node.kind)) {
			final s: Null<Span> = node.span;
			if (s != null) out.push(s);
		}
		for (child in node.children) collectConditionalSpans(child, out);
	}

	/**
	 * The lexical class of the occurrence at `at`; see `OccurrenceClass`.
	 *
	 * The LEXICAL class is decided first, and a `#if...#end` region only classifies what
	 * is left: `ConditionalRaw` means "code the resolver could not bind", and a comment or
	 * string inside a conditional region is neither - the lexer reads it the same whichever
	 * branch is live. Asking the conditional first made one commented-out line inside a
	 * `#if` block every rename of that name in the whole FILE (the class scans `0...length`),
	 * including bindings whose scope lay nowhere near the region.
	 */
	private static function classifyAt(
		source: String, at: Int, len: Int, condSpans: Array<Span>, regions: Array<LexRegion>
	): OccurrenceClass {
		for (region in regions) if (at >= region.from && at < region.to) return switch region.kind {
			case StringLit:
				literalNamesIdentifier(source, at, len, region) ? StringLiteral : StringWord;
			// A regex body is inert literal text, and no by-name lookup reads one, but nothing needs
			// the relaxation - the conservative reading stays.
			case RegexLit: StringLiteral;
			case LineComment | BlockComment: isNoqaComment(source, region) ? DirectiveComment : CommentTrivia;
		};
		return offsetWithinAny(at, condSpans) ? ConditionalRaw : ActiveCode;
	}

	/**
	 * Whether the occurrence at `[at, at + len)` inside the string `region` NAMES the identifier
	 * rather than merely containing the word. Two shapes qualify:
	 *
	 *  - the occurrence is the literal's ENTIRE content — the form every by-name lookup takes
	 *    (`Reflect.field(o, 'edit')`, a string-keyed field map, a serialized field name);
	 *  - the occurrence is an interpolation READ — preceded by `$` or by `{` that a `$` precedes.
	 *    Checked whatever the quote character is: this scanner is language-neutral and a spurious
	 *    block is the safe direction.
	 *
	 * Everything else — a word inside a sentence, a fragment of a path or a compound key — cannot
	 * address the member and must not veto its rename.
	 */
	private static function literalNamesIdentifier(source: String, at: Int, len: Int, region: LexRegion): Bool {
		if (at == region.from + 1 && at + len == region.to - 1) return true;
		final prev: Int = at - 1;
		if (prev <= region.from) return false;
		final prevCode: Int = source.fastCodeAt(prev);
		return prevCode == '$'.code || prevCode == '{'.code && prev - 1 > region.from && source.fastCodeAt(prev - 1) == '$'.code;
	}

	/**
	 * Whether a comment region carries a `noqa` suppression directive on any of
	 * its lines (`noqa` or `noqa: rules`, case-insensitive — the flake8 form the
	 * `Suppression` check honours). Such a line is machine-meaningful, so the
	 * rename must not rewrite inside it.
	 */
	private static function isNoqaComment(source: String, region: LexRegion): Bool {
		for (raw in source.substring(region.from, region.to).split('\n')) {
			var line: String = StringTools.trim(raw);
			if (line.startsWith('//') || line.startsWith('/*')) line = line.substr(2).trim();
			final lower: String = line.toLowerCase();
			if (lower == 'noqa' || lower.startsWith('noqa:')) return true;
		}
		return false;
	}

	/**
	 * The start offset of the BLOCK comment token whose end is exactly `end`, or -1 when
	 * no such token exists. `tokens` is a `collectCommentTokens` result, i.e. the lexer's
	 * own view: a block comment is ONE token from its opener to the first closer, so an
	 * opener sequence appearing inside the comment's text is content, not a boundary.
	 */
	private static function commentEndingAt(tokens: Array<{ from: Int, to: Int, isLine: Bool }>, end: Int, blockOnly: Bool): Int {
		for (t in tokens) if (t.to == end && !(blockOnly && t.isLine)) return t.from;
		return -1;
	}

	/**
	 * Whether only spaces and tabs separate `at` from the start of its line — the test that tells a declaration's own leading comment from the PREVIOUS declaration's trailing
	 * one. Both end just above the next declaration and are equally adjacent to it; only
	 * the line the comment opens on says whose it is.
	 */
	public static function startsItsLine(source: String, at: Int): Bool {
		var i: Int = at - 1;
		while (i >= 0 && (source.fastCodeAt(i) == ' '.code || source.fastCodeAt(i) == '\t'.code)) i--;
		return i < 0 || source.fastCodeAt(i) == '\n'.code;
	}

	/** Whether the block comment opening at `open` is a `/**` doc rather than a plain block. */
	private static inline function isDocOpener(source: String, open: Int): Bool {
		return open + 2 < source.length && source.fastCodeAt(open + 2) == '*'.code;
	}

	/**
	 * End offset (exclusive) of the Haxe regex literal opened by `~/` at `open`,
	 * flags included; -1 when it is not terminated on its own line. Matches the
	 * compiler's own lexer: the body runs to the first unescaped `/`, and a
	 * comment OPENER inside it is body text - `haxe` lexes a block-comment
	 * opener right after `~/` as part of the regex too, not as `~` applied to a
	 * comment (verified against the compiler).
	 *
	 * Without this arm the shared region scan opened a phantom block comment at
	 * the comment opener hiding in `~/[\/*]/`: unterminated, so every byte to
	 * EOF counted as comment trivia and real code after the literal became
	 * invisible - a cross-file member rename refused the whole scope, and every
	 * consumer of `collectCommentTokens` saw a comment token that is not there.
	 */
	private static function scanRegexLiteral(source: String, open: Int, n: Int): Int {
		final nl: Int = source.indexOf('\n', open + 2);
		final lineEnd: Int = nl < 0 ? n : nl;
		var i: Int = open + 2;
		while (i < lineEnd) {
			final c: Int = source.fastCodeAt(i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			if (c == '/'.code) {
				i++;
				while (i < lineEnd && isRegexFlag(source.fastCodeAt(i))) i++;
				return i;
			}
			i++;
		}
		return -1;
	}

	/** Walk `node`, appending the name-token span of every direct child of a `hosts` node. */
	private static function collectStructureFieldNames(node: QueryNode, source: String, hosts: Array<String>, out: Array<Span>): Void {
		if (hosts.contains(node.kind)) for (field in node.children) {
			final name: Null<String> = field.name;
			final span: Null<Span> = field.span;
			if (name == null || span == null) continue;
			final at: Int = identTokenOffset(source, span, name);
			if (at >= 0) out.push(new Span(at, at + name.length));
		}
		for (child in node.children) collectStructureFieldNames(child, source, hosts, out);
	}

	/**
	 * Whether the string literal containing `at` can interpolate: single-quoted and
	 * carrying a `$` that is not the escaped `$$`. Decided per LITERAL rather than
	 * per occurrence - working out which `${...}` region an occurrence falls in
	 * costs another scan, and the coarse answer only ever vetoes a rename. A
	 * double-quoted literal never interpolates in Haxe, so it is always inert.
	 */
	private static function interpolatingLiteralAt(source: String, at: Int, regions: Array<LexRegion>): Bool {
		for (region in regions) {
			if (region.kind != StringLit || at < region.from || at >= region.to) continue;
			if (source.fastCodeAt(region.from) != "'".code) return false;
			var i: Int = region.from + 1;
			while (i < region.to) {
				if (source.fastCodeAt(i) != '$'.code) {
					i++;
					continue;
				}
				if (i + 1 >= region.to || source.fastCodeAt(i + 1) != '$'.code) return true;
				i += 2;
			}
			return false;
		}
		return false;
	}

	/**
	 * Whether the identifier at `at` sits in the member-name slot of a dotted access
	 * (`o.name`, `o?.name`, `Type.name`) - never a binding of `name` in the
	 * surrounding scope. The range operator is excluded: in `0...name` the name is a
	 * real read. Only whitespace is stepped over, so a comment between the dot and
	 * the name answers false and vetoes - the safe side.
	 */
	private static function isMemberNamePosition(source: String, at: Int): Bool {
		var i: Int = at - 1;
		while (i >= 0 && isSpace(source.fastCodeAt(i))) i--;
		return i >= 0 && source.fastCodeAt(i) == '.'.code && (i <= 0 || source.fastCodeAt(i - 1) != '.'.code) && !onImportLine(source, at);
	}

	/**
	 * Whether `at` sits on a line whose first token is `import` or `using`. The last
	 * segment of such a path DOES bind a name in the file's scope, so it is the one
	 * dotted position `isMemberNamePosition` must not wave through - a rename onto it
	 * would shadow the imported type. Line-based on purpose: the region scan the
	 * caller already holds says nothing about statement kind, and an `import` never
	 * shares its line with other code.
	 */
	private static function onImportLine(source: String, at: Int): Bool {
		final head: String = source.substring(lineStartOf(source, at), at).ltrim();
		return head.startsWith('import ') || head.startsWith('using ');
	}

	/**
	 * The declaration head just past the field NAME: `end` is where the type annotation
	 * (or the `=`) begins, and `dropped` the span of a `(default, null)` property head to
	 * delete — null for a plain `var`. Returns null when the head cannot be read, or
	 * carries any OTHER accessor pair, whose access `final` does not reproduce.
	 */
	private static function declHeadAfterName(source: String, declSpan: Span): Null<{ dropped: Null<Span>, end: Int }> {
		final limit: Int = declSpan.to;
		var i: Int = declSpan.from + 'var'.length;
		while (i < limit && isSpace(source.fastCodeAt(i))) i++;
		final nameStart: Int = i;
		while (i < limit && isIdentChar(source.fastCodeAt(i))) i++;
		if (i == nameStart) return null;
		final nameEnd: Int = i;
		while (i < limit && isSpace(source.fastCodeAt(i))) i++;
		if (i >= limit || source.fastCodeAt(i) != '('.code) return { dropped: null, end: nameEnd };
		final close: Int = source.indexOf(')', i);
		if (close < 0 || close >= limit) return null;
		final accessors: Array<String> = [for (a in source.substring(i + 1, close).split(',')) StringTools.trim(a)];
		return accessors.length != 2 || accessors[0] != 'default' || accessors[1] != 'null' ? null : {
			dropped: new Span(nameEnd, close + 1),
			end: close + 1
		};
	}

	/**
	 * The declaration's initializer expression node, or null when the field has none.
	 * The LAST child is the initializer unless it is a type annotation
	 * (`typeAnnotationKinds`) — an anonymous structure type projects as a child of the
	 * declaration too.
	 */
	private static function declInitializer(field: QueryNode, shape: RefShape): Null<QueryNode> {
		final typeKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		if (field.children.length == 0) return null;
		final last: QueryNode = field.children[field.children.length - 1];
		return typeKinds.contains(last.kind) ? null : last;
	}

	/**
	 * The span to delete so the declaration keeps its type but loses ` = <default>`:
	 * from the whitespace before the `=` through the end of the default expression.
	 * Null when the bytes between head and default are not exactly whitespace + `=` (a
	 * comment there would be silently dropped), or when anything but the statement
	 * terminator follows the default.
	 */
	private static function initializerDropSpan(source: String, declSpan: Span, initSpan: Span, headEnd: Int): Null<Span> {
		final tail: String = source.substring(initSpan.to, declSpan.to).trim();
		if (tail != ';' && tail != '') return null;
		var i: Int = initSpan.from - 1;
		while (i >= headEnd && isSpace(source.fastCodeAt(i))) i--;
		if (i < headEnd || source.fastCodeAt(i) != '='.code) return null;
		var start: Int = i - 1;
		while (start >= headEnd && isSpace(source.fastCodeAt(start))) start--;
		return start < headEnd ? null : new Span(start + 1, initSpan.to);
	}

	/**
	 * Whether the declaration default `node` can be MOVED into constructor position
	 * unchanged. A positive whitelist, not a list of rejected shapes: a numeric or
	 * boolean literal, a plain string literal, a negated numeric literal, or a dotted
	 * constant chain (`constantChain`). Everything else — an allocation, a call, a bare
	 * identifier, `this` — fails by construction. A string qualifies only when it carries
	 * no interpolation at all: `containsInterpolation` catches the shorthand `$name` form,
	 * and the childless-fragments test catches the `${expr}` form, whose hole projects as
	 * a nested expression node rather than an interpolation kind.
	 */
	private static function defaultIsMoveSafe(source: String, node: QueryNode, shape: RefShape): Bool {
		final numeric: Array<String> = shape.numericLiteralKinds ?? [];
		if (numeric.contains(node.kind)) return true;
		if (node.kind == shape.boolLitKind) return true;
		return if ((shape.stringLiteralKinds ?? []).contains(node.kind))
			!containsInterpolation(node, shape) && node.children.foreach(c -> c.children.length == 0)
		else if (node.kind == shape.negationKind)
			node.children.length == 1 && numeric.contains(node.children[0].kind)
		else
			node.kind == shape.fieldAccessKind && constantChain(source, node, shape);
	}

	/** Whether `node`'s subtree carries a string-interpolation hole, which reads surrounding bindings. */
	private static function containsInterpolation(node: QueryNode, shape: RefShape): Bool {
		if (node.kind == shape.stringInterpIdentKind || (shape.interpolationKinds ?? []).contains(node.kind)) return true;
		for (child in node.children) if (containsInterpolation(child, shape)) return true;
		return false;
	}

	/**
	 * Whether `node` is a dotted access rooted at a CAPITALISED identifier — a
	 * type-qualified constant or enum value (`Defaults.MODE`, `Direction.LEFT`), the one
	 * non-literal default safe to evaluate later. A lower-case root could be an instance
	 * field, unset at constructor position. Every segment name must also be unwritten in
	 * the file, so the value cannot change between the declaration and the constructor.
	 */
	private static function constantChain(source: String, node: QueryNode, shape: RefShape): Bool {
		final segments: Array<String> = [];
		var current: QueryNode = node;
		while (current.kind == shape.fieldAccessKind) {
			final segment: Null<String> = current.name;
			if (segment == null || current.children.length != 1) return false;
			segments.push(segment);
			current = current.children[0];
		}
		final root: Null<String> = current.name;
		if (current.kind != shape.identKind || root == null || root.length == 0 || root == shape.selfReferenceText) return false;
		final head: String = root.charAt(0);
		if (head == head.toLowerCase()) return false;
		segments.push(root);
		for (segment in segments) if (MemberWriteScan.writtenInRange(source, segment, null, 0, source.length)) return false;
		return true;
	}

	/**
	 * The ONE top-level `if (<param> != null) <field> = <param>;` constructor statement
	 * writing `field`, or null when the constructor holds none, more than one, or one
	 * whose shape differs in any way. A statement that writes the field through some
	 * OTHER shape is not matched here — the caller's whole-file write scan rejects it.
	 */
	private static function soleGuardedCtorFieldInit(
		source: String, container: QueryNode, ctor: QueryNode, field: QueryNode, shape: RefShape
	): Null<GuardedCtorInit> {
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final fieldSpan: Null<Span> = field.span;
		final fieldName: Null<String> = field.name;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == shape.blockBodyKind);
		if (fieldSpan == null || fieldName == null || body == null) return null;
		var match: Null<GuardedCtorInit> = null;
		for (stmt in body.children) if (ifKinds.contains(stmt.kind)) {
			final found: Null<GuardedCtorInit> = guardedFieldAssign(source, stmt, fieldSpan.from, fieldName, container, shape);
			if (found == null) continue;
			if (match != null) return null;
			match = found;
		}
		return match;
	}

	/**
	 * `stmt` read as `if (<param> != null) <field> = <param>;` — the guard must be a bare
	 * `!= null` test of the very identifier assigned, the branch a single assignment
	 * statement (braced or not), and there must be no `else`. `terminator` carries the
	 * bytes the assignment ends with, so the rewritten statement keeps them verbatim.
	 */
	private static function guardedFieldAssign(
		source: String, stmt: QueryNode, fieldFrom: Int, fieldName: String, container: QueryNode, shape: RefShape
	): Null<GuardedCtorInit> {
		final stmtSpan: Null<Span> = stmt.span;
		final param: Null<String> = nullGuardParamName(stmt, shape);
		final branch: Null<QueryNode> = guardedSoleStatement(stmt, shape);
		if (stmtSpan == null || param == null || branch == null) return null;
		final branchSpan: Null<Span> = branch.span;
		if (branch.kind != shape.exprStatementKind || branch.children.length != 1 || branchSpan == null) return null;
		final assign: QueryNode = branch.children[0];
		final assignSpan: Null<Span> = assign.span;
		if (assign.kind != shape.assignKind || assign.children.length != 2 || assignSpan == null) return null;
		final target: QueryNode = assign.children[0];
		final targetSpan: Null<Span> = target.span;
		final value: QueryNode = assign.children[1];
		return if (targetSpan == null || value.kind != shape.identKind || value.name != param)
			null
		else if (!statementCommentFree(source, stmtSpan, targetSpan))
			null
		else if (!ctorTargetIsField(target, fieldFrom, fieldName, container, shape))
			null
		else
			{
				stmt: stmtSpan,
				target: targetSpan,
				param: param,
				terminator: source.substring(assignSpan.to, branchSpan.to)
			};
	}

	/**
	 * Whether the constructor parameter `paramName` is nullable — declared optional
	 * (`?p:T`), wrapped in a nullable type (`Null<T>`), or defaulted to `null`. A
	 * non-nullable parameter's `!= null` guard is vestigial and `p ?? d` would not fold
	 * the same way, so the rewrite refuses it.
	 */
	private static function ctorParamIsNullable(source: String, ctor: QueryNode, paramName: String, shape: RefShape): Bool {
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final wrappers: Array<String> = shape.nullableWrapperTypeNames ?? [];
		for (child in ctor.children) if (paramKinds.contains(child.kind) && child.name == paramName) {
			if (child.kind == shape.optionalParamKind) return true;
			if (child.children.exists(c -> c.kind == shape.nullLiteralKind)) return true;
			final span: Null<Span> = child.span;
			if (span == null) return false;
			final text: String = source.substring(span.from, span.to);
			final colon: Int = text.indexOf(':');
			if (colon < 0) return false;
			final declared: String = text.substring(colon + 1).trim();
			for (wrapper in wrappers) if (declared == wrapper || declared.startsWith('$wrapper<')) return true;
			return false;
		}
		return false;
	}

	/**
	 * The declaration geometry `ctorConditionalDefaultFinalEdits` needs, or null when the
	 * declaration cannot host the fold: it must be a NON-STATIC field whose head is plain
	 * or exactly `(default, null)`, carrying a MOVE-SAFE initializer reachable by a bare
	 * ` = ` (a comment between head and default, or anything but a terminator after it,
	 * bails). `dropped` is the property head to delete, `initDrop` the ` = <default>`
	 * region, `initSpan` the default expression the constructor assignment inherits.
	 */
	private static function foldableDeclaration(
		source: String, loc: { container: QueryNode, field: QueryNode }, declSpan: Span, shape: RefShape
	): Null<FoldableDecl> {
		final field: QueryNode = loc.field;
		final name: Null<String> = field.name;
		final fieldSpan: Null<Span> = field.span;
		if (name == null || fieldSpan == null) return null;
		if (fieldSpan.from != declSpan.from) return null;
		if (staticMemberFroms(loc.container, shape).contains(fieldSpan.from)) return null;
		final head: Null<{ dropped: Null<Span>, end: Int }> = declHeadAfterName(source, fieldSpan);
		final init: Null<QueryNode> = declInitializer(field, shape);
		final initSpan: Null<Span> = init?.span;
		if (head == null || init == null || initSpan == null) return null;
		if (initSpan.from < head.end || !defaultIsMoveSafe(source, init, shape)) return null;
		final initDrop: Null<Span> = initializerDropSpan(source, fieldSpan, initSpan, head.end);
		return initDrop == null ? null : {
			name: name,
			span: fieldSpan,
			dropped: head.dropped,
			initSpan: initSpan,
			initDrop: initDrop
		};
	}

	/**
	 * Whether the constructor reaches the guarded statement with the field still in the
	 * state the declaration default put it in. A declaration initializer runs at
	 * constructor ENTRY on EVERY path, so moving it down to the guard's position is
	 * behaviour-preserving only when nothing before the guard can leave the constructor
	 * (the field would then never be assigned at all — Haxe's definite-assignment check
	 * for a `final` field is not flow-sensitive, so that compiles) and nothing before the
	 * guard mentions the field (a read there sees the default today and an unset field
	 * after the fold). Both scans are deliberately coarse: a `return` inside a lambda, or
	 * the field name in a comment or an unrelated local, refuses the candidate.
	 *
	 * Residual: a read reached through a helper CALLED from the constructor before the
	 * guard is invisible here, the same blind spot `field-init-at-declaration` carries for
	 * the inverse move.
	 */
	private static function guardReachedIntact(source: String, ctor: QueryNode, name: String, guardFrom: Int, shape: RefShape): Bool {
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == shape.blockBodyKind);
		final bodySpan: Null<Span> = body?.span;
		final exitKinds: Array<String> = shape.controlExitKinds ?? [];
		// An unset exit-kind set would turn the scan below into a no-op and silently accept
		// every early return, so its completeness is load-bearing here — refuse without it.
		return body != null && bodySpan != null && exitKinds.length != 0 && !referencedInRange(source, name, bodySpan.from, guardFrom, [])
			&& !kindStartsBefore(body, exitKinds, guardFrom);
	}

	/** Whether `node`'s subtree holds a node of one of `kinds` that STARTS before `boundary`. */
	private static function kindStartsBefore(node: QueryNode, kinds: Array<String>, boundary: Int): Bool {
		final span: Null<Span> = node.span;
		// Spans are monotone, so a subtree starting past the boundary holds no match.
		if (span != null && span.from >= boundary) return false;
		if (span != null && kinds.contains(node.kind)) return true;
		for (child in node.children) if (kindStartsBefore(child, kinds, boundary)) return true;
		return false;
	}

	/**
	 * Whether the guarded statement carries no comment the rewrite would drop. Only the
	 * assignment TARGET is copied verbatim; every other byte of the statement — the guard,
	 * the braces, the operator, the assigned value — is regenerated, so a comment outside
	 * the target's span disappears silently. Checking around the target rather than around
	 * the whole assignment is what makes this the same fail-closed rule the declaration
	 * side applies in `initializerDropSpan`. No false positive is possible: by the time
	 * this runs the condition is proven to be exactly `<ident> != null` and the tail is the
	 * statement terminator, so no string literal can occupy either region.
	 */
	private static function statementCommentFree(source: String, stmt: Span, target: Span): Bool {
		return !hasCommentMarker(source, stmt.from, target.from) && !hasCommentMarker(source, target.to, stmt.to);
	}

	/**
	 * The parameter name of a bare `<name> != null` guard on `stmt`, or null when the
	 * condition has any other shape or an `else` branch follows (a second assignment path
	 * the `??` rewrite cannot express).
	 */
	private static function nullGuardParamName(stmt: QueryNode, shape: RefShape): Null<String> {
		if (stmt.children.length != 2) return null;
		final cond: QueryNode = stmt.children[0];
		if (cond.kind != shape.notEqKind || cond.children.length != 2 || cond.children[1].kind != shape.nullLiteralKind) return null;
		final guard: QueryNode = cond.children[0];
		return guard.kind == shape.identKind ? guard.name : null;
	}

	/**
	 * `stmt`'s then-branch reduced to its SOLE statement, unwrapping one brace level, or
	 * null when the branch holds anything but exactly one statement.
	 */
	private static function guardedSoleStatement(stmt: QueryNode, shape: RefShape): Null<QueryNode> {
		if (stmt.children.length != 2) return null;
		final branch: QueryNode = stmt.children[1];
		return if (branch.kind != shape.blockStmtKind)
			branch
		else if (branch.children.length == 1)
			branch.children[0]
		else
			null;
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


	/**
	 * Remove EVERY node in `targets` from `source` in one canonicalisation — the multi-node
	 * form of `deleteNode`, which is this with a single target.
	 *
	 * One call rather than a fold of single deletions because each `deleteNode` returns
	 * REWRITTEN source: the second call would have to re-parse it and re-resolve its target,
	 * and the writer may by then have moved the very span the caller measured. Collecting the
	 * spans against ONE tree and handing them to `canonicalize` together keeps every span in
	 * the coordinate system it was computed in.
	 *
	 * That is also why OVERLAP is refused rather than tolerated. `applyEdits` splices each span
	 * independently, so a target nested inside another (a member and the region holding it, or
	 * two nested regions) makes the second splice run on coordinates the first already shifted —
	 * it deletes unrelated code, and the re-parse does not catch it because the wreckage usually
	 * still parses. A caller that means to remove a node and its container passes the CONTAINER
	 * alone. Spans widened to their line can also collide between neighbours that share a
	 * line, which the same check catches.
	 *
	 * Each cut is widened once more, over ONE flanking blank line, so the deletion gives
	 * back the separator the declaration owned (`blankExtendedSpan`). Two targets
	 * separated by exactly one blank line then produce TOUCHING spans rather than
	 * overlapping ones — the earlier cut ends where the later one begins — so a run of
	 * adjacent declarations closes to a single blank however many of them one call
	 * removes, and the disjointness check above still passes.
	 */
	public static function deleteNodes(
		source: String, targets: Array<{ node: QueryNode, parent: Null<QueryNode> }>, reformat: Bool, plugin: GrammarPlugin,
		withDoc: Bool = true, ?optsJson: String
	): EditResult {
		if (targets.length == 0) return Err('no node to remove');
		final edits: Array<{ span: Span, text: String }> = [];
		for (target in targets) {
			final nodeSpan: Null<Span> = target.node.span;
			if (nodeSpan == null) return Err('the node to remove has no source span');
			final group: Span = trailingTrimmedSpan(source, declGroupSpan(target.node, target.parent, nodeSpan));
			// A declaration's doc comment is trivia OUTSIDE its node span, so the group span
			// stops short of it and the block is left in the file — where it silently becomes
			// the documentation of whatever declaration follows. Removing it WITH the node is
			// therefore the default; `withDoc = false` is the deliberate opt-out for a caller
			// that keeps the comment on purpose. The line/comma extension then runs on top.
			final span: Span = withDoc ? docExtendedSpan(source, group, true) : group;

			var isComma: Bool = adjacentToComma(source, span);
			final parent: Null<QueryNode> = target.parent;
			if (!isComma && parent != null) isComma = COMMA_CONTAINER_KINDS.contains(parent.kind);

			// A comma list has no blank separators, so only the line branch gives one back.
			final cut: Span = isComma ? commaExtendedSpan(source, span) : blankExtendedSpan(source, lineExtendedSpan(source, span));
			edits.push({ span: cut, text: '' });
		}
		// A target nested in another — a member and the region holding it, two nested regions — is
		// dropped in favour of the outer one, which removes it anyway. `isContainedEdit` is the same
		// containment test `lint --fix` uses to keep an edit set atomic, and it already carries which
		// geometries survive `applyEdits`' right-to-left splice.
		final kept: Array<{ span: Span, text: String }> = [for (i => edit in edits) if (!isContainedEdit(edits, i)) edit];
		final ordered: Array<{ span: Span, text: String }> = kept.copy();
		ordered.sort((a, b) -> a.span.from - b.span.from);
		// What is left must be disjoint. Node spans never partially overlap, but a span widened to
		// its whole line does when two targets share a line — splicing those would delete the shared
		// text twice over and take the survivor with it.
		for (i in 1...ordered.length) if (ordered[i].span.from < ordered[i - 1].span.to)
			return Err('the nodes to remove share a line — removing them together would delete more than the two');
		return canonicalize(source, kept, reformat, plugin, optsJson);
	}


	/**
	 * Every identifier a `case` pattern in `tree` BINDS — the pattern wrapper is a case
	 * branch's first child. Sibling case-branch captures flatten into ONE scope frame, so a
	 * member sharing a capture's name can be mis-attributed by the resolver; the member
	 * operations refuse a rename or a move when the member name is in this set.
	 *
	 * An identifier the LANGUAGE cannot bind as a pattern variable is left out: it is a
	 * reference to a constant, and counting it as a capture refused every rename of an
	 * `enum abstract` value that its own type spells in a `switch`. Governed by
	 * `RefShape.upperInitialNeverCaptures`; unset keeps every pattern identifier.
	 */
	public static function casePatternCaptures(tree: QueryNode, shape: RefShape): Array<String> {
		final out: Array<String> = [];
		final identKind: String = shape.identKind;
		final caseBranchKind: Null<String> = shape.caseBranchKind;
		if (caseBranchKind == null) return out;
		final skipUpperInitial: Bool = shape.upperInitialNeverCaptures == true;
		function walkPattern(node: QueryNode): Void {
			final name: Null<String> = node.name;
			if (node.kind == identKind && name != null && !(skipUpperInitial && isUpperInitial(name)) && !out.contains(name))
				out.push(name);
			for (c in node.children) walkPattern(c);
		}
		function walk(node: QueryNode): Void {
			if (node.kind == caseBranchKind && node.children.length > 0) walkPattern(node.children[0]);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

}

/**
 * What `RefactorSupport.eachFieldMember`'s container walk threads through every frame — the
 * kind-sets it matches on, the branch seams its member fold descends `#if` regions with, and the
 * visitor. Resolved once per file.
 */
private typedef FieldMemberCtx = {
	final source: String;
	final file: String;
	final containers: Array<String>;
	final members: Array<String>;
	final mutableFields: Array<String>;
	final visibility: Array<String>;
	final defaultVis: String;
	final branch: MemberBranchSeams;
	final visit: (owner:String, field:QueryNode, source:String, file:String, exported:Bool) -> Void;
};
