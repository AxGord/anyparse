package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * Flags `while (x.indexOf(S) != -1) x = x.replace(S, B);` — a search-and-replace
 * loop that is redundant BY CONSTRUCTION: `StringTools.replace` already replaces
 * EVERY occurrence of `S` in one call (verified live), so looping on `indexOf`
 * either does nothing extra or never stops. Three arms, the last of which splits
 * again once a LITERAL `B` decides what its parameter `S` cannot:
 *
 * - **Arm A — `S` and `B` are both LITERALS and `B` does NOT contain `S`.** After
 *   one `replace`, `x` has zero occurrences of `S` left, so the guard is false and
 *   the loop would have run at most once anyway. `Severity.Info`, with an autofix
 *   that collapses the whole loop to the single unconditional assignment
 *   `x = x.replace(S, B);` — sound even when the ORIGINAL string had zero
 *   occurrences of `S` to begin with, since `replace` on a no-match input returns
 *   the string unchanged.
 * - **Arm B — `S` and `B` are both LITERALS and `B` CONTAINS `S`.** Every
 *   replacement reinserts `S` into `x`, so the guard is true again on the next
 *   check — the loop is INFINITE for any input that ever contains `S`. This is a
 *   real bug, not a style nit: `Severity.Warning`, report-only (there is no
 *   mechanical fix for "the author meant something else").
 * - **Arm C — at least one of `S` / `B` is a PARAMETER of an enclosing
 *   function.** `Severity.Info`, report-only; see its own section below. A PARAMETER `S`
 *   paired with a LITERAL `B` splits out of it into two decided sub-arms, since that
 *   literal settles the question with no knowledge of the caller.
 *
 * ## What is matched
 *
 * The guard accepts three spellings of "does `x` contain `S`": `x.indexOf(S) !=
 * -1`, its reversed operand order `-1 != x.indexOf(S)`, and `x.contains(S)`. Each
 * of `S` (the guard's `indexOf` / `contains` argument AND `replace`'s first
 * argument) and `B` (`replace`'s second argument) must be EITHER a plain string
 * literal (`StringFoldSupport.literalOf` — no interpolation) OR a bare identifier
 * bound to a PARAMETER of ANY function OR LAMBDA enclosing the loop (a
 * `RefShape.paramKinds` child of ANY `RefShape.functionKinds` /
 * `lambdaKinds` ancestor, NOT merely the nearest — a lambda's own parameters and
 * the enclosing METHOD's are equally caller-chosen). Anything else — a field
 * access, a call, an index access, a LOCAL `var`, an unresolvable identifier — is
 * not this pattern and is left alone. The two `S` positions must be the SAME
 * thing: equal literal content, or the same parameter binding; a literal /
 * parameter MIX across the two `S` positions is not a match. The receiver `x` must
 * be a single identifier — never `this.x` / `obj.x` / an index access — bound to
 * the SAME local/parameter declaration in the guard call, the `replace` call and
 * the assignment target (`TypeResolver.identBindingFrom`, so a same-named variable
 * from an unrelated scope never falsely qualifies), and that declaration must
 * carry an explicit `:String` annotation (`TypeInfoProvider.declaredTypes`) — an
 * untyped or non-`String` receiver is a silent miss, never a wrong flag.
 *
 * The loop body must be EXACTLY the one assignment statement — braced with a
 * single statement, or the bare unbraced form Haxe allows for a single-statement
 * `while`. Any additional statement (a second assignment, a `trace`, …) means the
 * loop is doing more than a redundant replace and is skipped entirely.
 *
 * ## Arm C — a parameter pair cannot be decided statically
 *
 * When either operand is a parameter, whether `B` contains `S` is a property of
 * the CALLER's arguments, not of this function: `replaceWord(line, 'a', 'aa')`
 * loops forever, `replaceWord(line, 'a', 'b')` returns. Both readings are live, so
 * the finding is `Severity.Info` and REPORT-ONLY — there is no arm-A collapse to
 * make (the loop is not provably redundant) and no arm-B certainty to claim. The
 * message names both operands' VERBATIM source text, so the reader decides. That
 * covers two parameters, and a LITERAL `S` with a PARAMETER `B` (`line.replace(' ',
 * sep)`) — there the literal says nothing about what the caller's `sep` contains.
 *
 * ## The literal-`B` hybrids — a PARAMETER `S`, and the literal decides
 *
 * The reverse mix is NOT undecidable, and reporting it in arm C's words produced
 * plain nonsense on `stripWord(line, word)` looping on `line.replace(word, '')`:
 * "potential infinite loop when '' contains word" — an empty literal contains no
 * non-empty word, and `replace(word, '')` REMOVES rather than reinserts. So a
 * literal `B` under a parameter `S` splits into two decided sub-arms:
 *
 * - **EMPTY literal `B`.** For every non-empty `S` one `replace` deletes ALL
 *   occurrences, the guard is false on the next check, and the loop is simply
 *   REDUNDANT — the message says exactly that and names the single call that does
 *   the same work. It stays REPORT-ONLY nonetheless: `indexOf('') == 0`, so on the
 *   degenerate `S == ''` the ORIGINAL loop spins forever while the collapsed form
 *   returns at once. That difference is a behaviour change, and an autofix may not
 *   silently trade a hang for a return — the caller may be relying on neither, but
 *   the rule cannot know, and a hang is the kind of bug a human must see. The
 *   message carries the degenerate hazard for the same reason. Being a REDUNDANCY
 *   verdict rather than a hazard one, it is also the single arm no dominating guard
 *   can suppress: no guard makes a redundant loop non-redundant, so `classifyArm`
 *   answers before the guard walk.
 * - **NON-EMPTY literal `B`.** The hazard is real but its condition is EXACT: the
 *   loop runs forever for precisely those `S` that occur in that literal, the equal
 *   `S == B` included. The message states that condition and quotes the literal
 *   verbatim instead of arm C's undecidable phrasing, and the whole dominating-guard
 *   apparatus below still applies — `if ('xy'.indexOf(word) != -1) return …;` does
 *   prove the loop terminates, and an `S == B` equality guard removes exactly one of
 *   the offending `S` values, which the caveat clause says in those terms.
 *
 * The one static proof that the hazard cannot happen is a CONTAINMENT test that
 * EXITS before the loop — `if (B.indexOf(S) != -1) return …;`, its reversed order,
 * or `if (B.contains(S)) return …;` (read by the same `matchGuard`, held to the
 * same operand identity), whose then-branch unconditionally exits
 * (`CheckScan.branchAlwaysExits`: a `return` / `throw` / `break` / `continue`, bare
 * or as the LAST statement of a block). That suppresses arm C — and the non-empty
 * literal-`B` hybrid — outright; the empty-literal one is never suppressed, its
 * redundancy verdict holding whatever any guard says.
 *
 * Such a guard must DOMINATE the loop, not merely precede it in the text: the walk
 * ascends from the `while` through the enclosing statement lists
 * (`ControlFlowSupport.blockKinds`) and considers only the PRECEDING SIBLINGS at
 * each level. A guard nested inside another `if`, in an `else` arm, in a loop or
 * `switch` body, inside a `#if` region (one `Conditional` node, not a statement
 * list — so it protects ONE target and would silence every other), or in a nested
 * function or lambda nothing calls, may never have run when the loop is reached and
 * proves nothing.
 *
 * An EQUALITY guard does NOT: `if (S == B) return …;` rules out only the
 * degenerate `B == S`, while every `B` that merely CONTAINS `S` still loops
 * forever. Such a guard reads like protection, which is precisely why the finding
 * survives it and the message says so. Arms A and B are untouched by either guard
 * — with two literals the verdict is already decided and needs no proof.
 *
 * ## Default OFF — opt-in
 *
 * A brand-new check ships `DefaultOff`: dropped from the default set and from a
 * bare `lint … --all` report until a project opts in via `apqlint.json`
 * (`"rules": { "redundant-replace-loop": { "enabled": true } }`), or an explicit
 * `--rule redundant-replace-loop` selects it (which bypasses enablement).
 *
 * ## Grammar-agnostic
 *
 * Driven by `whileStmtKind`, `notEqKind`, `callKind`, `fieldAccessKind`,
 * `identKind`, `assignKind`, `blockStmtKind`, `exprStatementKind`,
 * `unaryMinusKinds` and `numericLiteralKinds` (any unset, or the plugin's
 * `stringFoldSupport()` null, → the check is a no-op), plus `parenKind`
 * (optional, one guard-condition unwrap) and `opaqueKinds` to skip reification
 * subtrees.
 *
 * Two further seam groups are optional, and they fail in OPPOSITE directions.
 * `functionKinds` / `lambdaKinds` / `paramKinds` ENABLE arm C: with none of them a
 * parameter operand can never be recognised, so arm C is unreachable and the check
 * keeps its literals-only behaviour exactly as before parameters were admitted.
 * `ifStatementKinds`, `GrammarPlugin.controlFlowSupport()` and `eqKind` drive the
 * SUPPRESSION instead: leaving `ifStatementKinds` or the control-flow support unset
 * does not disable arm C, it disables the dominating-guard proof, so arm C then
 * reports strictly MORE; leaving `eqKind` unset only drops the message's
 * equality-guard caveat. Arms A / B are untouched by every seam in this paragraph.
 */
@:nullSafety(Strict)
final class RedundantReplaceLoop implements Check implements DefaultOff {

	/** This check's stable id — named once so the literal is not itself a repeated string. */
	private static inline final RULE_ID: String = 'redundant-replace-loop';

	/** A `while` node has exactly [condition, body] children. */
	private static inline final WHILE_CHILD_COUNT: Int = 2;

	/** A `!=` comparison node has exactly [left, right] children. */
	private static inline final COMPARISON_CHILD_COUNT: Int = 2;

	/** A unary-minus (`Neg`) node has exactly [operand] children. */
	private static inline final NEG_CHILD_COUNT: Int = 1;

	/** A plain assignment node has exactly [target, value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** `x.indexOf(S)` / `x.contains(S)`: callee + one argument. */
	private static inline final ONE_ARG_CALL_CHILD_COUNT: Int = 2;

	/** `x.replace(S, B)`: callee + two arguments. */
	private static inline final REPLACE_CALL_CHILD_COUNT: Int = 3;

	private static inline final SEARCH_METHOD: String = 'indexOf';
	private static inline final CONTAINS_METHOD: String = 'contains';
	private static inline final REPLACE_METHOD: String = 'replace';
	private static inline final STRING_TYPE: String = 'String';

	/** Longest literal excerpt echoed verbatim in a finding message before it is elided. */
	private static inline final EXCERPT_MAX: Int = 40;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a while (x.indexOf(S) != -1) x = x.replace(S, B); loop — replace() '
			+ 'already replaces every occurrence in one call; an undecidable PARAMETER pair is reported as a potential infinite loop, '
			+ 'while a PARAMETER S with a LITERAL B is decided by that literal: an empty one makes the loop merely redundant, a non-empty '
			+ 'one loops forever for exactly those S occurring in it';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final typed: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		if (typed == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			walk(tree, tree, entry.file, entry.source, declaredTypes, s, violations);
		}
		return violations;
	}

	/** Collapse each ARM-A (fixable) violation's whole `while` loop to its single body statement, verbatim. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final typed: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		if (typed == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final declaredTypes: Map<Int, String> = typed.declaredTypes(source);
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) wanted.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		fixWalk(tree, tree, source, declaredTypes, s, wanted, edits);
		return CanonicalEdit.dropContainedEdits(edits);
	}

	/** Bundle the required `RefShape` kinds + `StringFoldSupport`, or null when any is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final whileStmtKind: Null<String> = shape.whileStmtKind;
		if (whileStmtKind == null) return null;
		final notEqKind: Null<String> = shape.notEqKind;
		if (notEqKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final unaryMinusKinds: Array<String> = shape.unaryMinusKinds ?? [];
		if (unaryMinusKinds.length == 0) return null;
		final numericLiteralKinds: Array<String> = shape.numericLiteralKinds ?? [];
		if (numericLiteralKinds.length == 0) return null;
		final strings: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (strings == null) return null;
		// Optional, and in the SUPPRESSING direction: with no control-flow support no guard can be
		// read as exiting, so arm C reports strictly more rather than going silent.
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return {
			shape: shape,
			whileStmtKind: whileStmtKind,
			notEqKind: notEqKind,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			identKind: identKind,
			assignKind: assignKind,
			blockStmtKind: blockStmtKind,
			exprStmtKind: exprStmtKind,
			unaryMinusKinds: unaryMinusKinds,
			numericLiteralKinds: numericLiteralKinds,
			// A lambda's parameters are just as caller-chosen as a method's, so both host kinds
			// count as an enclosing scope a parameter operand may belong to. Which of those scopes
			// each reader admits differs: `operandOf` takes a parameter of ANY of them,
			// `dominatingGuards` reads only the innermost.
			fnKinds: (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []),
			paramKinds: shape.paramKinds ?? [],
			ifStatementKinds: shape.ifStatementKinds ?? [],
			flow: flow,
			blockKinds: flow == null ? [] : flow.blockKinds(),
			eqKind: shape.eqKind,
			parenKind: shape.parenKind,
			strings: strings,
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/** Descend `node`, flagging every qualifying `while` loop. A reification subtree (`opaqueKinds`) is skipped wholesale. */
	private static function walk(
		node: QueryNode, root: QueryNode, file: String, source: String, declaredTypes: Map<Int, String>, s: Seams, out: Array<Violation>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (node.kind == s.whileStmtKind) {
			final m: Null<Match> = matchWhile(node, root, source, declaredTypes, s);
			if (m != null) out.push(toViolation(file, m));
		}
		for (c in node.children) walk(c, root, file, source, declaredTypes, s, out);
	}

	/** Mirror of `walk` for the fix path: emit the collapse edit for each `wanted`, ARM-A loop. */
	private static function fixWalk(
		node: QueryNode, root: QueryNode, source: String, declaredTypes: Map<Int, String>, s: Seams, wanted: Array<String>,
		out: Array<{ span: Span, text: String }>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (node.kind == s.whileStmtKind) {
			final m: Null<Match> = matchWhile(node, root, source, declaredTypes, s);
			if (m != null && m.arm == Arm.A && wanted.contains('${m.whileSpan.from}:${m.whileSpan.to}'))
				out.push({ span: m.whileSpan, text: source.substring(m.stmtSpan.from, m.stmtSpan.to) });
		}
		for (c in node.children) fixWalk(c, root, source, declaredTypes, s, wanted, out);
	}

	/**
	 * If `whileNode` is a qualifying redundant-replace loop, its match (spans, arm, and the
	 * receiver/literal text for the message); else null. See the type doc for the full gate list.
	 */
	private static function matchWhile(
		whileNode: QueryNode, root: QueryNode, source: String, declaredTypes: Map<Int, String>, s: Seams
	): Null<Match> {
		if (whileNode.children.length != WHILE_CHILD_COUNT) return null;
		var cond: QueryNode = whileNode.children[0];
		if (s.parenKind != null && cond.kind == s.parenKind && cond.children.length == 1) cond = cond.children[0];
		final guard: Null<{ receiver: QueryNode, search: QueryNode }> = matchGuard(cond, source, s);
		if (guard == null) return null;
		final receiver: QueryNode = guard.receiver;
		if (receiver.kind != s.identKind) return null;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(receiver, root, s.shape);
		if (bindingFrom == null || declaredTypes[bindingFrom] != STRING_TYPE) return null;
		final whileSpan: Null<Span> = whileNode.span;
		if (whileSpan == null) return null;
		final fns: Array<QueryNode> = [];
		enclosingFunctions(root, whileSpan, s, fns);
		final search: Null<Operand> = operandOf(guard.search, root, fns, source, s);
		if (search == null) return null;

		final body: Null<BodyMatch> = matchBody(whileNode.children[1], root, fns, source, bindingFrom, search, s);
		if (body == null) return null;
		final replacement: Operand = body.replacement;
		final classified: Null<Classification> = classifyArm(search, replacement, fns, whileNode, root, source, s);
		return classified == null ? null : {
			whileSpan: whileSpan,
			stmtSpan: body.stmtSpan,
			arm: classified.arm,
			eqGuarded: classified.eqGuarded,
			receiverName: receiver.name ?? '',
			// The operand's OWN verbatim source (delimiters included for a literal), not a
			// hand-rewrapped `.content` — content may itself carry a quote character (`"'"`), and
			// rewrapping it in a hardcoded delimiter would mis-render (`':', '''`).
			searchSrc: search.src,
			replacementSrc: replacement.src
		};
	}

	/**
	 * The loop BODY's half of the match: `body` must be exactly one assignment `x = x.replace(S, B)`
	 * whose target and receiver are the SAME binding the guard tested (`bindingFrom`) and whose
	 * first argument is the same `S` (`sameOperand`). Returns that statement's span — arm A's
	 * replacement text — and the resolved `B`, or null when the body is anything else. Any
	 * additional statement means the loop is doing more than a redundant replace.
	 */
	private static function matchBody(
		body: QueryNode, root: QueryNode, fns: Array<QueryNode>, source: String, bindingFrom: Int, search: Operand, s: Seams
	): Null<BodyMatch> {
		final stmt: Null<QueryNode> = singleStatementOf(body, s);
		if (stmt == null || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != s.assignKind || assign.children.length != ASSIGN_CHILD_COUNT) return null;
		final target: QueryNode = assign.children[0];
		if (target.kind != s.identKind || TypeResolver.identBindingFrom(target, root, s.shape) != bindingFrom) return null;
		final value: QueryNode = assign.children[1];
		final replaceCall: Null<MethodCall> = methodCallParts(value, s);
		if (
			replaceCall == null || replaceCall.method != REPLACE_METHOD || value.children.length != REPLACE_CALL_CHILD_COUNT
			|| replaceCall.recv.kind != s.identKind || TypeResolver.identBindingFrom(replaceCall.recv, root, s.shape) != bindingFrom
		)
			return null;
		final replaceSearch: Null<Operand> = operandOf(value.children[1], root, fns, source, s);
		if (replaceSearch == null || !sameOperand(search, replaceSearch)) return null;
		final replacement: Null<Operand> = operandOf(value.children[2], root, fns, source, s);
		final stmtSpan: Null<Span> = stmt.span;
		return replacement == null || stmtSpan == null ? null : { stmtSpan: stmtSpan, replacement: replacement };
	}

	/**
	 * Which arm the matched loop falls in, or null when it must not be reported at all (arm C
	 * with a dominating containment guard). Two literals decide the outcome statically — arms
	 * A / B, byte-identical to the behaviour from before parameters were admitted as operands;
	 * anything else is arm C, where a containment test that exits before the loop is the one
	 * static proof that `B` never contains `S` whatever the caller passes, and an equality
	 * guard only sharpens the message. The two guard walks share ONE dominating-guard list.
	 *
	 * `fns` cannot actually be empty here on the arm-C path: a null `literal` comes only from
	 * `operandOf`'s parameter branch, which refuses outright when no enclosing function holds
	 * the binding as a parameter. Reaching the throw below would mean that invariant broke.
	 *
	 * PAST the two-literal return, a non-null `B` content means a PARAMETER `S` with a LITERAL
	 * `B` — the hybrid arms `CEmptyB` / `CLiteralB`, where the literal decides the verdict with
	 * no knowledge of the caller. The EMPTY one answers BEFORE the dominating-guard walk on
	 * purpose: its verdict is that the loop is REDUNDANT, which no guard can turn false, so
	 * there is nothing for a containment proof to suppress (and `''.indexOf(S) != -1` holds only
	 * for the degenerate empty `S` anyway). A non-empty literal keeps the full arm-C treatment —
	 * `if ('xy'.indexOf(word) != -1) return …;` really does prove the loop terminates.
	 *
	 * The DOMINANCE walk takes the INNERMOST enclosing function (`fns`' last element) — a guard
	 * outside a lambda may not have run when a loop inside it is reached — the opposite
	 * direction from the parameter test `operandOf` runs over the whole chain.
	 */
	private static function classifyArm(
		search: Operand, replacement: Operand, fns: Array<QueryNode>, whileNode: QueryNode, root: QueryNode, source: String, s: Seams
	): Null<Classification> {
		final searchContent: Null<String> = search.literal;
		final replacementContent: Null<String> = replacement.literal;
		if (searchContent != null && replacementContent != null)
			return { arm: replacementContent.indexOf(searchContent) == -1 ? Arm.A : Arm.B, eqGuarded: false };
		if (fns.length == 0)
			throw new Exception('$RULE_ID: arm C reached with no enclosing function — operandOf refuses a parameter operand without one');
		if (replacementContent == '') return { arm: Arm.CEmptyB, eqGuarded: false };
		final guards: Array<QueryNode> = dominatingGuards(fns[fns.length - 1], whileNode, s);
		if (guardsContainment(guards, fns, search, replacement, root, source, s)) return null;
		final eqGuarded: Bool = guardsEquality(guards, fns, search, replacement, root, source, s);
		return { arm: replacementContent == null ? Arm.C : Arm.CLiteralB, eqGuarded: eqGuarded };
	}

	/**
	 * The guard's receiver + search argument when `cond` is one of the three accepted
	 * shapes (`x.indexOf(S) != -1`, `-1 != x.indexOf(S)`, `x.contains(S)`), else null.
	 */
	private static function matchGuard(cond: QueryNode, source: String, s: Seams): Null<{ receiver: QueryNode, search: QueryNode }> {
		if (cond.kind == s.notEqKind && cond.children.length == COMPARISON_CHILD_COUNT) {
			final left: QueryNode = cond.children[0];
			final right: QueryNode = cond.children[1];
			final leftCall: Null<MethodCall> = indexOfCallParts(left, s);
			if (leftCall != null && isNegativeOneLiteral(right, source, s)) return { receiver: leftCall.recv, search: left.children[1] };
			final rightCall: Null<MethodCall> = indexOfCallParts(right, s);
			return rightCall != null && isNegativeOneLiteral(left, source, s)
				? { receiver: rightCall.recv, search: right.children[1] }
				: null;
		}
		final call: Null<MethodCall> = methodCallParts(cond, s);
		return call != null && call.method == CONTAINS_METHOD && cond.children.length == ONE_ARG_CALL_CHILD_COUNT ? {
			receiver: call.recv,
			search: cond.children[1]
		} : null;
	}

	/**
	 * The `S` / `B` operand `node` denotes, or null when it is neither accepted shape. A plain
	 * string literal (`StringFoldSupport.literalOf`, which answers null for an interpolated one)
	 * carries its content; a bare identifier carries its binding offset, but ONLY when that binding
	 * is a PARAMETER of one of `fns`, the functions and lambdas enclosing the loop. A field access,
	 * a call, an index access, a LOCAL `var` and an unresolvable identifier all answer null — the
	 * loop is then not this pattern and is left alone, exactly as before parameters were admitted.
	 */
	private static function operandOf(node: QueryNode, root: QueryNode, fns: Array<QueryNode>, source: String, s: Seams): Null<Operand> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final src: String = source.substring(span.from, span.to);
		final literal: Null<StringLiteral> = s.strings.literalOf(node, source);
		if (literal != null) return { literal: literal.content, paramBindingFrom: null, src: src };
		if (node.kind != s.identKind || fns.length == 0) return null;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(node, root, s.shape);
		return bindingFrom == null || !isParameterOfAny(fns, bindingFrom, s)
			? null
			: { literal: null, paramBindingFrom: bindingFrom, src: src };
	}

	/**
	 * Whether the binding at `bindingFrom` is a parameter of ANY of `fns` — the innermost function or
	 * lambda enclosing the loop, or any scope above it. A parameter of an OUTER scope is exactly as
	 * caller-chosen as the innermost one's, which is what arm C is about: a loop inside a lambda whose
	 * `S` / `B` are the enclosing METHOD's parameters is the same hazard as one reading the lambda's
	 * own. Deliberately the WIDEST reading, the opposite direction from `dominatingGuards`.
	 */
	private static function isParameterOfAny(fns: Array<QueryNode>, bindingFrom: Int, s: Seams): Bool {
		return fns.exists(fn -> isParameterOf(fn, bindingFrom, s));
	}

	/** Whether the binding at `bindingFrom` is one of `fn`'s own parameter declarations (`Seams.paramKinds`). */
	private static function isParameterOf(fn: QueryNode, bindingFrom: Int, s: Seams): Bool {
		for (child in fn.children) if (s.paramKinds.contains(child.kind)) {
			final span: Null<Span> = child.span;
			if (span != null && bindingFrom >= span.from && bindingFrom < span.to) return true;
		}
		return false;
	}

	/** Whether two operands denote the SAME thing — equal literal content, or the same parameter binding. A literal / parameter mix never matches. */
	private static function sameOperand(a: Operand, b: Operand): Bool {
		final literal: Null<String> = a.literal;
		if (literal != null) return literal == b.literal;
		final bindingFrom: Null<Int> = a.paramBindingFrom;
		return bindingFrom != null && bindingFrom == b.paramBindingFrom;
	}

	/**
	 * Push onto `out` EVERY function or LAMBDA (`Seams.fnKinds`) whose span contains `target`,
	 * outermost first and the INNERMOST one last; empty when the loop sits outside any (or the
	 * grammar names no function / lambda kinds — arm C is then unreachable and the check keeps its
	 * literals-only behaviour).
	 *
	 * Its two readers want OPPOSITE ends of the chain, which is why it hands over the whole thing
	 * rather than one node. The PARAMETER test (`isParameterOfAny`) scans ALL of it: a parameter of
	 * any enclosing scope is caller-chosen, so a loop inside a lambda reading the enclosing METHOD's
	 * parameters is arm C just as much as one reading the lambda's own. The DOMINANCE walk
	 * (`dominatingGuards`) takes only the LAST element: a guard outside a lambda may not have run
	 * when a loop inside it is reached, so nothing above the innermost function may be read as
	 * proof. Narrowing the chain to one node for both is what silently broke the first reader.
	 */
	private static function enclosingFunctions(node: QueryNode, target: Span, s: Seams, out: Array<QueryNode>): Void {
		final span: Null<Span> = node.span;
		if (span != null && (span.from > target.from || span.to < target.to)) return;
		if (s.fnKinds.contains(node.kind)) out.push(node);
		for (child in node.children) enclosingFunctions(child, target, s, out);
	}

	/**
	 * Whether any of the loop's DOMINATING `guards` tests containment of `search` in `replacement`
	 * — `B.indexOf(S) != -1` / `-1 != B.indexOf(S)` / `B.contains(S)`, the same three spellings
	 * `matchGuard` reads for the loop's own condition, held to the same operand identity. Every
	 * path that reaches the loop ran such a guard and did not take its exit, so the guard held AT
	 * THE POINT IT RAN and arm C has nothing to report.
	 *
	 * That is not the same as holding AT THE LOOP: nothing here scans for a write to `B` or `S`
	 * between the two, so `if (b.indexOf(s) != -1) return x; b = b + s; while (…)` is suppressed
	 * even though the loop is by then infinite. Deliberately not fixed — the whole arm is a
	 * report-only `Info`, so the gap costs a MISSED report, never a wrong one, and a reassignment
	 * scan is more machinery than that is worth.
	 */
	private static function guardsContainment(
		guards: Array<QueryNode>, fns: Array<QueryNode>, search: Operand, replacement: Operand, root: QueryNode, source: String, s: Seams
	): Bool {
		for (cond in guards) {
			final guard: Null<{ receiver: QueryNode, search: QueryNode }> = matchGuard(cond, source, s);
			if (guard == null) continue;
			final receiver: Null<Operand> = operandOf(guard.receiver, root, fns, source, s);
			final searched: Null<Operand> = operandOf(guard.search, root, fns, source, s);
			if (receiver != null && searched != null && sameOperand(receiver, replacement) && sameOperand(searched, search)) return true;
		}
		return false;
	}

	/**
	 * Whether any of the loop's DOMINATING `guards` tests `S == B` (either operand order). Such a
	 * guard is INSUFFICIENT — it rules out only the degenerate `B == S`, never the `B` that merely
	 * CONTAINS `S` — so it never suppresses the finding; it only sharpens the message.
	 */
	private static function guardsEquality(
		guards: Array<QueryNode>, fns: Array<QueryNode>, search: Operand, replacement: Operand, root: QueryNode, source: String, s: Seams
	): Bool {
		final eqKind: Null<String> = s.eqKind;
		if (eqKind == null) return false;
		for (cond in guards) if (cond.kind == eqKind && cond.children.length == COMPARISON_CHILD_COUNT) {
			final left: Null<Operand> = operandOf(cond.children[0], root, fns, source, s);
			final right: Null<Operand> = operandOf(cond.children[1], root, fns, source, s);
			if (left == null || right == null) continue;
			if (
				(sameOperand(left, search) && sameOperand(right, replacement))
				|| (sameOperand(left, replacement) && sameOperand(right, search))
			)
				return true;
		}
		return false;
	}

	/**
	 * The CONDITIONS of every `if` that DOMINATES `whileNode` inside `fn`: the walk ascends from
	 * the loop through the enclosing statement lists (`Seams.blockKinds`, the grammar's
	 * `ControlFlowSupport`) and at each level reads only the PRECEDING SIBLINGS of the node it
	 * came up through, keeping those whose then-branch unconditionally exits. Preceding IN THE
	 * TEXT is not enough — a guard nested inside another `if`, in an `else` arm, in a loop or
	 * `switch` body, inside a `#if` region (which projects as one `Conditional` node, never a
	 * statement list), or in a nested function or lambda nothing calls, may not have run at all
	 * when the loop is reached. Empty when the grammar exposes no control-flow support, which
	 * only loses the suppression.
	 */
	private static function dominatingGuards(fn: QueryNode, whileNode: QueryNode, s: Seams): Array<QueryNode> {
		final flow: Null<ControlFlowSupport> = s.flow;
		if (flow == null) return [];
		final path: Null<Array<QueryNode>> = TreePath.pathTo(fn, whileNode);
		if (path == null) return [];
		final out: Array<QueryNode> = [];
		for (i in 0...path.length - 1) {
			final host: QueryNode = path[i];
			if (!s.blockKinds.contains(host.kind)) continue;
			for (sibling in host.children) {
				if (sibling == path[i + 1]) break;
				final cond: Null<QueryNode> = exitGuardCondition(sibling, flow, s);
				if (cond != null) out.push(cond);
			}
		}
		return out;
	}


	/**
	 * `guard`'s condition when it is an `if` whose then-branch unconditionally exits — a `return`
	 * (valued or bare), a `throw`, a `break` or a `continue`, bare or as the LAST statement of a
	 * block (`CheckScan.branchAlwaysExits`, the shared reading `redundant-else` de-nests on) —
	 * else null. One optional paren layer is unwrapped, as in the loop's own condition.
	 */
	private static function exitGuardCondition(guard: QueryNode, flow: ControlFlowSupport, s: Seams): Null<QueryNode> {
		if (!s.ifStatementKinds.contains(guard.kind) || guard.children.length < COMPARISON_CHILD_COUNT) return null;
		if (!CheckScan.branchAlwaysExits(guard.children[1], flow)) return null;
		final cond: QueryNode = guard.children[0];
		return s.parenKind != null && cond.kind == s.parenKind && cond.children.length == 1 ? cond.children[0] : cond;
	}

	/** `x.METHOD(...)` destructured into its receiver + method name, or null when `node` is not a field-access call. */
	private static function methodCallParts(node: QueryNode, s: Seams): Null<MethodCall> {
		if (node.kind != s.callKind || node.children.length < 1) return null;
		final callee: QueryNode = node.children[0];
		final method: Null<String> = callee.name;
		return callee.kind != s.fieldAccessKind || method == null || callee.children.length != 1
			? null
			: { recv: callee.children[0], method: method };
	}

	/** `x.indexOf(S)` destructured into its receiver, or null when `node` is not exactly that one-argument call. */
	private static function indexOfCallParts(node: QueryNode, s: Seams): Null<MethodCall> {
		final parts: Null<MethodCall> = methodCallParts(node, s);
		return parts != null && parts.method == SEARCH_METHOD && node.children.length == ONE_ARG_CALL_CHILD_COUNT ? parts : null;
	}

	/** Whether `node` is a unary-minus wrapping the integer literal `1` — the `-1` "not found" sentinel. */
	private static function isNegativeOneLiteral(node: QueryNode, source: String, s: Seams): Bool {
		if (!s.unaryMinusKinds.contains(node.kind) || node.children.length != NEG_CHILD_COUNT) return false;
		final inner: QueryNode = node.children[0];
		if (!s.numericLiteralKinds.contains(inner.kind)) return false;
		final span: Null<Span> = inner.span;
		return span != null && source.substring(span.from, span.to) == '1';
	}

	/** The loop body's single statement (a plain assignment expression statement), or null when the body is not exactly one. */
	private static function singleStatementOf(body: QueryNode, s: Seams): Null<QueryNode> {
		return if (body.kind == s.exprStmtKind)
			body
		else if (body.kind == s.blockStmtKind && body.children.length == 1 && body.children[0].kind == s.exprStmtKind)
			body.children[0]
		else
			null;
	}

	/**
	 * `m` as its `Violation`: `Info` for arm A (redundant, autofixable) and for every arm-C shape
	 * (a parameter operand, report-only), `Warning` for arm B (provably infinite, report-only).
	 * Switched exhaustively on the `enum abstract`, so a further arm is a compile error rather
	 * than silently landing in the `Info` branch.
	 */
	private static function toViolation(file: String, m: Match): Violation {
		final search: String = excerpt(m.searchSrc);
		final replacement: String = excerpt(m.replacementSrc);
		final severity: Severity = switch m.arm {
			case Arm.A, Arm.C, Arm.CEmptyB, Arm.CLiteralB: Severity.Info;
			case Arm.B: Severity.Warning;
		};
		final message: String = switch m.arm {
			case Arm.A:
				'this while (${m.receiverName}.indexOf($search) != -1) loop runs at most once — replace() already replaces every '
					+ 'occurrence; collapses to ${m.receiverName} = ${m.receiverName}.replace($search, $replacement);';
			case Arm.B:
				'this loop never terminates for any ${m.receiverName} containing $search — replace($search, $replacement'
					+ ') reintroduces it every time, since $replacement itself contains $search';
			case Arm.C: armCMessage(m, search, replacement);
			case Arm.CEmptyB: emptyReplacementMessage(m, search, replacement);
			case Arm.CLiteralB: literalReplacementMessage(m, search, replacement);
		};
		return {
			file: file,
			span: m.whileSpan,
			rule: RULE_ID,
			severity: severity,
			message: message
		};
	}

	/**
	 * Arm C's message: the hazard first (`potential infinite loop when <B> contains <S>`), then the
	 * equality-guard caveat when the enclosing function carries one — `S == B` is not containment,
	 * so the guard reads like protection while covering only the degenerate case.
	 */
	private static function armCMessage(m: Match, search: String, replacement: String): String {
		final head: String = 'potential infinite loop when $replacement contains $search — replace($search, $replacement) reinserts $search'
			+ ' on every pass, so the guard never goes false';
		return m.eqGuarded
			? '$head; the $search == $replacement guard does not cover containment — a $replacement that merely CONTAINS $search'
				+ ' still loops forever'
			: head;
	}

	/**
	 * The EMPTY-literal `B` message: `replace(S, '')` REMOVES every occurrence in one call, so the
	 * loop adds nothing over a single unconditional assignment — the finding is REDUNDANCY, never
	 * the infinite loop arm C claims (an empty literal cannot contain a non-empty `S`, and nothing
	 * is reinserted). The degenerate note is why it is still report-only rather than arm A's
	 * autofix: `indexOf('') == 0`, so on an empty `S` the ORIGINAL loop hangs where the collapsed
	 * form returns, and no rewrite may silently trade a hang for a return.
	 */
	private static function emptyReplacementMessage(m: Match, search: String, replacement: String): String {
		return 'this while (${m.receiverName}.indexOf($search) != -1) loop is redundant for any non-empty $search — replace($search, '
			+ '$replacement) REMOVES every occurrence in one call, so one ${m.receiverName} = ${m.receiverName}.replace($search, '
			+ '$replacement); does the same work; not autofixed: the ORIGINAL loop spins forever on a degenerate $search == $replacement'
			+ ' (indexOf($replacement) == 0), and collapsing it would silently turn that hang into a return';
	}

	/**
	 * The NON-empty-literal `B` message: the hazard is real but its condition is exact — the loop
	 * runs forever for precisely those `S` that occur in the literal, equality included — so the
	 * message states THAT rather than arm C's undecidable "when `B` contains `S`", and names the
	 * literal verbatim so the reader can check the condition by eye. The equality-guard caveat is
	 * sharper here for the same reason: the guard removes exactly one of those `S`.
	 */
	private static function literalReplacementMessage(m: Match, search: String, replacement: String): String {
		final head: String = 'potential infinite loop when $search occurs in $replacement — replace($search, $replacement) writes '
			+ '$replacement back into ${m.receiverName} on every pass, so the loop runs forever for exactly those $search'
			+ ' that are a substring of $replacement (the equal $search == $replacement included)';
		return m.eqGuarded
			? '$head; the $search == $replacement guard rules out only the equal case — a shorter $search that still occurs in '
				+ '$replacement loops forever'
			: head;
	}

	/**
	 * `text` — one operand's verbatim source: a literal WITH its delimiters, or, on arm C, the bare
	 * parameter name — capped to `EXCERPT_MAX` characters (an ellipsis marks the cut) for a
	 * finding message.
	 */
	private static function excerpt(text: String): String {
		return text.length <= EXCERPT_MAX ? text : '${text.substring(0, EXCERPT_MAX)}…';
	}

}

