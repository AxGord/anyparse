package anyparse.check;

import anyparse.check.Check.OracleAssisted;
import anyparse.check.Check.TypeOracle;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MemberKinds;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags a class / abstract / interface member that omits an explicit type — a
 * field with no `:Type`, a function parameter with no `:Type`, or a function with
 * no return type. Stating types everywhere is a documented project rule; the check
 * holds without a type-checker because the omission is purely syntactic.
 * A conservative autofix fills in a statically-certain initializer type, plus a : Void return
 * type when a block-bodied function has no value-return and no throw in its own scope (nested
 * functions and lambdas excluded). A non-Void return type has no structural evidence at all, so
 * it is the `OracleAssisted` pass (`fixWithOracle`), which asks the compiler and therefore runs
 * only under a configured `compilerOracle`; the rest stays report-only.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.fieldDeclKinds` are the field hosts; `RefShape.memberDeclKinds` minus
 * those are the function hosts. `RefShape.paramKinds` are parameters,
 * `RefShape.functionBodyKinds` the body markers — a function child that is neither
 * a parameter nor a body is its return type. Field / parameter type presence is
 * read from source: the type annotation is not projected as a node, but it sits
 * between the name and the initializer / default, so a `:` there means a type is
 * present. Enum-abstract values (a `RefShape.enumAbstractDeclKind` member's
 * fields) are exempt — their type is the abstract's underlying type. Any unset →
 * no-op.
 */
@:nullSafety(Strict)
final class ExplicitType implements Check implements OracleAssisted {

	/**
	 * An anonymous-structure return type longer than this stays report-only — the same
	 * default the sibling `explicit-local-type` applies to inferred local types, where a
	 * long inline structure is noise rather than documentation.
	 */
	private static inline final MAX_ANON_LEN: Int = 80;

	/**
	 * Simple names visible WITHOUT an import from every Haxe module — the standard library's root
	 * package. `collectInheritedParamEdits` may copy one of these across files unconditionally;
	 * every other name has to be proven to denote the same type on both sides. Hand-maintained on
	 * purpose: the resolution index does not model the standard library unless a project happens to
	 * name it as a resolution library, so this list — not the index — is what makes the common
	 * `str:String` copy possible at all.
	 */
	private static final AMBIENT_TYPES: Array<String> = [
		'Any',
		'Array',
		'Bool',
		'Class',
		'Dynamic',
		'Enum',
		'EnumValue',
		'Float',
		'Int',
		'Iterable',
		'Iterator',
		'KeyValueIterator',
		'Map',
		'Null',
		'Single',
		'String',
		'UInt',
		'Void'
	];

	public function new() {}

	/**
	 * The oracle-assisted RETURN-TYPE pass: annotate every flagged function whose type the
	 * display server names. `fix()` leaves a non-`Void` return type report-only because no
	 * structural evidence pins it; the compiler's own answer is that evidence, so the same
	 * findings become fixable the moment a project configures a `compilerOracle`. Everything
	 * else the check reports — fields, parameters — is already handled structurally and is
	 * skipped here: a violation whose span keys a FUNCTION node is the return-type finding,
	 * since a field / parameter violation keys its own node instead.
	 *
	 * Per finding, every failed gate is a silent skip that leaves it report-only: a `macro`
	 * function (its `Expr` return is implicit), a body the annotation cannot be placed before
	 * (`voidInsertPoint`), a name token the source does not spell in active code, a reply that
	 * is not a printed function type (`returnTypeOf`), and a type `normalizeWith` refuses.
	 */
	public function fixWithOracle(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, oracle: TypeOracle
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final bodies: Array<String> = shape.functionBodyKinds ?? [];
		final functions: Array<String> = [for (k in members) if (!fields.contains(k)) k];
		if (functions.length == 0 || bodies.length == 0 || violations.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final flagged: Map<String, Bool> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan != null) flagged['${vspan.from}:${vspan.to}'] = true;
		}
		final printer: TypeRefPrinter = ExplicitLocalType.printerFor(source, tree, plugin);
		final seams: ReturnSeams = {
			source: source,
			file: violations[0].file,
			bodies: bodies,
			flagged: flagged,
			printer: printer,
			oracle: oracle,
			regions: plugin.lexicalRegions(source)
		};
		final macroKind: Null<String> = shape.macroModifierKind;
		final boundary: QueryNode -> Bool = c -> members.contains(c.kind);
		final edits: Array<{ span: Span, text: String }> = [];

		function walk(node: QueryNode): Void {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final child: QueryNode = kids[i];
				if (functions.contains(child.kind) && !MemberKinds.macroModifierPrecedes(kids, i, macroKind, boundary)) {
					final edit: Null<{ span: Span, text: String }> = returnEdit(seams, child);
					if (edit != null) edits.push(edit);
				}
				walk(child);
			}
		}
		walk(tree);
		if (edits.length > 0) for (importEdit in printer.pendingImportEdits()) edits.push(importEdit);
		return edits;
	}

	public function id(): String {
		return 'explicit-type';
	}

	public function description(): String {
		return 'a member field, parameter, or return type without an explicit type annotation';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
		final params: Array<String> = shape.paramKinds ?? [];
		final bodies: Array<String> = shape.functionBodyKinds ?? [];
		final enumAbstract: Null<String> = shape.enumAbstractDeclKind;
		// Function hosts are the member kinds that are not fields; a missing fields
		// or functions set leaves the check with nothing useful to do.
		final functions: Array<String> = [for (k in memberKinds) if (!fields.contains(k)) k];
		if (fields.length == 0 || functions.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			// checkstyle `Type.ignoreEnumAbstractValues` (default true) toggles the enum-abstract-value exemption.
			final ignoreEA: Bool = plugin.checkOverrides(entry.file)?.explicitTypeIgnoreEnumAbstract ?? true;
			final ea: Null<String> = ignoreEA ? enumAbstract : null;
			// The same exemption for the values of an enum abstract written `@:enum` (or through the
			// `#if` version guard): they project under a plain abstract, and annotating one with its
			// literal's type is a compile error (`Int should be <the abstract>`).
			final guarded: Array<Int> = ignoreEA ? EnumAbstractForms.valueStarts(plugin, tree) : [];
			walk(violations, entry.file, entry.source, tree, null, fields, functions, params, bodies, ea, guarded);
		}
		return violations;
	}

	/**
	 * Annotate a field / parameter whose initializer has a statically-certain type: a
	 * literal (`String` / `Bool` / `Int` / `Float`, negatives included), a `new T<...>()`
	 * with written type parameters, or a typed cast / check-type `(x : T)`. Everything
	 * uncertain — a bare `new T()` (possibly generic), a call, a field read, an array /
	 * map / ternary, or a `[]` — is left report-only: a wrong annotation breaks the build, so when
	 * uncertain the fix skips. A missing non-Void return type is report-only HERE too, and is
	 * picked up by `fixWithOracle` when the project configures a compiler oracle.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final params: Array<String> = shape.paramKinds ?? [];
		final fixable: Array<String> = fields.concat(params);
		if (fixable.length == 0) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final edits: Array<{ span: Span, text: String }> = [];
		collectInitializerEdits(tree, source, violations, shape, plugin, fixable, edits);
		final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
		final functions: Array<String> = [for (k in memberKinds) if (!fields.contains(k)) k];
		collectVoidReturnEdits(tree, source, shape, violations, functions, memberKinds, edits);
		collectInheritedParamEdits(tree, source, violations, plugin, index, functions, params, edits);
		return edits;
	}

	/**
	 * The RETURN half of a printed function type — `(name : String) -> String` yields `String`.
	 * Public as the parse seam its own tests drive: only a function-TYPED parameter discriminates
	 * the depth scan, and no realistic fixture reaches that shape through the display server.
	 * The compiler prints a method's own type as a parenthesised parameter group followed by
	 * `->` and the result, so a reply of any other shape (a position that resolved to a value,
	 * a query the server could not answer) yields null. The group's closing parenthesis is
	 * found by DEPTH, so a function-typed parameter cannot end it early.
	 */
	public static function returnTypeOf(printed: String): Null<String> {
		final t: String = printed.trim();
		if (t.length == 0 || t.fastCodeAt(0) != '('.code) return null;
		var depth: Int = 0;
		var i: Int = 0;
		while (i < t.length) {
			final c: Int = t.fastCodeAt(i);
			if (c == '('.code)
				depth++;
			else if (c == ')'.code && --depth == 0)
				break;
			i++;
		}
		if (i >= t.length) return null;
		final rest: String = t.substring(i + 1).ltrim();
		if (!rest.startsWith('->')) return null;
		final ret: String = rest.substring(2).trim();
		return ret.length == 0 ? null : ret;
	}

	/** Whether `c` is a space or tab — horizontal whitespace, excluding line breaks. */
	private static inline function isInlineSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code;
	}

	/** Whether `c` continues a dotted type-reference token — a letter, digit, `_` or `.`. */
	private static inline function isNominalPart(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code
			|| c == '.'.code;
	}

	/**
	 * The annotation edit for ONE flagged function, or null when any gate fails. Split out of
	 * `fixWithOracle` for the complexity budget; every `null` here leaves the finding report-only.
	 */
	private static function returnEdit(s: ReturnSeams, fn: QueryNode): Null<{ span: Span, text: String }> {
		final span: Null<Span> = fn.span;
		final name: Null<String> = fn.name;
		if (span == null || name == null || !s.flagged.exists('${span.from}:${span.to}')) return null;
		final body: Null<QueryNode> = fn.children.find(c -> s.bodies.contains(c.kind));
		if (body == null) return null;
		final at: Int = voidInsertPoint(span.from, body, s.source);
		if (at < 0) return null;
		// The display server answers at a position INSIDE the name token, not at the
		// `function` keyword the node's span starts on.
		final nameAt: Int = OccurrenceScan.activeCodeIdentTokenOffset(s.source, span, name, s.regions);
		if (nameAt < 0) return null;
		final raw: Null<String> = s.oracle.typeAt(s.file, nameAt + name.length - 1);
		final ret: Null<String> = raw == null ? null : returnTypeOf(raw);
		if (ret == null) return null;
		// The `<method>.<param>` form can only be printed for a method that DECLARES type
		// parameters — `<` right after the name token. Without that proof the same shape is an
		// ordinary package-qualified type whose package tail happens to match the method name.
		final generic: Bool = s.source.fastCodeAt(nameAt + name.length) == '<'.code;
		final norm: Null<String> = ExplicitLocalType.normalizeWith(ret, s.printer, MAX_ANON_LEN, {
			file: s.file,
			methodName: generic ? name : null
		}, at);
		return norm == null ? null : { span: new Span(at, at), text: ':$norm' };
	}

	/**
	 * Walk `node` carrying its `parentKind` (for the enum-abstract exemption). A
	 * field with no type annotation is flagged unless its container is an enum
	 * abstract; a function has each untyped parameter and its missing return type
	 * flagged. `guarded` holds the span starts of the values of an enum abstract the grammar does
	 * not project as one (`EnumAbstractForms`), which carries the same exemption.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, parentKind: Null<String>, fields: Array<String>,
		functions: Array<String>, params: Array<String>, bodies: Array<String>, enumAbstract: Null<String>, guarded: Array<Int>
	): Void {
		if (fields.contains(node.kind)) {
			final exempt: Bool = parentKind == enumAbstract || EnumAbstractForms.isValue(node.span, guarded);
			if (!exempt && !LiteralInfer.hasTypeBeforeInit(node, source))
				push(out, file, node.span, 'field declared without an explicit type');
		} else if (functions.contains(node.kind))
			checkFunction(out, file, source, node, params, bodies);
		for (c in node.children) walk(out, file, source, c, node.kind, fields, functions, params, bodies, enumAbstract, guarded);
	}

	/**
	 * Flag each untyped parameter of `fn`, and `fn` itself when it has no return
	 * type — a child that is neither a parameter nor a body marker. A constructor
	 * (`new`) is exempt from the return-type rule: it has no return type.
	 * Flag each untyped parameter of `fn`, and `fn` itself when it has no return
	 * type. A constructor (`new`) is exempt from the return-type rule — it has no
	 * return type to declare.
	 */
	private static function checkFunction(
		out: Array<Violation>, file: String, source: String, fn: QueryNode, params: Array<String>, bodies: Array<String>
	): Void {
		for (child in fn.children) if (params.contains(child.kind) && !LiteralInfer.hasTypeBeforeInit(child, source))
			push(out, file, child.span, 'parameter declared without an explicit type');
		if (fn.name != 'new' && !hasReturnType(fn, params, bodies))
			push(out, file, fn.span, 'function declared without an explicit return type');
	}

	/**
	 * Whether `fn` declares a return type. A generic constraint (`<T:C>`) and a
	 * return type project as the same kind of node, but a constraint sits before the
	 * parameters and the return type immediately before the body — so the return type
	 * is the child directly preceding the body marker, when that child is neither a
	 * parameter nor a body. (A constrained generic with no parameters and no return
	 * type is the one residual miss; it under-reports, never false-positives.)
	 */
	private static function hasReturnType(fn: QueryNode, params: Array<String>, bodies: Array<String>): Bool {
		final kids: Array<QueryNode> = fn.children;
		var bodyIndex: Int = -1;
		for (i in 0...kids.length) if (bodies.contains(kids[i].kind)) bodyIndex = i;
		if (bodyIndex <= 0) return false;
		final before: QueryNode = kids[bodyIndex - 1];
		return !params.contains(before.kind) && !bodies.contains(before.kind);
	}

	private static function push(out: Array<Violation>, file: String, span: Null<Span>, message: String): Void {
		if (span != null) out.push({
			file: file,
			span: span,
			rule: 'explicit-type',
			severity: Severity.Warning,
			message: message
		});
	}

	/**
	 * The `: Void` return-type pass of `fix()`: annotate every flagged function whose
	 * block body holds no value-return or throw in its own scope. The invariants are
	 * captured by the local `walk` / `editVoid` closures — mirroring the recursive-walker
	 * shape used elsewhere (`CallGraph.collectNodes`) — instead of being threaded through
	 * every recursive call. A `macro`-modified function returns `Expr` implicitly and is
	 * left report-only, detected via `RefactorSupport.macroModifierPrecedes` whose run
	 * ends at the previous member declaration.
	 */
	private static function collectVoidReturnEdits(
		tree: QueryNode, source: String, shape: RefShape, violations: Array<Violation>, functions: Array<String>, members: Array<String>,
		edits: Array<{ span: Span, text: String }>
	): Void {
		final valueReturns: Array<String> = shape.valueReturnKinds ?? [];
		if (functions.length == 0 || valueReturns.length == 0) return;
		final blockBody: Null<String> = shape.blockBodyKind;
		if (blockBody == null) return;
		final blockBodyKind: String = blockBody;
		final stop: Array<String> = (shape.localFunctionKinds ?? []).concat(shape.lambdaKinds ?? []);
		final throwKinds: Array<String> = shape.throwKinds ?? [];
		final macroKind: Null<String> = shape.macroModifierKind;
		final flagged: Map<String, Violation> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan != null) flagged['${vspan.from}:${vspan.to}'] = v;
		}
		final boundary: QueryNode -> Bool = c -> members.contains(c.kind);

		function editVoid(fn: QueryNode): Void {
			final span: Null<Span> = fn.span;
			if (span == null || !flagged.exists('${span.from}:${span.to}')) return;
			final body: Null<QueryNode> = fn.children.find(c -> c.kind == blockBodyKind);
			// A throw in the function's own scope makes its return type unify with any type
			// (a caller may use the call as a value), so `: Void` would be unsound — leave it
			// report-only, as with a value-return.
			if (
				body == null || MemberKinds.subtreeContainsKindStopping(body, valueReturns, stop)
				|| MemberKinds.subtreeContainsKindStopping(body, throwKinds, stop)
			)
				return;
			final at: Int = voidInsertPoint(span.from, body, source);
			if (at >= 0) edits.push({ span: new Span(at, at), text: ':Void' });
		}

		function walk(node: QueryNode): Void {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final child: QueryNode = kids[i];
				if (functions.contains(child.kind) && !MemberKinds.macroModifierPrecedes(kids, i, macroKind, boundary)) editVoid(child);
				walk(child);
			}
		}
		walk(tree);
	}

	/**
	 * The offset right after the parameter list's `)` — where a return-type annotation is
	 * inserted, before the body — found by scanning back from the body's first token over
	 * horizontal whitespace only. Shared by the structural `: Void` pass and the oracle-assisted
	 * one. The first non-whitespace character must be the `)`;
	 * anything else (a comment ending in `)`, or the `)` and `{` on separate lines)
	 * leaves the finding report-only, so a `)` inside a comment between the parameter
	 * list and the body is never mistaken for the parameter close. Returns -1 when the
	 * `)` is not immediately before the body.
	 */
	private static function voidInsertPoint(lo: Int, body: QueryNode, source: String): Int {
		final bodySpan: Null<Span> = body.span;
		if (bodySpan == null) return -1;
		var pos: Int = bodySpan.from;
		while (pos > lo && isInlineSpace(source.fastCodeAt(pos - 1))) pos--;
		return pos > lo && source.fastCodeAt(pos - 1) == ')'.code ? pos : -1;
	}

	/**
	 * The INHERITED-SIGNATURE pass of `fix()`: type a flagged parameter by COPYING the annotation
	 * the SAME method carries on a supertype or implemented interface of the enclosing type.
	 * `class H implements I { public function get(str) … }` against
	 * `interface I { function get(str:String):Bytes; }` yields `str:String` — the one parameter
	 * type that is not an inference guess but a written declaration the implementation must match.
	 *
	 * The search is the transitive `supertypes` + `interfaces` closure of the enclosing type, and
	 * EVERY ambiguity is a conservative skip that leaves the finding report-only, because a wrong
	 * annotation breaks the build:
	 *
	 * - no `SymbolIndex` (the check ran outside a resolving fix path) or the enclosing type is not
	 *   indexed / not found by span;
	 * - a constructor — `new` is never inherited, so a supertype ctor's signature is unrelated;
	 * - no type in the closure declares a member of that name (a plain method: its type would need
	 *   the compiler oracle, which this pass does not use);
	 * - a declaring type whose source is unavailable or does not parse, whose parameter list is
	 *   SHORTER, whose parameter at that position carries a different OPTIONALITY (`?p` vs `p` are
	 *   different node kinds and a mismatched implementation would not compile), or which leaves
	 *   that parameter untyped as well;
	 * - a GENERIC declaring type (`typeParamArity != 0`): it states its members with its own type
	 *   parameters, which the implementation binds to anything, so a copied `T` names nothing here;
	 * - two declaring types stating DIFFERENT type sources for the position;
	 * - a parameter the initializer pass already annotated from its default value;
	 * - a type source not usable from THIS file verbatim (`typeUsableFrom`). The pass copies a type
	 *   REFERENCE, never an import: `AddImport` returns a whole rewritten source rather than a span
	 *   edit, and a file whose import block sits inside `#if` regions has no safe insert slot to
	 *   compute from a check's `fix`.
	 */
	private static function collectInheritedParamEdits(
		tree: QueryNode, source: String, violations: Array<Violation>, plugin: GrammarPlugin, index: Null<SymbolIndex>,
		functions: Array<String>, params: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		if (index == null || functions.length == 0 || params.length == 0 || violations.length == 0) return;
		// Re-bound to a non-null local: strict null-safety narrowing does not reach a struct literal.
		final idx: SymbolIndex = index;
		final file: String = violations[0].file;
		final fi: Null<FileInfo> = idx.fileInfo(file);
		if (fi == null) return;
		final owners: Array<TypeDeclInfo> = fi.types;
		final flagged: Map<String, Bool> = [];
		for (v in violations) {
			final vs: Null<Span> = v.span;
			if (vs != null) flagged['${vs.from}:${vs.to}'] = true;
		}
		final seams: InheritedSeams = {
			idx: idx,
			plugin: plugin,
			file: file,
			functions: functions,
			params: params
		};

		function visit(node: QueryNode): Void {
			final name: Null<String> = node.name;
			if (functions.contains(node.kind) && name != null && name != 'new') {
				final own: Array<QueryNode> = [for (c in node.children) if (params.contains(c.kind)) c];
				final owner: Null<TypeDeclInfo> = enclosingType(owners, node.span);
				if (owner != null) for (i in 0...own.length) paramEdit(seams, owner, name, own, i, source, edits, flagged);
			}
			for (c in node.children) visit(c);
		}
		visit(tree);
	}

	/**
	 * Push the annotation edit for `own[i]` when it is flagged, not already annotated by another
	 * pass, and the inherited declaration yields a type source usable from this file. Every failed
	 * gate is a silent skip — the finding stays report-only.
	 */
	private static function paramEdit(
		s: InheritedSeams, owner: TypeDeclInfo, method: String, own: Array<QueryNode>, i: Int, source: String,
		edits: Array<{ span: Span, text: String }>, flagged: Map<String, Bool>
	): Void {
		final node: QueryNode = own[i];
		final span: Null<Span> = node.span;
		if (span == null || !flagged.exists('${span.from}:${span.to}')) return;
		for (e in edits) if (e.span.from >= span.from && e.span.from <= span.to) return;
		final found: Null<InheritedParam> = inheritedParam(s, owner, method, i, node.kind);
		if (found == null) return;
		if (!typeUsableFrom(s, found.text, found.file)) return;
		final at: Int = node.children.length > 0 ? LiteralInfer.insertPoint(node, node.children[0], source) : span.to;
		if (at >= 0) edits.push({ span: new Span(at, at), text: ':${found.text}' });
	}

	/** The innermost indexed type declaration of this file whose span contains `span`, or null. */
	private static function enclosingType(owners: Array<TypeDeclInfo>, span: Null<Span>): Null<TypeDeclInfo> {
		final s: Null<Span> = span;
		if (s == null) return null;
		var best: Null<TypeDeclInfo> = null;
		for (t in owners) if (t.span.from <= s.from && s.to <= t.span.to) {
			final b: Null<TypeDeclInfo> = best;
			if (b == null || t.span.from >= b.span.from) best = t;
		}
		return best;
	}

	/**
	 * The type source written for parameter `paramIndex` of `method` by the transitive supertype /
	 * interface closure of `owner`, or null when no declaring type states one UNAMBIGUOUSLY. A type
	 * that declares a member of that name but cannot yield a matching typed parameter aborts the
	 * whole lookup rather than being skipped: it is evidence the position is not what this pass
	 * assumes.
	 */
	private static function inheritedParam(
		s: InheritedSeams, owner: TypeDeclInfo, method: String, paramIndex: Int, paramKind: String
	): Null<InheritedParam> {
		final queue: Array<String> = owner.supertypes.concat(owner.interfaces);
		final seen: Array<String> = [owner.name];
		var found: Null<InheritedParam> = null;
		var at: Int = 0;
		while (at < queue.length) {
			final name: String = queue[at++];
			if (seen.contains(name)) continue;
			seen.push(name);
			// A generic declaring type states its members with its OWN type parameters, which the
			// implementation may bind to anything -- copying `T` verbatim never compiles. Refusing the
			// whole lookup (not just this candidate) keeps the answer conservative.
			for (fi in s.idx.refs.declaringFiles(name)) for (t in fi.types) if (t.name == name) {
				for (sup in t.supertypes.concat(t.interfaces)) queue.push(sup);
				if (!t.members.exists(m -> m.name == method)) continue;
				if (t.typeParamArity != 0) return null;
				final src: Null<String> = s.idx.sourceOf(fi.file);
				if (src == null) return null;
				final text: Null<String> = declaredParamType(s, src, t.span, method, paramIndex, paramKind);
				if (text == null) return null;
				final prev: Null<InheritedParam> = found;
				if (prev != null && prev.text != text) return null;
				found = { text: text, file: fi.file };
			}
		}
		return found;
	}

	/**
	 * The verbatim `:Type` source of the `paramIndex`-th parameter of `method` declared inside
	 * `typeSpan` of `src`, or null when the method node, the position, the optionality
	 * (`paramKind`) or the annotation itself is not there.
	 */
	private static function declaredParamType(
		s: InheritedSeams, src: String, typeSpan: Span, method: String, paramIndex: Int, paramKind: String
	): Null<String> {
		final provider: Null<TypeInfoProvider> = s.plugin is TypeInfoProvider ? cast s.plugin : null;
		if (provider == null) return null;
		final tree: Null<QueryNode> = CheckScan.parseOrNull(s.plugin, src);
		if (tree == null) return null;
		final fn: Null<QueryNode> = memberNamed(tree, typeSpan, method, s.functions);
		if (fn == null) return null;
		final own: Array<QueryNode> = [for (c in fn.children) if (s.params.contains(c.kind)) c];
		if (paramIndex >= own.length || own[paramIndex].kind != paramKind) return null;
		final span: Null<Span> = own[paramIndex].span;
		return span == null ? null : provider.declaredTypeSources(src)[span.from];
	}

	/**
	 * The function node named `method` inside `typeSpan` — located by span containment rather than
	 * by a type-declaration kind, so no extra grammar seam is needed. A node that is itself a
	 * parameter host is the only shape searched, and a local function / lambda never carries a
	 * member kind, so nesting cannot produce a false hit.
	 */
	private static function memberNamed(node: QueryNode, typeSpan: Span, method: String, functions: Array<String>): Null<QueryNode> {
		final span: Null<Span> = node.span;
		if (functions.contains(node.kind) && node.name == method && span != null && span.from >= typeSpan.from && span.to <= typeSpan.to)
			return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = memberNamed(c, typeSpan, method, functions);
			if (hit != null) return hit;
		}
		return null;
	}

	/**
	 * Whether `typeText` can be written VERBATIM in the file being fixed and MEAN THERE WHAT IT
	 * MEANS in `declFile`. Both halves matter: a name that merely resolves on both sides can still
	 * resolve to two DIFFERENT types (`import a.Payload` here, `import b.Payload` in the interface),
	 * and Haxe rejects the resulting override with a type mismatch.
	 *
	 * Per nominal, in order:
	 *
	 * - one of `AMBIENT_TYPES` → yes, it means the same thing in every module;
	 * - brought in by a `#if`-guarded import on EITHER side → no: `ImportInfo.guarded` marks an
	 *   import whose presence is branch-dependent while the index is branch-blind, so the name
	 *   would not resolve in the other configuration;
	 * - resolvable from BOTH files to exactly one declaration each, and it is the SAME declaration
	 *   (same file, same span) → yes;
	 * - resolvable from neither (a type the index does not model at all — the standard library is
	 *   normally absent) AND both files carry the identical plain `import` path for the name → yes;
	 * - anything else → no. That includes a name resolvable on one side only (it would need an
	 *   import this pass does not add), an ambiguous simple name, and a type declared in a file the
	 *   index SKIPPED, which is indistinguishable from an unknown one.
	 */
	private static function typeUsableFrom(s: InheritedSeams, typeText: String, declFile: String): Bool {
		final here: Null<FileInfo> = s.idx.fileInfo(s.file);
		final there: Null<FileInfo> = s.idx.fileInfo(declFile);
		if (here == null || there == null) return false;
		for (n in nominalsOf(typeText)) if (!AMBIENT_TYPES.contains(n)) {
			if (guardedImportOf(here, n) || guardedImportOf(there, n)) return false;
			final mine: Array<{ file: FileInfo, type: TypeDeclInfo }> = s.idx.resolveTypeRefsFrom(n, s.file);
			final theirs: Array<{ file: FileInfo, type: TypeDeclInfo }> = s.idx.resolveTypeRefsFrom(n, declFile);
			if (mine.length == 1 && theirs.length == 1) {
				if (mine[0].file.file != theirs[0].file.file || mine[0].type.span.from != theirs[0].type.span.from) return false;
				continue;
			}
			if (mine.length != 0 || theirs.length != 0) return false;
			final path: Null<String> = plainImportPathOf(here, n);
			if (path == null || path != plainImportPathOf(there, n)) return false;
		}
		return true;
	}

	/** Whether `fi` names `simple` in an import / using path's last segment, or binds it as an import alias. */
	private static function plainImportPathOf(fi: FileInfo, simple: String): Null<String> {
		var found: Null<String> = null;
		for (imp in fi.imports) if (!imp.guarded && imp.kind == ImportKind.Import) {
			final dot: Int = imp.raw.lastIndexOf('.');
			if ((dot < 0 ? imp.raw : imp.raw.substr(dot + 1)) != simple) continue;
			if (found != null && found != imp.raw) return null;
			found = imp.raw;
		}
		return found;
	}

	/**
	 * Whether `fi` brings `simple` into scope only under a conditional-compilation guard — an
	 * `ImportInfo.guarded` import (or an alias binding the name). The reference index is branch-blind,
	 * so such an import reads as unconditional; copying a type that rests on it emits a name that does
	 * not resolve in the other configuration.
	 */
	private static function guardedImportOf(fi: FileInfo, simple: String): Bool {
		for (imp in fi.imports) if (imp.guarded) switch imp.kind {
			case ImportKind.Import, ImportKind.Using:
				final dot: Int = imp.raw.lastIndexOf('.');
				if ((dot < 0 ? imp.raw : imp.raw.substr(dot + 1)) == simple) return true;
			case ImportKind.Alias:
				if (imp.alias == simple) return true;
			case ImportKind.Wild:
				return true;
		}
		return false;
	}

	/**
	 * The distinct SIMPLE nominal names a written type source mentions — `Null<pkg.Box<Int>>` →
	 * `Null`, `Box`, `Int`. Identifier runs are split on every other character (so generics,
	 * function arrows and anonymous-structure punctuation all fall away), each run is reduced to
	 * its last dotted segment, and a run that does not start upper-case (a package segment, an
	 * anonymous field name) is dropped.
	 *
	 * A type PARAMETER is NOT distinguishable here — `T` scans exactly like a nominal — which is
	 * why the generic case is refused one level up, on the declaring type's `typeParamArity`,
	 * rather than left to `typeUsableFrom`.
	 */
	private static function nominalsOf(typeText: String): Array<String> {
		final out: Array<String> = [];
		var i: Int = 0;
		while (i < typeText.length) {
			if (!isNominalPart(typeText.fastCodeAt(i))) {
				i++;
				continue;
			}
			final start: Int = i;
			while (i < typeText.length && isNominalPart(typeText.fastCodeAt(i))) i++;
			final token: String = typeText.substring(start, i);
			final dot: Int = token.lastIndexOf('.');
			final simple: String = dot < 0 ? token : token.substr(dot + 1);
			final head: Int = simple.fastCodeAt(0);
			if (head >= 'A'.code && head <= 'Z'.code && !out.contains(simple)) out.push(simple);
		}
		return out;
	}

	/**
	 * The initializer pass of `fix()`: for each flagged field / parameter whose
	 * initializer's type is statically certain, push a `:T` annotation edit.
	 * Return-type violations key the whole function and are absent from the
	 * field/param index, so they fall through to the Void pass.
	 */
	private static function collectInitializerEdits(
		tree: QueryNode, source: String, violations: Array<Violation>, shape: RefShape, plugin: GrammarPlugin, fixable: Array<String>,
		edits: Array<{ span: Span, text: String }>
	): Void {
		final byKey: Map<String, QueryNode> = [];
		MemberKinds.indexNodesByKind(tree, fixable, byKey);
		// A cast target lookup costs a SECOND full parse of the file (`castTargetSources`),
		// so compute it lazily and cache it — a fix whose violations key nothing into `byKey`,
		// or whose initializers are never casts, never pays for it.
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		var castTargetsCache: Null<Map<Int, String>> = null;
		function castTargets(): Map<Int, String> {
			final existing: Null<Map<Int, String>> = castTargetsCache;
			if (existing != null) return existing;
			final p: Null<TypeInfoProvider> = provider;
			final computed: Map<Int, String> = p != null ? p.castTargetSources(source) : [];
			castTargetsCache = computed;
			return computed;
		}
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null || node.children.length == 0) continue;
			final typeSource: Null<String> = LiteralInfer.inferType(node.children[0], source, shape, castTargets);
			if (typeSource == null) continue;
			final at: Int = LiteralInfer.insertPoint(node, node.children[0], source);
			if (at >= 0) edits.push({ span: new Span(at, at), text: ':$typeSource' });
		}
	}

}

