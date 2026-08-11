package anyparse.check;

import anyparse.check.CasePatternScan.CaseRunContext;
import anyparse.check.CasePatternScan.CaseSeams;
import anyparse.check.CasePatternScan.PatternBinder;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a case-pattern BINDER that IS a whole pattern, binds a name already declared in scope, and
 * then never reads it — `case closeAction:` written where `closeAction` is a field, a parameter or
 * a local. `Warning`, REPORT-ONLY.
 *
 * ## The mistake it names
 *
 * Haxe resolves a bare lowercase identifier in a pattern as a CAPTURE. It does not compare the
 * subject against a same-named binding in scope, and it does not warn that it declined to:
 *
 * ```haxe
 * var closeAction:String = "expected";
 * for (v in ["expected", "OTHER", "zzz"]) switch v {
 *     case closeAction: trace('matched: $v');  // matches ALL THREE
 * }
 * ```
 *
 * (verified on `--interp`; the arm fires for every value). Only an enum / enum-abstract value or a
 * `static inline` field resolves as a pattern CONSTANT — an ordinary field never does. So the
 * author who wrote the name of something in scope almost always meant a comparison, and got a
 * catch-all that shadows it. The fix is theirs to choose — an `==` test, a case guard
 * (`case v if (v == closeAction):`), or a genuine capture under a name that is free — which is why
 * this check offers none.
 *
 * ## Why it must exist for `unused-case-binder` to keep its fix
 *
 * That rule sees the same arm as an unread binder and rewrites it to `case _:`, which is
 * behaviour-preserving and erases the only surviving evidence of the mistake — after which
 * `unnecessary-switch` is entitled to delete the husk, and the intent is gone from the file. It now
 * asks `CasePatternScan.shadowedDeclaration` first and REFUSES the rewrite for exactly the shape
 * reported here, leaving the arm for a human. The two share one predicate on purpose: a gate that
 * disagreed with the report would either hide findings or freeze fixes.
 *
 * ## What is flagged
 *
 * A BARE binder (`CasePatternScan.binders` with `bare` set — a `var x` capture and an `=`-capture
 * head are binders by SYNTAX, so no reader could have meant a comparison there) that is the WHOLE
 * pattern, whose name is not a `declaredConstantNames` member (that set is what a bare identifier
 * must avoid to read as a binder at all), which the arm never READS (the same mention count
 * `unused-case-binder` uses — a binder that IS read is a deliberate capture, whatever it shadows),
 * and which `shadowedDeclaration` resolves to a visible declaration.
 *
 * WHOLE-pattern is the precondition the real tree taught. At the top level a bare name is the arm's
 * entire decision, so the comparison misreading is the dominant explanation and the arm silently
 * becomes a catch-all. NESTED in a constructor pattern (`case TArray(e, …)`) a capture is the
 * ordinary reading and the shadowing is incidental — heaps' `HlslOut` carries exactly that,
 * copy-pasted from the arm above it, where the right advice is `unused-case-binder`'s "spell it
 * `_`". Reporting there would have been a wrong diagnosis AND would have suppressed a correct fix,
 * since both rules read the one predicate.
 *
 * An arm holding a conditional-compilation region or a macro reification is skipped, for the
 * reasons `unused-case-binder` documents: neither its arm run nor its reads can be enumerated.
 *
 * ## Seams
 *
 * Everything arrives through `CasePatternScan.seamsOf`; a grammar leaving a required kind unset
 * makes the check a no-op, and one leaving the SCOPE kinds unset makes `shadowedDeclaration` answer
 * null, which is the same thing one finding at a time.
 */
@:nullSafety(Strict)
final class ShadowingCaseBinder implements Check {

	private static final RULE_ID: String = 'shadowing-case-binder';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a case-pattern binder whose name shadows a declaration in scope — a bare lowercase pattern captures, it never compares';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<CaseSeams> = CasePatternScan.seamsOf(plugin);
		if (seams == null) return [];
		final resolved: CaseSeams = seams;
		final context: CaseRunContext = CasePatternScan.runContextOf(resolved, files, plugin);
		final violations: Array<Violation> = [];
		for (entry in context.parsed) collect(resolved, context.constants, context.index, entry.file, entry.tree, violations);
		return violations;
	}

	/** Report-only: which of an `==` test, a case guard or a free binder name was meant is the author's call. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Every shadowing binder in `tree`, in document order. */
	private static function collect(
		seams: CaseSeams, constants: Array<String>, index: SymbolIndex, file: String, tree: QueryNode, out: Array<Violation>
	): Void {
		CasePatternScan.eachCaseArm(
			seams, tree, (switchNode, at) -> armFindings(seams, constants, index, file, tree, switchNode.children[at], out)
		);
	}

	/** Every shadowing binder of one arm, grouped by name so an or-pattern reports once. */
	private static function armFindings(
		seams: CaseSeams, constants: Array<String>, index: SymbolIndex, file: String, root: QueryNode, arm: QueryNode,
		out: Array<Violation>
	): Void {
		final groups: Null<Array<Array<PatternBinder>>> = CasePatternScan.binderGroups(seams, arm);
		if (groups == null) return;
		for (group in groups) {
			final binder: PatternBinder = group[0];
			final name: String = binder.name;
			// WHOLE-pattern only. At the top level a bare name IS the arm's whole decision, so the
			// comparison misreading is the dominant explanation and the arm silently becomes a
			// catch-all — a behavioural bug. NESTED in a constructor pattern (`case TArray(e, …)`) a
			// capture is the ordinary reading and shadowing is incidental: heaps' HlslOut carries
			// exactly that, copy-pasted from the arm above, where the right advice is
			// `unused-case-binder`'s "spell it `_`" — which this rule's gate must not block.
			if (!binder.bare || !binder.whole || constants.contains(name)) continue;
			if (CasePatternScan.mentionCount(seams, arm, name) != group.length) continue;
			final shadowed: Null<String> = CasePatternScan.shadowedDeclaration(seams, root, arm, name, index);
			final span: Null<Span> = binder.node.span;
			if (shadowed == null || span == null) continue;
			out.push({
				file: file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: buildMessage(name, shadowed, binder.whole)
			});
		}
	}

	/** The finding message: what is shadowed, and — for a whole-pattern binder — that the arm therefore matches everything. */
	private static function buildMessage(name: String, shadowed: String, whole: Bool): String {
		final head: String =
			'case binder \'$name\' shadows the $shadowed of the same name — a bare lowercase pattern CAPTURES, it never compares';
		return whole ? '$head, so this arm matches EVERY value; write a guard (case v if (v == $name):) or compare with ==' : head;
	}

}
