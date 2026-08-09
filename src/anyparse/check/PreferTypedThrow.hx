package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StdResolver;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags `throw '<string>'` — a raw string thrown as an exception. The value carries no
 * type, no stack and no uniform API; the canonical form boxes it
 * (`throw new Exception('<string>')`, `RefShape.exceptionTypePath`), which every
 * `catch (e:Exception)` handler binds with the full wrapper API. `Info`.
 *
 * ## Default OFF — opt-in
 *
 * A `DefaultOff` marker: dropped from the default set and from a bare `lint … --all`
 * report unless a project opts in via `apqlint.json`
 * (`"rules": { "prefer-typed-throw": { "enabled": true } }`), or an explicit
 * `--rule prefer-typed-throw` selects it. Boxing a throw is a project-wide convention
 * decision, not a universal default.
 *
 * ## What is flagged
 *
 * A `throwKinds` node whose single operand — parentheses peeled — is a
 * `stringLiteralKinds` node: a plain literal (`throw 'boom'`) or an INTERPOLATED one
 * (`throw 'bad $id'`), both of which the rewrite carries through verbatim as the
 * constructor argument. `throw <expr>` of any other shape is out of scope: only a literal
 * is provably a raw String at the throw site, and only a literal can be moved into the
 * constructor with no evaluation-order question.
 *
 * ## The catch-clause gate — fail closed over the PROJECT scope
 *
 * Boxing changes what a handler sees. A `catch (e:String)` clause STOPS MATCHING a boxed
 * throw altogether; so does a `catch (e:ValueException)` (the runtime wraps a RAW throw in
 * that, never a boxed one); a `catch (e:Dynamic)` / `catch (e:Any)` still matches but now binds
 * the wrapper object instead of the raw string, so a body reading the raw value's API changes
 * behaviour. None is decidable per-file — the handler can live anywhere the thrower's call
 * reaches. So the gate scans the report files UNION the configured library roots (via
 * `RefactorSupport.resolutionIndexOf`): if ANY `catch` clause there is typed one of those
 * names, the rule DEGRADES WHOLESALE to report-only — every finding keeps its diagnostic, no
 * finding gets an edit. A source the index could not PARSE is unreadable rather than absent, so
 * a skipped project file degrades too, and the `Cli` fixed-point loop lists this rule in
 * `fullScopeIds` so a later pass sees every file rather than the changed subset. With NO
 * resolution scope at all (a direct `check.run`) the gate can only answer for the files it is
 * handed — its proof is only as wide as the run.
 *
 * ## Why the auto-discovered std is excluded from that scan
 *
 * Every file the implicitly discovered std contributed is skipped, recognised by
 * `StdResolver.isStdFile` — the SAME memoised `stdDir` the scope itself was built from, never
 * a guess at a `/std/` path segment. The argument is reachability, not volume: a `String` /
 * `Dynamic` catch inside std guards std-internal throws within std's own call boundaries, and a
 * PROJECT throw converted to `haxe.Exception` cannot change which std-internal throws those
 * clauses see. Scanning them only imports a verdict about code the rewrite can never reach.
 *
 * Left in, that verdict was not fail-closed but permanently closed: the std ships ~31 such
 * clauses across 10 files (`haxe.ds.BalancedTree` catches `String`; `haxe.io.Bytes`,
 * `haxe.io.BytesInput`, `haxe.Template`, `sys.Http` and friends catch `Dynamic`), so on any
 * Haxe-equipped machine the implicit std joined the scope and degraded EVERY run — the fix arm
 * opened only under `APQ_NO_STD` / `"resolutionStd": false`, which is to say never.
 *
 * The PROJECT half keeps the full fail-closed treatment, and that half is the point: a
 * project's own `catch (msg:String)` — a vendored crash reporter, say — does sit on a path a
 * project throw reaches, so ONE such clause anywhere in report or library scope still degrades
 * the whole rule. The edge the exclusion knowingly buys is a project callback handed INTO std
 * and invoked inside a std `try`; a rule that can never act is the worse trade.
 *
 * The scan is TEXTUAL (a `catch` token, its parenthesised parameter, the nominal after the
 * `:`), not a parse: it must visit every indexed project source, a parse of each would dominate
 * the run, and for the shapes that matter (`catch (e:String)`, `catch(e : Dynamic)`, a
 * line-broken parameter) it decodes, while its over-matches (the token inside a comment or a
 * string) only degrade the rule further. It does NOT resolve names: a clause typed through a
 * `typedef Raw = String` alias reads as `Raw` and does not degrade — a KNOWN unsound miss,
 * since the project's own alias would still be catching a raw String.
 *
 * ## Autofix
 *
 * The literal's span is replaced with `new <Exception>(<literal verbatim>)`, and the
 * exception reference is spelled by `TypeRefPrinter`: the short name when the type is
 * already visible, the short name PLUS an inserted `import haxe.Exception;` when that name
 * is free in the file, else the fully-qualified `haxe.Exception` — so a file that already
 * binds `Exception` to something else is never silently retargeted. A throw inside a
 * conditional-compilation region (`conditionalMemberKind`) always emits the fully-qualified
 * path and adds no import: a top-level import would be unused in a build where that branch
 * is compiled out (the same convention `catch-dynamic` follows).
 */
