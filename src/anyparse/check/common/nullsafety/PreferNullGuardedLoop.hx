package anyparse.check.common.nullsafety;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.common.control.BranchChain;
import anyparse.check.scan.PlainReadProof;
import anyparse.query.ElementSpan;
import anyparse.query.LexicalRegions;
import anyparse.query.MemberKinds;
import anyparse.query.NominalTypes;
import anyparse.query.ParenGuard;
import anyparse.query.SymbolIndex;

/** The resolved seams `PreferNullGuardedLoop` reads in both `run` and `fix`. */
private typedef Seams = {
	final forKind: String;
	final coalesceKind: String;
	final arrayKind: String;
	final emptyTypes: Array<String>;
	final ifKinds: Array<String>;
	final indexKind: Null<String>;
	final safeAccessKind: Null<String>;
	final binderKinds: Array<String>;
	final unsafeKinds: Array<String>;
};

/** A loop over `value ?? []`: the loop, its `??` iterable, the guarded value, and why a guard cannot replace it (null: it can). */
private typedef Fallback = {
	final loop: QueryNode;
	final coalesce: QueryNode;
	final value: QueryNode;
	final refusal: Null<String>;
};

/**
 * The one answer to "which loop iterates a null fallback that a null guard replaces": flags
 * `for (x in e ?? []) body` and rewrites it to `if (e != null) for (x in e) body`. `Severity.Info`, opt-in, with a
 * RISKY autofix applied only under a configured `compilerOracle`: whether the compiler narrows `e` after the null
 * check is a fact of the project's null safety, so the oracle typechecks each rewrite and reverts what breaks.
 *
 * The guard builds no empty array for a null `e` and reads as one statement. It reads `e` twice where the fallback
 * reads it once, so a loop is reported and NOT rewritten, the reason in its message, when:
 *
 * - `e` holds a call, a construction or an assignment (`CheckScan.mutationKinds`): two evaluations are observable;
 * - `e` holds an index read: a second lookup, and a null check narrows no index read;
 * - `e` holds a safe-navigation read (`a?.b`): a null check narrows none either;
 * - `e` is not proven a plain read by `PlainReadProof` (a property getter would run twice): anything but the self
 *   reference, a bound local or parameter, an own physical field, and a `.field` chain of proven plain members;
 * - `e` resolves to a container outside `RefShape.emptyLiteralTypes`: the fallback there is that container's empty
 *   value, not a plain skip. An unresolved type is left to the oracle;
 * - an `else` follows the loop directly: it would bind to the new guard;
 * - a comment sits inside the iterable: the rewrite would drop or duplicate it.
 *
 * A fallback other than the empty array literal (`e ?? other`) is a different loop and is not flagged. A loop in a
 * comprehension is an expression node of another kind and is not flagged either.
 *
 * ## Grammar-agnostic
 *
 * Driven by `forStmtKind`, `nullCoalesceKind`, `arrayLiteralKind` and `emptyLiteralTypes` (any unset → no-op), plus
 * the optional `ifStatementKinds`, `indexAccessKind`, `nullSafeAccessKind` and `iterationValueBinderKinds`.
 */
@:nullSafety(Strict)
final class PreferNullGuardedLoop extends RuleBase implements RiskyFix implements DefaultOff {

	/** This check's stable id, spelled once. */
	private static inline final RULE_ID: String = 'prefer-null-guarded-loop';

	private static final FIXABLE: String =
		'this loop over a null fallback (e ?? []) can be a null guard around the loop: if (e != null) for (x in e)';
	private static final REFUSED: String = 'this loop iterates a null fallback (e ?? []) that a null guard cannot replace as written: ';
	private static final EVALUATED_TWICE: String = 'the guard would evaluate the call, construction or assignment in the iterable twice';
	private static final INDEX_READ: String = 'the guard would read the indexed element twice, and a null check narrows no index read';
	private static final SAFE_NAV_READ: String = 'a null check narrows no safe-navigation read (?.)';
	private static final UNPROVEN_READ: String = 'the guard reads the iterable twice, and a property getter is not ruled out for it';
	private static final OTHER_CONTAINER: String = 'the iterable is not a container the empty literal stands for';
	private static final DANGLING_ELSE: String = 'the else after the loop would bind to the guard';
	private static final COMMENTED: String = 'a comment sits inside the iterable';