/**
 * One inherited parameter annotation: the VERBATIM type source `text` written for the position,
 * and the `file` of the supertype / interface that wrote it — the second half is what
 * `ExplicitType.typeUsableFrom` needs to tell an ambient top-level name from one that only
 * resolved because the DECLARING file imported it.
 */
private typedef InheritedParam = {
	final text: String;
	final file: String;
};

/**
 * The read-only context `ExplicitType.returnEdit` needs per finding: the `source` and `file`
 * being fixed (the display server addresses a POSITION IN A FILE), the body-marker kinds, the
 * violation spans this call owns, the per-file type `printer`, and the `oracle` itself.
 */
private typedef ReturnSeams = {
	final source: String;
	final file: String;
	final bodies: Array<String>;
	final flagged: Map<String, Bool>;
	final printer: TypeRefPrinter;
	final oracle: TypeOracle;

	/**
	 * The source's lexically-scanned non-code regions, hoisted once per file — the grammar's own
	 * answer (`GrammarPlugin.lexicalRegions`), carried here rather than re-derived per member.
	 */
	final regions: Array<LexRegion>;
};

/**
 * The read-only context `ExplicitType.collectInheritedParamEdits` threads through its helpers: the
 * resolving `idx`, the `plugin` that parses a declaring file, the `file` being fixed (the
 * resolution origin for every copied type reference), and the member / parameter kind seams.
 */
private typedef InheritedSeams = {
	final idx: SymbolIndex;
	final plugin: GrammarPlugin;
	final file: String;
	final functions: Array<String>;
	final params: Array<String>;
};