/** The resolved seams `RedundantReplaceLoop` reads in both `run` and `fix`. */
private typedef Seams = {
	final shape: RefShape;
	final whileStmtKind: String;
	final notEqKind: String;
	final callKind: String;
	final fieldAccessKind: String;
	final identKind: String;
	final assignKind: String;
	final blockStmtKind: String;
	final exprStmtKind: String;
	final unaryMinusKinds: Array<String>;
	final numericLiteralKinds: Array<String>;
	final fnKinds: Array<String>;
	final paramKinds: Array<String>;
	final ifStatementKinds: Array<String>;
	final flow: Null<ControlFlowSupport>;
	final blockKinds: Array<String>;
	final eqKind: Null<String>;
	final parenKind: Null<String>;
	final strings: StringFoldSupport;
	final opaqueKinds: Array<String>;
};

/** A destructured `x.method(...)` call: its receiver node and method name. */
private typedef MethodCall = {
	final recv: QueryNode;
	final method: String;
};

/**
 * One resolved `S` / `B` operand: EITHER a plain string literal, OR a bare identifier bound to a
 * PARAMETER of a function or lambda enclosing the loop. Exactly one of the two fields is non-null; `src` is the
 * operand's verbatim source text, which a finding message echoes (never a re-wrapped `.content`).
 */
