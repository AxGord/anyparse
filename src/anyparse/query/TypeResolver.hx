package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefHit;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Minimal type-aware purity resolution for the analysis layer. Recovers a
 * `recv.field` receiver's declared type — via a `TypeInfoProvider`'s
 * decl-span→type-name map + the `SymbolIndex` — to decide whether the field
 * read is provably side-effect-free.
 *
 * MVP scope (getter-purity for `unused-local`): only an **anonymous-struct**
 * receiver is resolved — its fields can never be property getters, so the read
 * has no side effect. Every other receiver (`this`, a class/abstract value, an
 * un-annotated or parametric local, a complex expression) returns `false` —
 * the caller keeps its conservative default. The result is therefore strictly
 * additive: it can only newly classify a read as safe, never wrongly.
 */
@:nullSafety(Strict)
final class TypeResolver {

	/**
	 * Simple `Type.method` names of stdlib STATIC functions that are provably
	 * side-effect-free — a discarded call to one cannot change observable
	 * behaviour, so `unused-local`'s autofix may delete a dead binding whose
	 * initializer is such a call. Explicitly enumerated (not "every method
	 * except"), so a future impure addition is never auto-trusted. `Math.random`
	 * / `Std.random` are deliberately ABSENT — they advance PRNG state (a side
	 * effect); every I/O-bearing type (`Sys`, `File`, ...) is out entirely.
	 *
	 * PURITY is NOT derivable from a declaration — a signature never states
	 * side-effect freedom — so, unlike the extension-method and static-return
	 * tables now derived from the std sources via `StdResolver`, this list is
	 * intrinsic semantic knowledge and stays hand-maintained.
	 */
	private static final PURE_STDLIB_STATIC_FUNCS: Array<String> = [
		'Date.now',
		'Date.fromTime',
		'Date.fromString',
		'Std.string',
		'Std.int',
		'Std.parseInt',
		'Std.parseFloat',
		'Std.isOfType',
		'Std.downcast',
		'Math.abs',
		'Math.min',
		'Math.max',
		'Math.floor',
		'Math.ceil',
		'Math.round',
		'Math.fround',
		'Math.ffloor',
		'Math.fceil',
		'Math.sqrt',
		'Math.pow',
		'Math.sin',
		'Math.cos',
		'Math.tan',
		'Math.asin',
		'Math.acos',
		'Math.atan',
		'Math.atan2',
		'Math.exp',
		'Math.log',
		'Math.isNaN',
		'Math.isFinite',
		'StringTools.trim',
		'StringTools.ltrim',
		'StringTools.rtrim',
		'StringTools.lpad',
		'StringTools.rpad',
		'StringTools.replace',
		'StringTools.startsWith',
		'StringTools.endsWith',
		'StringTools.contains',
		'StringTools.isSpace',
		'StringTools.hex',
		'StringTools.urlEncode',
		'StringTools.urlDecode',
		'StringTools.htmlEscape',
		'StringTools.htmlUnescape',
		'StringTools.fastCodeAt',
		'StringTools.isEof',
		'Path.join',
		'Path.directory',
		'Path.extension',
		'Path.withoutExtension',
		'Path.withoutDirectory',
		'Path.normalize',
		'Path.addTrailingSlash',
		'Path.removeTrailingSlash',
		'Path.isAbsolute'
	];

	/**
	 * The innermost type declaration whose span contains `faSpan` — the whole match, for a consumer
	 * that needs the declaration's KIND or its node rather than the name `enclosingTypeName` answers
	 * with: what a bare `this` denotes at a position depends on which kind of type hosts it.
	 */
	public static inline function enclosingTypeDecl(tree: QueryNode, faSpan: Span): Null<TypeDeclMatch> {
		return innermostTypeDecl(tree, faSpan);
	}

	/**
	 * True when `faNode` (a field-access node) is a provably side-effect-free read.
	 * Three resolved receivers: an anonymous-struct value (fields can't be getters);
	 * a local/param of a class/abstract type whose member `field` is a plain member;
	 * and `this`, against the enclosing type's members. In the latter two the member
	 * may be DECLARED by the resolved type or INHERITED from a project-resolvable
	 * supertype — `MemberLookup.memberGetter` walks the chain. Any unresolved receiver,
	 * a getter property, or a field whose accessor shape the index cannot prove plain
	 * returns false — the caller keeps its conservative default.
	 */
	public static function isPlainFieldRead(
		faNode: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: SymbolIndex
	): Bool {
		if (faNode.children.length != 1) return false;
		final field: Null<String> = faNode.name;
		if (field == null) return false;
		final recv: QueryNode = faNode.children[0];
		final identKind: Null<String> = shape.identKind;
		if (identKind == null || recv.kind != identKind) return false;
		final recvName: Null<String> = recv.name;
		final recvSpan: Null<Span> = recv.span;
		if (recvName == null || recvSpan == null) return false;
		if (recvName == shape.selfReferenceText) {
			final lookSpan: Span = faNode.span ?? recvSpan;
			final enclosing: Null<String> = enclosingTypeName(tree, lookSpan);
			return enclosing != null && index.members.memberGetter(enclosing, field) == false;
		}
		final bindingFrom: Null<Int> = resolveBindingFrom(recvName, recvSpan, tree, shape);
		if (bindingFrom == null) return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		return typeName != null && (index.structural.isAnonStructType(typeName) || index.members.memberGetter(typeName, field) == false);
	}