@:nullSafety(Strict)
final class PreferTypedThrow implements Check implements DefaultOff {

	private static inline final RULE_ID: String = 'prefer-typed-throw';

	/** The clause keyword the textual gate scans for — its length is the scan's step, so the two must stay one constant. */
	private static inline final CATCH_KEYWORD: String = 'catch';

	/** The finding message when the catch-clause gate passed — the rewrite is available. */
	private static inline final MSG_FIXABLE: String = 'a raw string throw — prefer throwing a typed exception';

	/** The finding message when the gate found a catch-all / String clause in scope — the rule is report-only. */
	private static inline final MSG_DEGRADED: String =
		'a raw string throw — prefer throwing a typed exception (report-only: a String / Dynamic / Any catch clause in the resolution scope would stop matching, or rebind, a typed exception)';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a throw of a raw string literal, replaceable with a typed exception';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			walkThrows(tree, seams, false, (literal, _) -> {
				final span: Null<Span> = literal.span;
				if (span != null) violations.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: MSG_FIXABLE
				});
			});
		}
		// The gate reads every source in the resolution scope, so it runs ONLY once a candidate
		// exists — a run that flags nothing must not pay for it.
		if (violations.length > 0 && catchAllInScope(files, plugin, seams)) for (v in violations) v.message = MSG_DEGRADED;
		return violations;
	}

	/**
	 * Box each flagged literal into `new <Exception>(…)`, plus the import its short form
	 * needs. Only a finding the gate left FIXABLE yields an edit — a degraded run's findings
	 * all carry `MSG_DEGRADED` and are skipped, which is what makes the whole-scope verdict
	 * survive the per-file `fix` seam without re-scanning.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final wanted: Map<String, Bool> = [];
		var anyFixable: Bool = false;
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null || v.message != MSG_FIXABLE) continue;
			wanted['${span.from}:${span.to}'] = true;
			anyFixable = true;
		}
		if (!anyFixable) return [];
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final importMap: Map<String, String> = provider != null ? provider.importMap(source) : [];
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(source, tree, importMap, index ?? RefactorSupport.resolutionIndexOf(plugin));
		final edits: Array<{ span: Span, text: String }> = [];
		walkThrows(tree, seams, false, (literal, insideConditional) -> {
			final span: Null<Span> = literal.span;
			if (span == null || !wanted.exists('${span.from}:${span.to}')) return;
			// A conditional region gets the qualified path and no import: a top-level import
			// would be unused in a build where the branch is compiled out.
			final typeText: String = insideConditional ? seams.exceptionPath : printer.print(seams.exceptionPath).text;
			edits.push({ span: span, text: 'new $typeText(${source.substring(span.from, span.to)})' });
		});
		if (edits.length > 0) for (importEdit in printer.pendingImportEdits()) edits.push(importEdit);
		return edits;
	}

	/**
	 * Visit every `throw <string literal>` in `node`'s subtree, handing the LITERAL node and
	 * whether it sits inside a conditional-compilation region to `found`. The throw's operand
	 * is paren-peeled first, so `throw ('boom')` is the same shape as `throw 'boom'`.
	 */
	private static function walkThrows(node: QueryNode, seams: Seams, insideConditional: Bool, found: (QueryNode, Bool) -> Void): Void {
		if (seams.throwKinds.contains(node.kind) && node.children.length == 1) {
			final operand: QueryNode = RefactorSupport.unwrapParens(node.children[0], seams.parenKind);
			if (seams.stringKinds.contains(operand.kind)) found(operand, insideConditional);
		}
		final childCond: Bool = insideConditional || (seams.condKind != null && node.kind == seams.condKind);
		for (c in node.children) walkThrows(c, seams, childCond, found);
	}

	/**
	 * Whether ANY source in the PROJECT half of the resolution scope carries a `catch` clause
	 * typed `String` or a catch-all name. The report `files` are scanned first (they are already
	 * in memory and are the likeliest hit); the resolution index — report files UNION the
	 * configured library roots — is scanned after, skipping the sources already seen AND every
	 * file the auto-discovered std contributed (`StdResolver.isStdFile`; the class doc has the
	 * reachability argument). True degrades the whole rule to report-only.
	 */
	private static function catchAllInScope(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, seams: Seams): Bool {
		for (entry in files) if (sourceHasBlockingCatch(entry.source, seams.blockingCatchTypes)) return true;
		final index: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin);
		if (index == null) return false;
		// A source the index could not PARSE never enters `allFiles`, so its clauses are
		// unreadable here. Unreadable is not absent: degrade rather than assume — except for a
		// std source, whose clauses this gate would not have read even had it parsed.
		for (skipped in index.skippedFiles()) if (!StdResolver.isStdFile(skipped)) return true;
		final scanned: Map<String, Bool> = [for (entry in files) entry.file => true];
		for (info in index.allFiles()) if (!scanned.exists(info.file) && !StdResolver.isStdFile(info.file)) {
			final src: Null<String> = index.sourceOf(info.file);
			if (src != null && sourceHasBlockingCatch(src, seams.blockingCatchTypes)) return true;
		}
		return false;
	}

	/**
	 * Whether `source` textually carries a `catch (<name>:<T>)` whose `T` reduces to a
	 * `blocking` nominal. A word-boundary `catch` token, the next `(`, its matching `)` and
	 * the nominal after the first `:` — no parse (see the class doc for why, and why an
	 * over-match is the safe direction). A clause with no `:` (an untyped `catch (e)`) or a
	 * non-nominal type (a function type / generics) yields no name and never blocks.
	 */
	private static function sourceHasBlockingCatch(source: String, blocking: Array<String>): Bool {
		final n: Int = source.length;
		var i: Int = 0;
		while (i < n) {
			final at: Int = source.indexOf(CATCH_KEYWORD, i);
			if (at < 0) return false;
			i = at + CATCH_KEYWORD.length;
			if (at > 0 && RefactorSupport.isIdentChar(source.fastCodeAt(at - 1))) continue;
			if (i < n && RefactorSupport.isIdentChar(source.fastCodeAt(i))) continue;
			var open: Int = i;
			while (open < n && source.isSpace(open)) open++;
			if (open >= n || source.fastCodeAt(open) != '('.code) continue;
			final close: Int = source.indexOf(')', open);
			if (close < 0) return false;
			final inner: String = source.substring(open + 1, close);
			final colon: Int = inner.indexOf(':');
			if (colon < 0) continue;
			final name: Null<String> = TypeResolver.simpleNominalName(inner.substring(colon + 1));
			if (name != null && blocking.contains(name)) return true;
		}
		return false;
	}

	/**
	 * The grammar seams this check needs, or null when any required one is unset — the check
	 * is then a no-op. `blockingCatchTypes` unions three sets: the grammar's catch-all names, its
	 * STRING literal type name (read off `literalTypeNames` through a `stringLiteralKinds` kind
	 * rather than hardcoded — the type a boxed throw stops matching), and the simple name of
	 * `rawThrowWrapperTypePath` (Haxe's `ValueException`: the runtime wraps a RAW throw in it, so
	 * a clause typed that way matches before the rewrite and not after).
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final throwKinds: Array<String> = shape.throwKinds ?? [];
		final stringKinds: Array<String> = shape.stringLiteralKinds ?? [];
		final exceptionPath: Null<String> = shape.exceptionTypePath;
		if (throwKinds.length == 0 || stringKinds.length == 0 || exceptionPath == null) return null;
		final blocking: Array<String> = (shape.catchAllTypeNames ?? []).copy();
		final literalTypes: Map<String, String> = shape.literalTypeNames ?? [];
		for (k in stringKinds) {
			final t: Null<String> = literalTypes[k];
			if (t != null && !blocking.contains(t)) blocking.push(t);
		}
		final wrapper: Null<String> = shape.rawThrowWrapperTypePath;
		if (wrapper != null) {
			final simple: String = wrapper.substring(wrapper.lastIndexOf('.') + 1);
			if (!blocking.contains(simple)) blocking.push(simple);
		}
		return {
			throwKinds: throwKinds,
			stringKinds: stringKinds,
			parenKind: shape.parenKind,
			condKind: shape.conditionalMemberKind,
			exceptionPath: exceptionPath,
			blockingCatchTypes: blocking
		};
	}

}

/** The resolved grammar seams of one `prefer-typed-throw` run — read once per `run` / `fix` rather than per node. */
private typedef Seams = {
	var throwKinds: Array<String>;
	var stringKinds: Array<String>;
	var parenKind: Null<String>;
	var condKind: Null<String>;
	var exceptionPath: String;
	var blockingCatchTypes: Array<String>;
}