private typedef Operand = {

	/** The literal content when the operand is a plain string literal, else null. */
	final literal: Null<String>;

	/** The START OFFSET of the parameter declaration this operand is bound to, else null. */
	final paramBindingFrom: Null<Int>;

	/** The operand's verbatim source text, delimiters included. */
	final src: String;

};

/**
 * Which arm a matched loop falls in — the outcomes the type doc describes.
 */
private enum abstract Arm(Int) {

	/** Both operands are literals and `B` does not contain `S`: redundant, `Info`, autofixed. */
	final A = 0;

	/** Both operands are literals and `B` contains `S`: provably infinite, `Warning`, report-only. */
	final B = 1;

	/** Neither literal-`B` hybrid: the pair is undecidable here, infinite for some argument, `Info`, report-only. */
	final C = 2;

	/** A PARAMETER `S` with the EMPTY literal `B`: redundant for every non-empty `S`, `Info`, report-only. */
	final CEmptyB = 3;

	/** A PARAMETER `S` with a NON-EMPTY literal `B`: infinite for exactly those `S` occurring in `B`, `Info`, report-only. */
	final CLiteralB = 4;

}

/**
 * A matched redundant-replace loop: both spans, which arm it is, whether an (insufficient)
 * equality guard precedes it, and the verbatim text the message echoes.
 */