	/**
	 * Whether `node` is safe to DELETE when its bound value is unused — the
	 * analysis-layer delete-fix's purity test, a strict superset of
	 * `RefactorSupport.isSideEffectFree`. It must stay SEPARATE from that shared
	 * predicate: `Inline` reuses `isSideEffectFree` to DUPLICATE an initializer
	 * across every read, where an array / object literal's identity matters, so
	 * widening the shared kind-set would corrupt inlining. Shapes the base
	 * predicate conservatively rejects are added here: an array literal whose
	 * elements are each deletion-pure, a plain (non-getter) field read
	 * (`isPlainFieldRead`), a provably-pure stdlib static call
	 * (`isPureStdlibCall`), and two TRANSPARENT single-child wrappers — a
	 * parenthesized expression (`shape.parenKind`) and the UNCHECKED cast
	 * `cast expr` (`shape.uncheckedCastKind`) — each pure iff its one child is.
	 * The runtime-CHECKED `cast(expr, T)` (`shape.checkedCastKind`) is
	 * deliberately NOT a wrapper here: it performs a runtime type test and can
	 * THROW on a mismatch, so discarding it is an observable behaviour change —
	 * it falls through to the conservative default. Any other node keeps that
	 * base conservative answer.
	 */
	public static function isDeletionPure(
		node: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: SymbolIndex
	): Bool {
		if (MemberKinds.isSideEffectFree(node)) return true;
		final arrayLiteralKind: Null<String> = shape.arrayLiteralKind;
		if (arrayLiteralKind != null && node.kind == arrayLiteralKind) {
			return node.children.foreach(c -> isDeletionPure(c, tree, shape, declaredTypes, index));
		}
		final parenKind: Null<String> = shape.parenKind;
		if (parenKind != null && node.kind == parenKind && node.children.length == 1)
			return isDeletionPure(node.children[0], tree, shape, declaredTypes, index);
		final uncheckedCastKind: Null<String> = shape.uncheckedCastKind;
		if (uncheckedCastKind != null && node.kind == uncheckedCastKind && node.children.length == 1)
			return isDeletionPure(node.children[0], tree, shape, declaredTypes, index);
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind != null && node.kind == fieldAccessKind) return isPlainFieldRead(node, tree, shape, declaredTypes, index);
		final callKind: Null<String> = shape.callKind;
		if (callKind != null && node.kind == callKind) return isPureStdlibCall(node, tree, shape, declaredTypes, index);
		return false;
	}

	/**
	 * Whether `callNode` is a call to a provably-pure stdlib STATIC function.
	 * Requires: the callee is a field access `Type.method` whose flattened
	 * `Type.method` names a `PURE_STDLIB_STATIC_FUNCS` entry; the receiver is a
	 * genuine type / package reference (its root identifier binds to NO local —
	 * a same-named local would make it a value call, not a static one); no
	 * project type shadows the simple type name (`index.refs.declaringFiles` empty);
	 * and every argument is itself `isDeletionPure`. A discarded such call has no
	 * observable effect, so a dead local bound to one is safe to delete. Any
	 * deviation keeps the conservative default (the binding is kept).
	 */
	public static function isPureStdlibCall(
		callNode: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: SymbolIndex
	): Bool {
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null || callNode.children.length == 0) return false;
		final callee: QueryNode = callNode.children[0];
		if (callee.kind != fieldAccessKind || callee.children.length != 1) return false;
		final method: Null<String> = callee.name;
		final receiver: QueryNode = callee.children[0];
		final typeName: Null<String> = receiver.name;
		if (method == null || typeName == null || !PURE_STDLIB_STATIC_FUNCS.contains('$typeName.$method')) return false;
		if (!receiverRootIsUnboundType(receiver, tree, shape)) return false;
		if (index.refs.declaringFiles(typeName).length != 0) return false;
		for (i in 1...callNode.children.length) if (!isDeletionPure(callNode.children[i], tree, shape, declaredTypes, index)) return false;
		return true;
	}

	/**
	 * The binding-span `from` the receiver occurrence at `recvSpan` resolves to,
	 * via the scope resolver — the key into a `TypeInfoProvider` decl-type map.
	 */
	public static function resolveBindingFrom(name: String, recvSpan: Span, tree: QueryNode, shape: RefShape): Null<Int> {
		final hit: Null<RefHit> = resolveBindingHit(name, recvSpan, tree, shape);
		return hit == null ? null : hit.bindingSpan?.from;
	}

	/**
	 * The node that DECLARES the name read at `recvSpan`, or null when the read binds to nothing
	 * the scope walk can see.
	 *
	 * The twin of `resolveBindingFrom`, which answers WHERE the declaration is. A caller that has
	 * to tell one KIND of declaration from another needs this instead: a bare `f(x)` whose `f`
	 * binds to a local closure is a different question from one whose `f` binds to a method of the
	 * enclosing type, and an offset alone cannot separate them.
	 */
	public static function bindingNodeFrom(name: String, recvSpan: Span, tree: QueryNode, shape: RefShape): Null<QueryNode> {
		final hit: Null<RefHit> = resolveBindingHit(name, recvSpan, tree, shape);
		return hit == null ? null : hit.bindingNode;
	}

	/**
	 * Whether `receiver` is a genuine TYPE reference — its ROOT identifier (walking down any
	 * `pkg.Type` field-access chain) binds to NO value: a local / parameter / field of the same
	 * name would make the access an INSTANCE access, not a static one. Shared by
	 * `isPureStdlibCall` and `ExplicitLocalType`'s static-method-return arm. False when the
	 * `fieldAccessKind` / `identKind` seams are unset, the root is not a bare identifier, or it
	 * resolves to a value binding.
	 */
	public static function receiverRootIsUnboundType(receiver: QueryNode, tree: QueryNode, shape: RefShape): Bool {
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final identKind: Null<String> = shape.identKind;
		if (fieldAccessKind == null || identKind == null) return false;
		var root: QueryNode = receiver;
		while (root.kind == fieldAccessKind && root.children.length == 1) root = root.children[0];
		final rootName: Null<String> = root.name;
		final rootSpan: Null<Span> = root.span;
		return
			root.kind == identKind && rootName != null && rootSpan != null && resolveBindingFrom(rootName, rootSpan, tree, shape) == null;
	}

	/**
	 * The binding-span `from` that the identifier `ident` resolves to — the key
	 * into a `TypeInfoProvider` declared-type / cast map. Null when `ident` is not
	 * an identifier node or its binding is unresolved.
	 */
	public static function identBindingFrom(ident: QueryNode, tree: QueryNode, shape: RefShape): Null<Int> {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null || ident.kind != identKind) return null;
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		return name == null || span == null ? null : resolveBindingFrom(name, span, tree, shape);
	}

	/**
	 * The SIMPLE declared type name of the identifier `ident` — resolves its
	 * binding via the scope resolver and reads `declaredTypes`. Null when `ident`
	 * is not an identifier node, its binding is unresolved, or the binding has no
	 * recovered nominal type (unannotated, parametric, or `Null<…>`-wrapped — all
	 * absent from `declaredTypes`).
	 */
	public static function identTypeName(
		ident: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>
	): Null<String> {
		final bindingFrom: Null<Int> = identBindingFrom(ident, tree, shape);
		return bindingFrom == null ? null : declaredTypes[bindingFrom];
	}

	/**
	 * The fully-qualified form of a SIMPLE type reference `typeSrc` (already
	 * whitespace-stripped): a qualified path (`a.b.X`) is its own FQN; a bare name
	 * (`X`) resolves via `importMap` (a plain `import a.b.X;`). Returns null for
	 * anything that is not a plain nominal reference — a generic / function / anon
	 * type (any char outside `[A-Za-z0-9_.]`), or a bare name with no matching import.
	 * Lets a check compare two type spellings by identity rather than by text.
	 */
	public static function canonicalTypeName(typeSrc: String, importMap: Map<String, String>): Null<String> {
		for (i in 0...typeSrc.length) {
			if (!isNominalChar(typeSrc.fastCodeAt(i))) return null;
		}
		return typeSrc.indexOf('.') != -1 ? typeSrc : importMap[typeSrc];
	}

	/**
	 * Whether the declaration binding at `bindingFrom` is an optional parameter
	 * (a node of kind `optionalParamKind` whose span covers it) — its value is
	 * nullable even though `declaredTypes` recorded a nominal type for it.
	 */
	public static function bindingIsOptionalParam(tree: QueryNode, bindingFrom: Int, optionalParamKind: String): Bool {
		var found: Bool = false;
		function walk(n: QueryNode): Void {
			if (found) return;
			if (n.kind == optionalParamKind) {
				final s: Null<Span> = n.span;
				if (s != null && s.from <= bindingFrom && bindingFrom < s.to) {
					found = true;
					return;
				}
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/**
	 * Whether the declaration binding at `bindingFrom` initialises itself with the LITERAL
	 * `null` — the declaration's own syntactic proof that the binding is nullable, whatever
	 * its written type says. A parameter default (`p: T = null`), a field (`var f: T = null`)
	 * and a local (`var l: T = null`) are one fact: `declaredTypes` records the nominal `T`
	 * and the initialiser contradicts it.
	 *
	 * Needs no target and no compiler, which is why it can gate a proof no oracle can check.
	 * `var x: Int = null` does not COMPILE on a static target, so a file holding one is a
	 * dynamic-target file by construction and its `Int` is nullable there; on every target a
	 * `T = null` holds null until something assigns it. Either way the binding is null at
	 * least once, so no non-null proof may be granted over it — see `isProvablyNonNull`.
	 *
	 * The initialiser must be a DIRECT child, so `var x: Int = f(null)` (null a grandchild)
	 * is not null-initialised.
	 */
	public static function bindingIsNullInitialised(
		tree: QueryNode, bindingFrom: Int, declKinds: Array<String>, nullLiteralKind: String
	): Bool {
		final decl: Null<QueryNode> = innermostDeclCovering(tree, declKinds, bindingFrom);
		return decl != null && decl.children.exists(child -> child.kind == nullLiteralKind);
	}

	/**
	 * Every declaration kind that binds a value together with an INITIALISER — parameters,
	 * fields, locals (a multi-declarator continuation included), local declaration
	 * expressions, static locals and module-level declarations. Composed from the `RefShape`
	 * seams that already name each family, so a grammar declares nothing new to be covered.
	 * A member of the union that is not a value binder (a module-level function decl) never
	 * carries a bare literal as a DIRECT child, so its presence in the union is inert.
	 */
	public static function valueBinderDeclKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = [];
		for (family in [
			shape.paramKinds,
			shape.fieldDeclKinds,
			shape.localDeclKinds,
			shape.localDeclExprKinds,
			shape.staticLocalDeclKinds,
			shape.moduleValueDeclKinds
		]) if (family != null) for (kind in family) if (!kinds.contains(kind)) kinds.push(kind);
		return kinds;
	}

	/**
	 * Whether the declaration binding at `bindingFrom` is a LOCAL (a `localDeclKinds`
	 * node) or a PARAMETER (a `paramKinds` node) — as opposed to a field or other decl.
	 * Lets a check restrict a declared-type nullable source to locals / params, since a
	 * bare field never narrows and is out of the flow engine's scope.
	 * The verbatim source of `fn`'s EXPLICIT return type, or null when it declares none (an
	 * inferred return type, or a node that is not a function at all). The return type is the
	 * child immediately before the body (`bodyKinds`) when that child is not a parameter
	 * (`paramKinds`) -- the shape every function-like grammar node shares.
	 *
	 * Consumers use it as a proof that the `return` position carries an EXPECTED TYPE: a rewrite
	 * that moves an expression out of an assignment (where the l-value typed it) into a `return`
	 * is only type-safe when the function states what it returns.
	 */
	public static function functionReturnTypeSource(
		fn: QueryNode, source: String, bodyKinds: Array<String>, paramKinds: Array<String>
	): Null<String> {
		final kids: Array<QueryNode> = fn.children;
		var bodyIdx: Int = -1;
		for (i in 0...kids.length) if (bodyKinds.contains(kids[i].kind)) {
			bodyIdx = i;
			break;
		}
		if (bodyIdx <= 0) return null;
		final candidate: QueryNode = kids[bodyIdx - 1];
		if (paramKinds.contains(candidate.kind)) return null;
		final span: Null<Span> = candidate.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

	/**
	 * The explicit return-type source in force for `node`'s CHILDREN: `node`'s own, when it
	 * introduces a function scope, and otherwise the `inherited` value passed down. The one
	 * step of a top-down walk that threads "what does the enclosing function promise to
	 * return" — a `null` result means "nothing is promised", never "not yet computed".
	 *
	 * ★ The scope set is `functionKinds` UNION `lambdaKinds`, and the union is the point. A
	 * Haxe lambda projects as `FnExpr` / `ThinParenLambdaExpr` / `ParenLambdaExpr` /
	 * `ThinArrow`, and NONE of those is in `functionKinds` — so a walk rebinding on
	 * `functionKinds` alone lets an enclosing method's declared `Bool` leak into every lambda
	 * nested in it, which is precisely a promise that method never made about the lambda's
	 * returns. Caught by a test, not by reading (`testInnerLambdaDoesNotInheritOuterBoolReturn`).
	 *
	 * An arrow lambda's body (`BlockExpr`) is not a `functionBodyKinds` entry, so
	 * `functionReturnTypeSource` yields null for one even when it is annotated `(x): Bool ->`.
	 * That is the fail-closed direction — a missed licence, never a false one.
	 */
	public static function childReturnTypeSource(
		node: QueryNode, source: String, inherited: Null<String>, functionKinds: Array<String>, lambdaKinds: Array<String>,
		bodyKinds: Array<String>, paramKinds: Array<String>
	): Null<String> {
		return functionKinds.contains(node.kind) || lambdaKinds.contains(node.kind)
			? functionReturnTypeSource(node, source, bodyKinds, paramKinds)
			: inherited;
	}

	/**
	 * Whether SOME `localDeclKinds` / `paramKinds` node COVERS the offset `bindingFrom` — a loose,
	 * span-keyed answer, and named for it. The walk is pre-order, so it answers for the OUTERMOST
	 * declaration containing the offset: a `for` binder nested in a `var`'s initializer reads as the
	 * `var`, and any binding inside a local declaration reads as that declaration.
	 *
	 * That imprecision is the SAFE direction for all four consumers — `join-return`,
	 * `join-single-use-local`, `nullable-switch-missing-null`, `return-reassign-ternary` — each of
	 * which reads a `true` as "bail out". A caller that reads a `true` as PERMISSION to drop, hoist
	 * or delete code must not use this: `bindsToValueDeclaration` is the precise sibling, which asks
	 * the resolver for the binding NODE instead of re-finding one by span.
	 */
	public static function mayBeLocalOrParam(
		tree: QueryNode, bindingFrom: Int, localDeclKinds: Array<String>, paramKinds: Array<String>
	): Bool {
		var found: Bool = false;
		function walk(n: QueryNode): Void {
			if (found) return;
			if (localDeclKinds.contains(n.kind) || paramKinds.contains(n.kind)) {
				final s: Null<Span> = n.span;
				if (s != null && s.from <= bindingFrom && bindingFrom < s.to) {
					found = true;
					return;
				}
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/**
	 * Whether the occurrence of `name` at `refSpan` binds to a VALUE DECLARATION — a local, a
	 * parameter, a `for` / `catch` binder — rather than to a type member, to a phantom, or to
	 * nothing the walk could resolve.
	 *
	 * POSITIVE proof; three conditions, every one required:
	 *
	 *  - the reference RESOLVES at all. An unresolved name — a cross-file read, an implicit-`this`
	 *    member, an inherited member, a reification interior — answers false.
	 *  - the binding node's KIND is one of the value-declaration vocabularies
	 *    (`valueDeclarationKinds`). Every other binder class, present or future, answers false by
	 *    construction rather than by an exclusion someone has to remember to write.
	 *  - the binding is declared DIRECTLY into a scope the resolver MODELS, and that scope
	 *    encloses the reference: its PARENT must be a `scopeKinds` / `branchScopeKinds` node
	 *    covering `refSpan`.
	 *
	 * The third condition is what keeps the answer sound where the scope model is WIDER than the
	 * language's. `Refs` adopts a declaration into the nearest enclosing scope-kind node, walking
	 * through everything in between — so a declaration written as the brace-less body of an `if`
	 * / `while`, inside an `untyped { … }` block, or inside a `#if` region (whose branches the
	 * plain tree folds into ONE node with no boundary between them) is visible to references the
	 * compiler binds elsewhere entirely. Each of those declares into a node that is not a modelled
	 * scope, so each answers false here. A multi-binding list (`var a = 1, b = 2`) is the one shape
	 * that legitimately declares INSIDE another declaration: `localDeclContinuationKinds` names the
	 * continuation, and the list head stands in for it.
	 *
	 * It over-refuses one measured class in exchange, and deliberately: a local declared under a
	 * TRANSPARENT wrapper — `untyped var x = 1;` or `@:meta var x = 1;`, which project as a
	 * `localDeclExprKinds` node inside `UntypedExpr` / `MetaExpr` inside a statement — does escape
	 * into the enclosing block (measured), yet its parent is the wrapper rather than the block.
	 * Admitting it would mean listing the wrapper kinds that "do not scope", which is a NEGATIVE
	 * list: the next member nobody thought of is a wrong DELETION, not a missed finding, whereas
	 * the current whitelist fails closed on shapes nobody has thought of. The trade is cheap —
	 * `untyped var` occurs 10 times in 20 964 real `.hx` files (TM, this repo, the Haxe std and the
	 * installed haxelib set), all ten being two lines of ONE file duplicated across five library
	 * versions — and it costs a finding, never a behaviour.
	 *
	 * A SELF-SCOPED binder (`for`, `catch`) has no such parent to ask — it IS the scope it binds
	 * into — and its arm is a RESTATEMENT, not a gate: `Refs` pushes such a frame only while
	 * walking inside the node that opens it and pops it on the way out, so every hit resolved
	 * through one is inside that node by construction, and `frameFor` declines to self-declare at
	 * all when the node's span is null. Removing the `covers` call there changes no result (the
	 * suite stays green with it replaced by `true`); it is kept so the containment the sentence
	 * above claims is asserted here rather than borrowed from another module.
	 *
	 * WHETHER the binding is in effect AT `refSpan` is not re-derived here either — that is
	 * `Refs.visibleFrom` and `Refs.headerFloor`, and this function trusts their answer. The floor
	 * is what keeps a `for` HEADER read (`for (p in <expr reading p>)`) bound to the enclosing
	 * declaration instead of to the iterator the loop is about to bind, so an over-refusal there
	 * does not silently become an admission. `UnnecessarySwitchCheckTest` covers that seam from
	 * this side.
	 *
	 * NOT `mayBeLocalOrParam`, and deliberately beside it rather than replacing it. That one
	 * re-finds the binding by span CONTAINMENT, so it answers for the OUTERMOST declaration
	 * covering the offset — a `for` binder nested in a `var`'s initializer reads as the `var`.
	 * Its consumers treat a `true` as "bail out", where being generous is the safe direction.
	 * Every consumer of THIS answer treats a `true` as permission to DROP or HOIST code, so it may
	 * not guess.
	 */
	public static function bindsToValueDeclaration(name: String, refSpan: Span, tree: QueryNode, shape: RefShape): Bool {
		final hit: Null<RefHit> = resolveBindingHit(name, refSpan, tree, shape);
		if (hit == null) return false;
		final binding: Null<QueryNode> = hit.bindingNode;
		if (binding == null || !valueDeclarationKinds(shape).contains(binding.kind)) return false;
		if (shape.selfScopeDeclKinds.contains(binding.kind)) return covers(binding.span, refSpan);
		final continuations: Array<String> = shape.localDeclContinuationKinds ?? [];
		var declaration: QueryNode = binding;
		while (continuations.contains(declaration.kind)) {
			final head: Null<QueryNode> = TreePath.parentOf(tree, declaration);
			if (head == null) return false;
			declaration = head;
		}
		final parent: Null<QueryNode> = TreePath.parentOf(tree, declaration);
		if (parent == null) return false;
		final branchScopes: Array<String> = shape.branchScopeKinds ?? [];
		return (shape.scopeKinds.contains(parent.kind) || branchScopes.contains(parent.kind)) && covers(parent.span, refSpan);
	}

	/**
	 * The name of the type DECLARING the field that a BARE occurrence of `name` at `refSpan`
	 * binds to, or null when the occurrence binds to anything else — a local, a parameter, a
	 * `for` / `catch` binder, a phantom, or nothing the walk could resolve.
	 *
	 * The mirror image of `bindsToValueDeclaration`, and asked for the opposite reason. That
	 * one proves a reference IS a local so a caller can bail out; this one proves a reference
	 * is NOT — it names the owning type only when the resolver bound the occurrence to a
	 * `fieldDeclKinds` DECLARATION NODE, which a local, a parameter and an unresolved name each
	 * fail for a different reason. `prefer-switch` / `prefer-switch-expression` is the caller:
	 * a bare identifier written as a `case` pattern is a compile-time constant when it names a
	 * static inline field and a CAPTURE that matches everything when it names a local, and only
	 * the binding tells the two apart. Handing back the owner's NAME rather than the node is
	 * what lets the caller finish the proof against the `SymbolIndex`, which is keyed by type
	 * name and holds the modifiers a raw declaration node does not spell.
	 *
	 * Null is the answer to every uncertainty. `Refs` is per-FILE, so an import-static, an
	 * inherited or a cross-file constant resolves to nothing and is refused; so is a binding
	 * node with no span, and a field declared outside any type declaration (a module-level
	 * field). A caller reading a non-null as permission to EMIT still owes the constness proof
	 * — this answers "which type declares it", never "is it constant".
	 */
	public static function bareFieldOwner(
		name: String, refSpan: Span, tree: QueryNode, shape: RefShape, fieldDeclKinds: Array<String>
	): Null<String> {
		final hit: Null<RefHit> = resolveBindingHit(name, refSpan, tree, shape);
		if (hit == null) return null;
		final binding: Null<QueryNode> = hit.bindingNode;
		if (binding == null || !fieldDeclKinds.contains(binding.kind)) return null;
		final declSpan: Null<Span> = binding.span;
		return declSpan == null ? null : innermostTypeDecl(tree, declSpan)?.name;
	}

	/**
	 * Whether null-safety is ACTIVE over `span`. A `@:nullSafety(disableArg)`
	 * (`@:nullSafety(Off)`) whose declaration scope — member (field / method), type
	 * (class), or module — covers `span` REFUSES (`false`): Haxe does not re-enable a
	 * disabled outer scope from an inner `Strict` (confirmed on 4.3.7), so a covering
	 * disable anywhere in the chain wins. Affirmation requires a covering non-`Off`
	 * `@:nullSafety` at TYPE / MODULE level (a class / module annotation); a
	 * member-level non-`Off` is NOT counted — that keeps the result strictly
	 * no-more-affirming than the class/module-only predicate this replaced, while a
	 * member-level `Off` can still refuse. A bare `@:nullSafety` (Haxe-default Loose)
	 * and every explicit mode (`Strict` / `StrictThreaded` / `Loose`) count as active —
	 * each rejects a null flowing into a nominally non-nullable binding, the sole
	 * guarantee `isProvablyNonNull` relies on.
	 */
	public static function enclosingIsNullSafe(tree: QueryNode, span: Span, metaName: String, disableArg: Null<String>): Bool {
		var active: Bool = false;
		for (s in collectNullSafetyScopes(tree, metaName, disableArg)) if (s.from <= span.from && span.to <= s.to) {
			if (s.disabled) return false;
			if (s.typeLevel) active = true;
		}
		return active;
	}

	/**
	 * Whether `operand` is a plain identifier resolvable to a provably non-null
	 * type — a `RefShape.nonNullableTypeNames` value type (null-safety-independent),
	 * or any recovered nominal type while null-safety is active. An operand bound to
	 * an optional parameter, to a declaration INITIALISED BY THE LITERAL `null`
	 * (`p: T = null`, `var f: T = null`, `var l: T = null` alike — the declaration's
	 * own syntax outranks its written type, so `bindingIsNullInitialised` is checked
	 * BEFORE the nominal), to a `RefShape.nullableWrapperTypeNames` type (`Null<…>` /
	 * `Dynamic` / `Any`), or with no recovered nominal type keeps the conservative
	 * default and is NOT proven non-null.
	 *
	 * The value-type arm is target-dependent and this entry point grants it. A caller
	 * whose CONSTRUCT proves the target is dynamic — a comparison against the `null`
	 * literal, which does not compile on a static target — must ask
	 * `isProvablyNonNullAtNullComparison` instead; both run the one implementation.
	 *
	 * The nominal-under-null-safety proof requires the enclosing `@:nullSafety` to be
	 * active at BOTH the operand's binding declaration and the read — the nearest
	 * annotation wins at each (member > type > module), so a member-level
	 * `@:nullSafety(Off)` on the field/local (Pony's `TouchableBase` timer fields) or
	 * on the reading method refuses, even inside a null-safe class. Bare `@:nullSafety`
	 * is Haxe-default Loose and is trusted here: Loose rejects a null flowing into a
	 * nominally non-nullable binding exactly as Strict does (its only relaxations are
	 * read-side narrowing of already-`Null<…>` values, which never reach this proof).
	 * Shared by every null-aware check whose construct is not itself target
	 * evidence (`redundant-null-coalescing`, `unnecessary-safe-nav`,
	 * `comparison-to-boolean`, …).
	 */
	public static function isProvablyNonNull(operand: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>): Bool {
		return provablyNonNull(operand, root, shape, declaredTypes, true);
	}

	/**
	 * `isProvablyNonNull` for an operand that sits in a COMPARISON AGAINST THE `null` LITERAL —
	 * the question `unnecessary-null-check` and `dead-null-guard` ask. Same proof, minus the
	 * value-type fast path: the comparison being asked about is ITSELF the evidence that this
	 * file's target treats the value type as nullable.
	 *
	 * On a static target the comparison does not COMPILE — Haxe 4.3.7 answers `On static
	 * platforms, null can't be used as basic type Int` (verified for `Int` / `Float` / `Bool` /
	 * `UInt`, on a parameter and on a field, for `-cpp` and `-hl`; `-js` / `-neko` / `-python` /
	 * `-lua` accept all four). So a file that CONTAINS one is a dynamic-target file by
	 * construction, and there a bare `Int` IS nullable, which is exactly what the guard is
	 * for. Nothing else the linter can read supplies that: `apqlint.json` carries no target
	 * key, no seam reads compiler defines, and a `compilerOracle` hxml may name several
	 * targets at once (Pony's names neko AND nodejs).
	 *
	 * The `@:nullSafety` arm below is untouched and still proves such an operand non-null:
	 * null safety normalises a non-`Null<…>` type to non-nullable on EVERY target and rejects
	 * a null flowing into it, so that conclusion is the COMPILER's rather than the target's.
	 *
	 * Note this argument does NOT extend to `??` / `?.`: `p ?? 7` on a `p: Int` compiles on
	 * `-cpp` and `-hl` (the compiler folds it), so those constructs prove nothing about the
	 * target and their checks keep `isProvablyNonNull`.
	 */
	public static function isProvablyNonNullAtNullComparison(
		operand: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>
	): Bool {
		return provablyNonNull(operand, root, shape, declaredTypes, false);
	}

	/**
	 * Whether two type SOURCES denote the same type. Exact (whitespace-insensitive)
	 * equality is the common case; when the spellings differ, both are canonicalized
	 * to an FQN via `canonicalTypeName` + the file's `importMap` and compared — so
	 * `Eof` (imported `haxe.io.Eof`) matches a qualified `haxe.io.Eof`, while
	 * `haxe.io.Eof` stays distinct from `sys.io.Eof`. A name that canonicalizes to
	 * null (a generic / function / anon type, or an unresolved bare name) yields no
	 * cross-spelling match — a safe miss. Sound within one file: an unqualified name
	 * binds to exactly one type, so equal FQNs are the same type.
	 *
	 * Whitespace is insignificant in a type EXCEPT inside a string-literal const type
	 * parameter (`Foo<"a b">`), so when either source carries a quote the comparison
	 * falls back to verbatim equality.
	 */
	public static function sameTypeSource(a: String, b: String, importMap: Map<String, String>): Bool {
		final quoted: Bool = a.indexOf('"') != -1 || a.indexOf("'") != -1 || b.indexOf('"') != -1 || b.indexOf("'") != -1;
		if (quoted) return a == b;
		final na: String = stripWs(a);
		final nb: String = stripWs(b);
		if (na == nb) return true;
		final ca: Null<String> = canonicalTypeName(na, importMap);
		final cb: Null<String> = canonicalTypeName(nb, importMap);
		return ca != null && cb != null && ca == cb;
	}

	/**
	 * The simple name of a plain nominal type SOURCE `typeSrc` — whitespace stripped, the
	 * last `.`-segment. Null when `typeSrc` is null or NOT a plain nominal (a generic /
	 * function / anonymous type — any char outside `[A-Za-z0-9_.]`). Lets a check key a
	 * `SymbolIndex` lookup (simple-name based) off a written type while rejecting shapes
	 * that can never name a single indexed class. Shared by `impossible-is-check` and
	 * `unreachable-catch`.
	 */
	public static function simpleNominalName(typeSrc: Null<String>): Null<String> {
		if (typeSrc == null) return null;
		final src: String = typeSrc;
		final buf: StringBuf = new StringBuf();
		for (i in 0...src.length) {
			final c: Int = src.fastCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) continue;
			if (!isNominalChar(c)) return null;
			buf.addChar(c);
		}
		final s: String = buf.toString();
		if (s == '') return null;
		final dot: Int = s.lastIndexOf('.');
		return dot == -1 ? s : s.substring(dot + 1);
	}

	/**
	 * The cast target type whose payload span key falls within `castSpan` — the earliest
	 * such key (the outermost payload of a nested cast). Shared by `redundant-cast` and
	 * `impossible-cast`.
	 */
	public static function castTargetWithin(castSpan: Span, castTargets: Map<Int, String>): Null<String> {
		var best: Null<String> = null;
		var bestKey: Int = -1;
		for (from => ty in castTargets) if (from >= castSpan.from && from < castSpan.to && (best == null || from < bestKey)) {
			best = ty;
			bestKey = from;
		}
		return best;
	}

	/**
	 * Whether ANY `@:nullSafety` scope is active over `span` — the member-affirming
	 * variant of `enclosingIsNullSafe`. A covering `@:nullSafety(Off)` anywhere in
	 * the chain refuses; otherwise ANY covering non-`Off` annotation — member,
	 * type, or module level — affirms. Used by the inference-fragility gate, where
	 * a member-level `@:nullSafety` on the enclosing method makes the rewrite
	 * hazard just as real as a class-level one (the affirmation asymmetry
	 * `enclosingIsNullSafe` keeps for `isProvablyNonNull` protects a PROOF of
	 * non-nullness; here the affirmative answer only makes a skip MORE
	 * conservative, so the member level is safe to count).
	 */
	public static function nullSafetyActiveAt(tree: QueryNode, span: Span, metaName: String, disableArg: Null<String>): Bool {
		var active: Bool = false;
		for (s in collectNullSafetyScopes(tree, metaName, disableArg)) if (s.from <= span.from && span.to <= s.to) {
			if (s.disabled) return false;
			active = true;
		}
		return active;
	}

	/**
	 * Whether `expr` is a field-access chain whose BASE identifier binds to a
	 * declaration with NO recoverable declared type — an INFERENCE-OPEN receiver.
	 * The paradigm case is a `for`-loop iterator over a custom `hasNext`/`next`
	 * iterator whose `next()` returns `Dynamic`: Haxe types the loop variable as
	 * an UNBOUND MONOMORPH (`Unknown<0>`), and each `base.field` access adds a
	 * structural constraint whose field TYPE is fixed by whatever context first
	 * unifies it. A rewrite that re-positions such an access between an
	 * expected-type context and a value-mode context can flip that constraint
	 * binding (`String` -> `Null<String>`) and retroactively change the type of
	 * EVERY use of the same field in the function. A base that is unresolved (a
	 * type name, `this`) or carries any declared-type entry (including a
	 * `Null<…>` / `Dynamic` wrapper — an annotated type is never a monomorph) is
	 * NOT open. Conservative over-approximation: an unannotated initialized local
	 * also reports open, though its type is fixed by its initializer.
	 */
	public static function isInferenceOpenFieldAccess(
		expr: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>
	): Bool {
		final faKind: Null<String> = shape.fieldAccessKind;
		if (faKind == null || expr.kind != faKind) return false;
		var base: QueryNode = expr;
		while (base.kind == faKind && base.children.length == 1) base = base.children[0];
		final bindingFrom: Null<Int> = identBindingFrom(base, root, shape);
		return bindingFrom != null && declaredTypes[bindingFrom] == null;
	}

	/**
	 * Whether rewriting a null guard whose FALLBACK operand is `fallback` between
	 * an expected-type context and a value-mode context is INFERENCE-FRAGILE at
	 * `site` — i.e. the rewrite may flip the fallback's inferred type from
	 * non-null to `Null<…>` and break compilation under active null-safety.
	 *
	 * The isolated mechanism (Haxe, verified 4.3.7): in an argument position
	 * (`m.get(x != null ? x : row.f)`) the ternary's branches are typed against
	 * the parameter's EXPECTED type, binding an inference-open `row.f`'s
	 * structural constraint NON-null (`row.f : String`). After the rewrite —
	 * `x ?? row.f` (operands typed against `Null<expected>`) or `m[…]` (the key
	 * typed in VALUE mode, where the null comparison creates a `Null<…>` and
	 * branch unification propagates it) — the same constraint binds NULLABLE
	 * (`row.f : Null<String>`), which retroactively poisons every later use of
	 * `row.f` in the function. Only that combination is fragile, so BOTH are
	 * required: an active `@:nullSafety` scope over `site` (member, type, or
	 * module level — without null-safety the flipped binding still compiles) AND
	 * an inference-open fallback (`isInferenceOpenFieldAccess`). The GUARDED
	 * operand needs no check: the null comparison itself binds it `Null<…>` in
	 * both the original and the rewritten form.
	 */
	public static function isInferenceFragileNullGuard(
		fallback: QueryNode, site: Span, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>
	): Bool {
		final metaName: Null<String> = shape.nullSafetyMetaName;
		if (metaName == null || !nullSafetyActiveAt(root, site, metaName, shape.nullSafetyDisableArg)) return false;
		return isInferenceOpenFieldAccess(fallback, root, shape, declaredTypes);
	}

	/** `s` with every space / tab / newline removed (whitespace is insignificant in a type). */
	public static function stripWs(s: String): String {
		final buf: StringBuf = new StringBuf();
		for (i in 0...s.length) {
			final c: Int = s.fastCodeAt(i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) buf.addChar(c);
		}
		return buf.toString();
	}

	/** The simple name of the innermost type declaration whose span contains `faSpan`, or null. */
	public static function enclosingTypeName(tree: QueryNode, faSpan: Span): Null<String> {
		return enclosingTypeDecl(tree, faSpan)?.name;
	}

	/**
	 * The verbatim (whitespace-stripped) declared type SOURCE of an identifier `recv`'s
	 * binding — a local, a parameter or an own-class field — via the scope resolver
	 * (`resolveBindingFrom`) plus `TypeInfoProvider.declaredTypeSources`. Null when `recv`
	 * is not an identifier, its binding does not resolve, the binding carries no WRITTEN
	 * type (an inference-typed source stays report-only), or the name is RE-SHADOWED in a
	 * visible scope (`var s:String; var s:Foo; … s`) where the first-wins resolver diverges
	 * from Haxe's nearest-preceding binding. A `Null<…>` wrapper is PRESERVED — a caller
	 * wanting the narrowed inner type unwraps it itself.
	 *
	 * `skipNullableOptionalParam` additionally treats a PARAMETER whose body type differs
	 * from its written source as unresolved (see `paramTypeSourceUnsafe`: an optional param
	 * with no default / any `= null` default → `Null<T>`, a rest param → `haxe.Rest<T>`, each
	 * ≠ the bare written `T`), so a caller that copies the source as the read's type (the
	 * plain-read arm) must skip it, while a caller that only needs the declared type for a
	 * method-return lookup passes false.
	 */
	public static function identDeclaredTypeSource(
		recv: QueryNode, shape: RefShape, tree: QueryNode, declaredTypeSources: () -> Map<Int, String>, skipNullableOptionalParam: Bool
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		final name: Null<String> = recv.name;
		final span: Null<Span> = recv.span;
		if (identKind == null || recv.kind != identKind || name == null || span == null) return null;
		// The scope resolver is first-wins per scope, but Haxe binds to the nearest-preceding
		// declaration; the two diverge only when a name is re-shadowed in a scope visible at the
		// use (`var s:String; var s:Foo; … s`). More than one visible declaration -> the
		// resolved type is untrustworthy, so bail to report-only.
		if (visibleDeclCount(tree, shape, name, span) > 1) return null;
		final bindingFrom: Null<Int> = resolveBindingFrom(name, span, tree, shape);
		if (bindingFrom == null) return null;
		if (skipNullableOptionalParam && paramTypeSourceUnsafe(tree, shape, bindingFrom)) return null;
		final typeSrc: Null<String> = declaredTypeSources()[bindingFrom];
		return typeSrc == null ? null : stripWs(typeSrc);
	}

	/**
	 * A lazily-memoized accessor for `plugin`'s `TypeInfoProvider.declaredTypeSources(source)`
	 * map — the span→written-type-source table the ident-type resolvers consume. Returns a
	 * thunk that computes the map on first call and caches it, so a caller that never reaches
	 * the resolution path never pays for the parse, and a `plugin` that is not a
	 * `TypeInfoProvider` yields the empty map. Shared by every check that threads
	 * `declaredTypeSources` into `identDeclaredTypeSource`.
	 */
	public static function memoizedDeclaredTypeSources(plugin: GrammarPlugin, source: String): () -> Map<Int, String> {
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		var cache: Null<Map<Int, String>> = null;
		return function(): Map<Int, String> {
			final existing: Null<Map<Int, String>> = cache;
			if (existing != null) return existing;
			final p: Null<TypeInfoProvider> = provider;
			final computed: Map<Int, String> = p != null ? p.declaredTypeSources(source) : [];
			cache = computed;
			return computed;
		};
	}

	/**
	 * The `valueDeclarationKinds` subset whose declaration binds into the ENCLOSING statement list
	 * — the statement-position locals with their expression and `static` twins, and the LOCAL
	 * FUNCTION forms (a bare read of one is a closure read, not a member read). Public because
	 * `RefactorSupport.exclusiveBranchRedeclaration` asks exactly this question ("does this statement
	 * list declare this name?"), and the two vocabularies must not drift: the union below is this list
	 * plus the binders that scope THEMSELVES.
	 *
	 * The SELF-SCOPING binders are excluded on purpose: a `for` iterator, a catch variable and a
	 * key-value binder each bind into the scope they open, so two sibling `for (i in xs)` loops — or
	 * two `catch (e:T)` clauses of one `try` — carry the name under one parent while resolving
	 * correctly, and counting them would report an ambiguity where there is none.
	 *
	 * A PARAMETER is excluded for a different reason and it is a LIMIT, not a property: a parameter is
	 * never a block child, so this list cannot name it. `exclusiveBranchRedeclaration` therefore reads
	 * the enclosing function's parameter list itself before it walks — without that, a region
	 * declaring the name inside a function that takes it as a parameter read as unambiguous and the
	 * rename corrupted every build the arm is compiled out of.
	 *
	 * `inlineFunctionKinds` is listed for completeness rather than for reachability: Haxe refuses a
	 * bare read of an `inline function` local outright (`Cannot create closure on inline closure`),
	 * so no valid input can bind an identifier to one. A grammar without that restriction gets the
	 * right answer for free.
	 */
	public static function blockScopedValueDeclarationKinds(shape: RefShape): Array<String> {
		return (shape.localDeclKinds ?? []).concat(shape.localDeclExprKinds ?? [])
			.concat(shape.staticLocalDeclKinds ?? [])
			.concat(shape.localFunctionKinds ?? [])
			.concat(shape.inlineFunctionKinds ?? []);
	}

	/** Whether `outer` covers `inner` — the containment a tree's spans state between ancestor and descendant. */
	private static inline function covers(outer: Null<Span>, inner: Span): Bool {
		return outer != null && outer.from <= inner.from && inner.to <= outer.to;
	}

	/** Whether `c` is a character of a plain nominal type reference — `[A-Za-z0-9_.]`. */
	private static inline function isNominalChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code
			|| c == '.'.code;
	}

	/** Whether `kind` is a member or type declaration — a scope a `@:nullSafety` meta can annotate. */
	private static inline function isDeclScope(kind: String): Bool {
		return MemberKinds.isFieldMemberKind(kind) || isTypeDeclScope(kind);
	}

	/** Whether `kind` is a TYPE declaration (class / interface / enum / typedef / abstract) — the level a `@:nullSafety` may affirm at. */
	private static inline function isTypeDeclScope(kind: String): Bool {
		return MemberKinds.TYPE_DECL_KINDS.contains(kind) || kind == 'FinalDecl';
	}


	/**
	 * Every node kind that DECLARES a value binding in `shape` — `blockScopedValueDeclarationKinds`
	 * plus the parameter kinds, the self-scoped binders (a `for` iterator, a catch exception) and a
	 * key-value loop's value binder. A UNION of the grammar's OWN binder vocabularies, so a grammar
	 * that gains a binder kind gains it here with it.
	 */
	private static function valueDeclarationKinds(shape: RefShape): Array<String> {
		return blockScopedValueDeclarationKinds(shape)
			.concat(shape.paramKinds ?? [])
			.concat(shape.selfScopeDeclKinds)
			.concat(shape.iterationValueBinderKinds ?? []);
	}


	/**
	 * The hit the reference walk emitted for the occurrence of `name` at `refSpan`, or null when
	 * it emitted none there — a member-access slot, a reification interior, an unspanned node.
	 * Both public resolvers read one field of it apiece: the binding's OFFSET keys a decl-type
	 * map, the binding's NODE says what the reference actually binds to.
	 */
	private static function resolveBindingHit(name: String, refSpan: Span, tree: QueryNode, shape: RefShape): Null<RefHit> {
		for (hit in Refs.find(name, tree, shape)) if (hit.span.from == refSpan.from && hit.span.to == refSpan.to) return hit;
		return null;
	}

	/** The innermost type declaration whose span contains `faSpan`, or null. */
	private static function innermostTypeDecl(tree: QueryNode, faSpan: Span): Null<TypeDeclMatch> {
		var best: Null<TypeDeclMatch> = null;
		function walk(n: QueryNode): Void {
			final td: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(n);
			if (td != null && td.fullSpan.from <= faSpan.from && faSpan.to <= td.fullSpan.to) {
				final width: Int = td.fullSpan.to - td.fullSpan.from;
				final b: Null<TypeDeclMatch> = best;
				if (b == null || width < b.fullSpan.to - b.fullSpan.from) best = td;
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/** Whether `node` or any descendant carries the name `name`. */
	private static function subtreeHasName(node: QueryNode, name: String): Bool {
		return node.name == name || node.children.exists(c -> subtreeHasName(c, name));
	}

	/**
	 * Every `@:nullSafety` annotation in `tree` as a scope span — from the meta's
	 * start to the end of the member / type declaration it precedes (modifier and
	 * unrelated-meta siblings in between are skipped). `disabled` records whether the
	 * meta carries `disableArg` (`Off`). A meta not followed by a member / type
	 * declaration at its own level (a statement- or expression-level annotation) is
	 * dropped: it falls outside the member > type > module hierarchy this models.
	 */
	private static function collectNullSafetyScopes(tree: QueryNode, metaName: String, disableArg: Null<String>): Array<{
		from: Int,
		to: Int,
		disabled: Bool,
		typeLevel: Bool
	}> {
		final scopes: Array<{
			from: Int,
			to: Int,
			disabled: Bool,
			typeLevel: Bool
		}> = [];
		function walk(node: QueryNode): Void {
			var pending: Array<{ from: Int, disabled: Bool }> = [];
			for (c in node.children) {
				final cs: Null<Span> = c.span;
				if (cs != null && c.name == metaName)
					pending.push({ from: cs.from, disabled: metaDisabled(c, disableArg) });
				else if (cs != null && isDeclScope(c.kind)) {
					final typeLevel: Bool = isTypeDeclScope(c.kind);
					for (p in pending) scopes.push({
						from: p.from,
						to: cs.to,
						disabled: p.disabled,
						typeLevel: typeLevel
					});
					pending = [];
				}
				walk(c);
			}
		}
		walk(tree);
		return scopes;
	}

	/** Whether a `@:nullSafety` meta node carries the disable argument (`Off`). */
	private static function metaDisabled(meta: QueryNode, disableArg: Null<String>): Bool {
		return disableArg != null && subtreeHasName(meta, disableArg);
	}

	/**
	 * The binding `operand` (an identifier) resolves to for nullability — the naive lexical
	 * binding, CORRECTED for self-shadowing. When `operand` sits inside the initializer of a
	 * same-named local `var` / `final`, the lexical resolver binds it to that just-declared
	 * local (declared type, non-null); but a var/final is NOT in scope in its own
	 * initializer, so its RHS must see the ENCLOSING binding (the shadowed param / outer
	 * local / field). Re-resolves to that enclosing binding. Null when `operand` is not an
	 * identifier, its binding is unresolved, or (self-shadow) no enclosing binding exists —
	 * the caller then keeps its conservative default.
	 */
	private static function operandBindingFrom(operand: QueryNode, root: QueryNode, shape: RefShape): Null<Int> {
		final naive: Null<Int> = identBindingFrom(operand, root, shape);
		if (naive == null) return null;
		final naiveFrom: Int = naive;
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final opSpan: Null<Span> = operand.span;
		final name: Null<String> = operand.name;
		if (localDeclKinds.length == 0 || opSpan == null || name == null) return naive;
		final selfLocal: Null<Span> = selfShadowLocalSpan(root, localDeclKinds, name, opSpan, naiveFrom);
		return selfLocal == null ? naive : enclosingBindingFrom(root, shape, name, selfLocal, opSpan);
	}

	/**
	 * The span of the local `var` / `final` declaration `operand` naively binds to WHEN that
	 * binding is the operand's own initializer — a `localDeclKinds` node named `name` that
	 * starts at `naiveFrom` and whose span contains `opSpan`. Null when the naive binding is
	 * not such a self-referential local initializer (a normal read positioned after the
	 * declaration, a param, or a field).
	 */
	private static function selfShadowLocalSpan(
		tree: QueryNode, localDeclKinds: Array<String>, name: String, opSpan: Span, naiveFrom: Int
	): Null<Span> {
		var found: Null<Span> = null;
		function walk(n: QueryNode): Void {
			if (found != null) return;
			final s: Null<Span> = n.span;
			if (
				s != null && s.from == naiveFrom && n.name == name && localDeclKinds.contains(n.kind) && s.from <= opSpan.from
				&& opSpan.to <= s.to
			) {
				found = s;
				return;
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/**
	 * The `from` of the binding of `name` visible in the scope ENCLOSING the self-shadowing
	 * local declared at `selfSpan` — the decl-host of `name` (a `declHostKinds` node other
	 * than the self-local, declared before it) in the INNERMOST enclosing scope that still
	 * covers `opSpan`. This is the binding the self-referential initializer actually reads
	 * (the shadowed param / outer local / field). Null when none exists.
	 */
	private static function enclosingBindingFrom(tree: QueryNode, shape: RefShape, name: String, selfSpan: Span, opSpan: Span): Null<Int> {
		final declHostKinds: Array<String> = shape.declHostKinds;
		final scopeKinds: Array<String> = shape.scopeKinds;
		var bestFrom: Null<Int> = null;
		var bestWidth: Int = 0;
		final scopeStack: Array<Span> = [];
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (s != null && n.name == name && s.from < selfSpan.from && declHostKinds.contains(n.kind) && scopeStack.length > 0) {
				final enc: Span = scopeStack[scopeStack.length - 1];
				if (enc.from <= opSpan.from && opSpan.to <= enc.to) {
					final width: Int = enc.to - enc.from;
					final prev: Null<Int> = bestFrom;
					if (prev == null || width < bestWidth || (width == bestWidth && s.from > prev)) {
						bestFrom = s.from;
						bestWidth = width;
					}
				}
			}
			final scopeSpan: Null<Span> = s != null && scopeKinds.contains(n.kind) ? s : null;
			if (scopeSpan != null) scopeStack.push(scopeSpan);
			for (c in n.children) walk(c);
			if (scopeSpan != null) scopeStack.pop();
		}
		walk(tree);
		return bestFrom;
	}

	/**
	 * The number of declarations of `name` VISIBLE at `useSpan` — a `declHostKinds`
	 * node named `name` whose innermost enclosing `scopeKinds` scope also contains
	 * `useSpan`. More than one means the name is re-shadowed in a visible scope, where
	 * the first-wins scope resolver cannot be trusted to match Haxe's binding.
	 */
	private static function visibleDeclCount(tree: QueryNode, shape: RefShape, name: String, useSpan: Span): Int {
		final declHostKinds: Array<String> = shape.declHostKinds;
		final scopeKinds: Array<String> = shape.scopeKinds;
		var count: Int = 0;
		final scopeStack: Array<Span> = [];
		function walk(node: QueryNode): Void {
			final s: Null<Span> = node.span;
			if (s != null && node.name == name && declHostKinds.contains(node.kind) && scopeStack.length > 0) {
				final enc: Span = scopeStack[scopeStack.length - 1];
				if (enc.from <= useSpan.from && useSpan.to <= enc.to) count++;
			}
			final scopeSpan: Null<Span> = s != null && scopeKinds.contains(node.kind) ? s : null;
			if (scopeSpan != null) scopeStack.push(scopeSpan);
			for (c in node.children) walk(c);
			if (scopeSpan != null) scopeStack.pop();
		}
		walk(tree);
		return count;
	}

	/**
	 * Whether the parameter binding at `bindingFrom` has a body type that DIFFERS from its
	 * written type source `T`, so copying the source verbatim as a read's type would be
	 * wrong. Three forms qualify: an OPTIONAL parameter with no default (`?p:T`, an
	 * `optionalParamKind` node with no child) and any `= null`-default parameter
	 * (`bindingIsNullInitialised`) are `Null<T>`; a REST parameter (`...p:T`, a
	 * `restParamKind` node) is `haxe.Rest<T>`. A required param, and an optional / required
	 * param with a NON-null default, keep `T` and are safe to copy.
	 */
	private static function paramTypeSourceUnsafe(tree: QueryNode, shape: RefShape, bindingFrom: Int): Bool {
		final optKind: Null<String> = shape.optionalParamKind;
		final optNode: Null<QueryNode> = optKind == null ? null : innermostDeclCovering(tree, [optKind], bindingFrom);
		if (optNode != null && optNode.children.length == 0) return true;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		final nullLiteralKind: Null<String> = shape.nullLiteralKind;
		if (paramKinds != null && nullLiteralKind != null && bindingIsNullInitialised(tree, bindingFrom, paramKinds, nullLiteralKind))
			return true;
		final restKind: Null<String> = shape.restParamKind;
		return restKind != null && innermostDeclCovering(tree, [restKind], bindingFrom) != null;
	}

	/**
	 * The one implementation behind both entry points. `trustValueTypes` grants the
	 * `RefShape.nonNullableTypeNames` fast path; a caller whose construct proves the target is
	 * dynamic passes `false` and falls through to the null-safety arm.
	 */
	private static function provablyNonNull(
		operand: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, trustValueTypes: Bool
	): Bool {
		final bindingFrom: Null<Int> = operandBindingFrom(operand, root, shape);
		if (bindingFrom == null) return false;
		// A re-shadowed name whose resolved binding sits AFTER the use is a forward bind: the
		// first-wins scope resolver picked a later same-name shadow (a `n:Null<T>` param plus a
		// later `final n:T = n;` capture) that does not dominate this use, so its declared type
		// is untrustworthy -> grant no non-null proof. A self-referential initializer
		// (`final p:T = p ?? ...`) re-resolves in operandBindingFrom to the earlier enclosing
		// binding (backward) and stays provable; a field used before its own later declaration
		// has a single visible decl, so it is untouched.
		final useName: Null<String> = operand.name;
		final useSpan: Null<Span> = operand.span;
		if (useName != null && useSpan != null && bindingFrom > useSpan.from && visibleDeclCount(root, shape, useName, useSpan) > 1)
			return false;
		final optionalParamKind: Null<String> = shape.optionalParamKind;
		if (optionalParamKind != null && bindingIsOptionalParam(root, bindingFrom, optionalParamKind)) return false;
		// A declaration that initialises ITSELF to the literal `null` is nullable by its own
		// syntax, before any written type or `@:nullSafety` is consulted: `var esVersion: Int =
		// null` records the nominal `Int` in `declaredTypes` and is null on every target that
		// compiles it. Parameters (`p: T = null`), fields and locals are one case here.
		final nullLiteralKind: Null<String> = shape.nullLiteralKind;
		if (nullLiteralKind != null && bindingIsNullInitialised(root, bindingFrom, valueBinderDeclKinds(shape), nullLiteralKind))
			return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		final nonNullableTypeNames: Array<String> = shape.nonNullableTypeNames ?? [];
		if (trustValueTypes && nonNullableTypeNames.contains(typeName)) return true;
		final nullableWrapperTypeNames: Array<String> = shape.nullableWrapperTypeNames ?? [];
		if (nullableWrapperTypeNames.contains(typeName)) return false;
		final nullSafetyMetaName: Null<String> = shape.nullSafetyMetaName;
		final opSpan: Null<Span> = operand.span;
		if (nullSafetyMetaName == null || opSpan == null) return false;
		final disableArg: Null<String> = shape.nullSafetyDisableArg;
		return enclosingIsNullSafe(root, new Span(bindingFrom, bindingFrom), nullSafetyMetaName, disableArg)
			&& enclosingIsNullSafe(root, opSpan, nullSafetyMetaName, disableArg);
	}

	/**
	 * The INNERMOST `declKinds` node whose span covers `bindingFrom` — the declaration that
	 * actually binds that offset when several nest. A multi-declarator list nests its
	 * continuations (`var a: T = null, b: T = 0` projects `b`'s node as a CHILD of `a`'s), so
	 * an outermost-first walk answers for the FIRST declarator no matter which name was asked
	 * about; the innermost answers for the one that owns `bindingFrom`. A single-kind caller
	 * (a parameter located by its binding offset) passes a one-element list.
	 */
	private static function innermostDeclCovering(tree: QueryNode, declKinds: Array<String>, bindingFrom: Int): Null<QueryNode> {
		var best: Null<QueryNode> = null;
		var bestWidth: Int = -1;
		function walk(node: QueryNode): Void {
			final s: Null<Span> = node.span;
			if (s != null && s.from <= bindingFrom && bindingFrom < s.to && declKinds.contains(node.kind)) {
				final width: Int = s.to - s.from;
				if (bestWidth == -1 || width < bestWidth) {
					best = node;
					bestWidth = width;
				}
			}
			for (child in node.children) walk(child);
		}
		walk(tree);
		return best;
	}

}