	/** The opening of the guard the fix writes, up to the guarded value. */
	private static final GUARD_HEAD: String = 'if (';

	public function new() {
		super(
			RULE_ID, 'a loop over a null fallback (for (x in e ?? [])) replaceable with a null guard (if (e != null) for (x in e))',
			RuleCategory.NullSafety
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final getIndex: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, seamsOf(plugin.refShape()), (entry, tree, seams, violations) -> {
			for (f in fallbacks(tree, entry.source, entry.file, plugin, getIndex, seams)) {
				final span: Null<Span> = f.coalesce.span;
				final refusal: Null<String> = f.refusal;
				if (span != null) violations.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: refusal == null ? FIXABLE : REFUSED + refusal
				});
			}
		});
	}

	/** Rewrite each flagged loop a guard can replace to `if (<e> != null) for (<binder> in <e>) body`. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return RunScan.editsWith(plugin, source, seamsOf(plugin.refShape()), (tree, seams) -> {
			final byKey: Map<String, Fallback> = [];
			// a fix is handed the findings of the one file it edits: their file is where the proof reads its types and names
			final file: String = violations.length == 0 ? '' : violations[0].file;
			for (f in fallbacks(tree, source, file, plugin, () -> index ?? IndexScope.resolutionIndexOf(plugin), seams)) {
				final span: Null<Span> = f.coalesce.span;
				if (span != null && f.refusal == null) byKey['${span.from}:${span.to}'] = f;
			}
			final guarded: Array<GuardedEdit> = [];
			RunScan.eachMatched(violations, byKey, (f, span) -> {
				final loopSpan: Null<Span> = f.loop.span;
				final valueSpan: Null<Span> = f.value.span;
				if (loopSpan == null || valueSpan == null) return;
				final value: String = source.substring(valueSpan.from, valueSpan.to);
				// The value lands left of `!=`, where an operand that binds looser needs parentheses: a hole for ParenGuard.
				guarded.push({
					span: new Span(loopSpan.from, span.to),
					text: '$GUARD_HEAD$value != null) ${source.substring(loopSpan.from, span.from)}$value',
					holes: [new Span(GUARD_HEAD.length, GUARD_HEAD.length + value.length)]
				});
			});
			return ParenGuard.guard(source, guarded, plugin);
		});
	}

	/**
	 * Every loop over an empty-array null fallback in `tree`, each with its refusal. The plain-read proof and the typer
	 * are asked only for a loop no syntactic refusal took.
	 */
	private static function fallbacks(
		tree: QueryNode, source: String, file: String, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>, s: Seams
	): Array<Fallback> {
		final found: Array<Fallback> = [];
		collect(tree, ElementSpan.lazyRegions(source, plugin), s, [], found);
		if (!found.exists(f -> f.refusal == null)) return found;
		final plainRead: QueryNode -> Bool = PlainReadProof.prover(tree, source, file, plugin, index);
		final resolved: Null<SymbolIndex> = index();
		final nominal: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, file, resolved, true);
		return found.map(f -> {
			if (f.refusal != null) return f;
			final refusal: Null<String> = if (!plainRead(f.value))
				UNPROVEN_READ;
			else if (nominal != null && otherContainer(nominal(f.value), resolved, s))
				OTHER_CONTAINER;
			else
				null;
			return refusal == null ? f : {
				loop: f.loop,
				coalesce: f.coalesce,
				value: f.value,
				refusal: refusal
			};
		});
	}

	/**
	 * Whether `type`, the resolved container of the iterated value, is
	 * one the empty literal does not stand for; an unresolved type is not.
	 */
	private static function otherContainer(type: Null<String>, index: Null<SymbolIndex>, s: Seams): Bool {
		return type != null && (!s.emptyTypes.contains(type) || NominalTypes.shadowedByNonStdType(index, type));
	}

	/**
	 * Collects the fallback loops under `node`. `elseEnds` holds the end of every enclosing then-branch that an `else`
	 * follows: a loop ending there has that `else` right after it. A matched loop's iterable is not descended into,
	 * so no two edits overlap.
	 */
	private static function collect(
		node: QueryNode, regions: () -> Array<LexRegion>, s: Seams, elseEnds: Array<Int>, out: Array<Fallback>
	): Void {
		final found: Null<Fallback> = node.kind == s.forKind ? fallbackOf(node, regions, s, elseEnds) : null;
		if (found != null) out.push(found);
		var ends: Array<Int> = elseEnds;
		if (s.ifKinds.contains(node.kind) && BranchChain.hasElse(node)) {
			final thenSpan: Null<Span> = BranchChain.thenOf(node).span;
			if (thenSpan != null) ends = elseEnds.concat([thenSpan.to]);
		}
		for (c in node.children) if (found == null || c != found.coalesce) collect(c, regions, s, ends, out);
	}

	private static function fallbackOf(loop: QueryNode, regions: () -> Array<LexRegion>, s: Seams, elseEnds: Array<Int>): Null<Fallback> {
		final iterable: Null<QueryNode> = NominalTypes.iterationIterable(loop, s.binderKinds);
		if (iterable == null || iterable.kind != s.coalesceKind || iterable.children.length != 2) return null;
		final value: QueryNode = iterable.children[0];
		final fallback: QueryNode = iterable.children[1];
		final span: Null<Span> = iterable.span;
		final loopSpan: Null<Span> = loop.span;
		if (fallback.kind != s.arrayKind || fallback.children.length != 0 || span == null || loopSpan == null) return null;
		final indexKind: Null<String> = s.indexKind;
		final safeAccessKind: Null<String> = s.safeAccessKind;
		final refusal: Null<String> = if (s.unsafeKinds.exists(k -> MemberKinds.subtreeContainsKind(value, k)))
			EVALUATED_TWICE;
		else if (indexKind != null && MemberKinds.subtreeContainsKind(value, indexKind))
			INDEX_READ;
		else if (safeAccessKind != null && MemberKinds.subtreeContainsKind(value, safeAccessKind))
			SAFE_NAV_READ;
		else if (elseEnds.contains(loopSpan.to))
			DANGLING_ELSE;
		else if (LexicalRegions.commentIntersects(span.from, span.to, regions()))
			COMMENTED;
		else
			null;
		return {
			loop: loop,
			coalesce: iterable,
			value: value,
			refusal: refusal
		};
	}

	private static function seamsOf(shape: RefShape): Null<Seams> {
		final forKind: Null<String> = shape.forStmtKind;
		final coalesceKind: Null<String> = shape.nullCoalesceKind;
		final arrayKind: Null<String> = shape.arrayLiteralKind;
		final emptyTypes: Null<Array<String>> = shape.emptyLiteralTypes;
		return forKind == null || coalesceKind == null || arrayKind == null || emptyTypes == null ? null : {
			forKind: forKind,
			coalesceKind: coalesceKind,
			arrayKind: arrayKind,
			emptyTypes: emptyTypes,
			ifKinds: shape.ifStatementKinds ?? [],
			indexKind: shape.indexAccessKind,
			safeAccessKind: shape.nullSafeAccessKind,
			binderKinds: shape.iterationValueBinderKinds ?? [],
			unsafeKinds: CheckScan.mutationKinds(shape)
		};
	}

}