private typedef Match = {

	/** The whole `while` statement — the finding's span, and what arm A's fix replaces. */
	final whileSpan: Span;

	/** The loop body's single assignment statement — arm A's replacement text, copied verbatim. */
	final stmtSpan: Span;

	/** Which of the three arms this loop falls in. */
	final arm: Arm;

	/** Arm C only: whether a dominating `S == B` guard precedes the loop, which adds the message's caveat clause. */
	final eqGuarded: Bool;

	/** The receiver identifier's name, echoed in the message. */
	final receiverName: String;

	/** The `S` operand's verbatim source (a literal with its delimiters, or a bare parameter name). */
	final searchSrc: String;

	/** The `B` operand's verbatim source (a literal with its delimiters, or a bare parameter name). */
	final replacementSrc: String;

};

/** `matchBody`'s result: the body statement's span (arm A's replacement text) and the resolved `B` operand. */
private typedef BodyMatch = {

	/** The loop body's single assignment statement — arm A's replacement text, copied verbatim. */
	final stmtSpan: Span;

	/** The resolved `B` operand — `replace`'s second argument. */
	final replacement: Operand;

};

/** `classifyArm`'s verdict: the arm a matched loop falls in, plus arm C's equality-guard caveat flag. */
private typedef Classification = {

	/** Which of the three arms the loop falls in. */
	final arm: Arm;

	/** Whether a dominating `S == B` guard precedes the loop (arm C's message caveat); always false for arms A / B. */
	final eqGuarded: Bool;

};
