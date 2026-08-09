package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefPrinter;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import anyparse.query.TypeInfoProvider;
import anyparse.check.Check.ConfigAware;

using StringTools;

/**
 * Flags a `catch` clause whose declared exception type is `Dynamic` (or `Any`) — a raw
 * catch-all. The user's rule: use `catch (exception:Exception)`, NOT `catch (e:Dynamic)`.
 * An `Exception` handler binds a wrapper object with a richer, uniform API; a `Dynamic`
 * handler binds the raw thrown value with none. `Severity.Warning`.
 *
 * ## Autofix — arm (a): the caught value is unused
 *
 * `fix` swaps `Dynamic` / `Any` to `Exception` whenever the caught variable is never mentioned
 * in the catch body — an unused catch-all swaps with zero behaviour change (Haxe 4.1 unified
 * exceptions). How the type is SPELLED is the shared `TypeRefPrinter`'s decision (short name when
 * already visible, short name plus an inserted `import haxe.Exception;` when the name is free,
 * fully-qualified on any collision — an import, an alias, a module-local or same-package type).
 * The path itself comes from `RefShape.exceptionTypePath`. A swap inside a conditional-compilation region
 * (`#if … #end`) emits fully-qualified `haxe.Exception` and adds no import — a top-level import
 * would be unused in a build where that branch is compiled out. Arm (a) keeps the original
 * variable name; only the type changes.
 *
 * ## Autofix — arm (b): the caught value is used ONLY for logging (opt-in)
 *
 * When the body uses the caught value ONLY as a logging value — string interpolation (`$e`),
 * `Std.string(e)`, or a `trace(e)` argument — the swap is NOT a pure no-op: it rebinds the value
 * from the raw thrown object to its `haxe.ValueException` wrapper, so the LOGGED TEXT changes
 * from `Std.string(rawValue)` to `Exception.toString()`. On hxcpp (and every 4.1+ target) those
 * COINCIDE: `ValueException.toString()` returns `Std.string(value)` of the very same raw value —
 * verified by a compiler probe (throw a String, catch as `Exception`: `trace` / `Std.string` /
 * `'$e'` all yield text identical to the `Dynamic` path). Because the equivalence is a
 * runtime-behaviour claim, arm (b) is GATED behind the rule option `apqlint.json` →
 * `"catch-dynamic": { "fixLoggingUses": true }` (default OFF): the option IS the project's
 * explicit acceptance of that equivalence. With it ON, `fix` swaps the type, RENAMES the variable
 * to `exception`, and rewrites every logging use (`$msg` → `$exception`), adding the import by the
 * same convention as arm (a). It is skipped when the body already references `exception` (renaming
 * would shadow it), or when any mention is NOT a pure stringify (a field access `e.foo`, a `throw`
 * / `return`, an argument to another call) — that reads or propagates the raw-value API and stays
 * report-only for a manual `.unwrap` decision.
 *
 * ## Autofix — arm (c): the catch has no declared type at all
 *
 * A bare `catch (e)` — no `:Type` at all — has been implicitly `haxe.Exception` since Haxe 4.1's
 * unified exceptions; annotating it is a pure clarity improvement, NOT a behaviour change (the
 * runtime type is identical before and after). `fix` therefore ALWAYS adds the `:Exception`
 * annotation, with no usage gating (unlike arm (b), which must reason about what the body does
 * with the value) and no rename — the bound variable name is left exactly as written. The type is
 * spelled by the same shared `TypeRefPrinter` convention as arms (a)/(b): short name when visible,
 * short name plus an inserted `import haxe.Exception;` when the name is free, fully-qualified on a
 * collision or inside a `#if … #end` conditional region (no import added there either).
 *
 * ## What is flagged
 *
 * A `catchClauseKind` whose declared type (read from the clause header source, between the first
 * `:` and the closing `)`) resolves to a `catchAllTypeNames` name (`Dynamic` / `Any`) — OR whose
 * header has no `:` at all (a bare `catch (e)`, arm (c)). A typed catch of any other name
 * (`Exception`, a custom class, `String`, …) is left alone.
 */
@:nullSafety(Strict)
final class CatchDynamic implements Check implements ConfigAware {

	/** The message for a bare, untyped `catch (e)` (arm (c)) — shared by `run` and any diagnostics. */
	private static final UNTYPED_MESSAGE: String =
		'untyped catch clause is implicitly Exception (Haxe 4.1+) — prefer catch (exception:Exception)';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'catch-dynamic';
	}

	public function description(): String {
		return 'a catch clause whose declared type is Dynamic or Any — prefer catch (exception:Exception)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams = readKinds(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, seams.kind, seams.catchAll);
		}
		return violations;
	}

	/**
	 * Arm (a) swaps an UNUSED `Dynamic`/`Any` catch-all to `Exception` (adding the import), keeping the
	 * original variable name; arm (b) — opt-in via `fixLoggingUses` — additionally renames a
	 * logging-only catch's variable to `exception` and rewrites its logging uses. A body that reads or
	 * propagates the raw value stays a finding.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams = readKinds(plugin);
		if (seams == null) return [];
		final kind: String = seams.kind;
		final catchAll: Array<String> = seams.catchAll;
		final condKind: Null<String> = seams.condKind;
		final callKind: String = seams.callKind;
		final fieldKind: String = seams.fieldKind;
		final identKind: String = seams.identKind;
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final flagged: Map<String, Bool> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged['${span.from}:${span.to}'] = true;
		}
		final file: String = violations.length > 0 ? violations[0].file : '';
		final fixLogging: Bool = LintConfig.resolveWith(_resolveConfig, file).boolOption('catch-dynamic', 'fixLoggingUses') ?? false;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final importMap: Map<String, String> = provider != null ? provider.importMap(source) : [];
		// The shared printer owns the short-name / add-import / fully-qualified decision (imports,
		// aliases, module-local and same-package bindings, sorted insert) — this rule used to
		// hand-roll a weaker version of it.
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(source, root, importMap, RefactorSupport.resolutionIndexOf(plugin));
		final exceptionPath: String = seams.exceptionPath;
		final edits: Array<{ span: Span, text: String }> = [];
		var rewroteNonConditional: Bool = false;
		function walk(node: QueryNode, insideConditional: Bool): Void {
			if (node.kind == kind) {
				// A conditional region gets the qualified path and no import: a top-level import
				// would be unused in a build where the branch is compiled out.
				final exText: String = insideConditional ? exceptionPath : printer.print(exceptionPath).text;
				final catchEdits: Array<{ span: Span, text: String }> = catchRewriteEdits(
					node, source, catchAll, exText, flagged, fixLogging, callKind, fieldKind, identKind
				);
				if (catchEdits.length > 0) {
					for (e in catchEdits) edits.push(e);
					if (!insideConditional) rewroteNonConditional = true;
				}
			}
			final childCond: Bool = insideConditional || (condKind != null && node.kind == condKind);
			for (c in node.children) walk(c, childCond);
		}
		walk(root, false);
		// The printer records a promise per `print` call, including for clauses that turned out
		// unrewritable; the promises are only MATERIALISED when a non-conditional rewrite actually
		// landed and needs the short name.
		if (rewroteNonConditional) for (importEdit in printer.pendingImportEdits()) edits.push(importEdit);
		return edits;
	}

	/** Walk `node`, flagging every catch clause whose declared type is a catch-all name, plus every bare untyped catch. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, catchKind: String, catchAll: Array<String>
	): Void {
		if (node.kind == catchKind) flagCatch(out, file, source, node, catchAll);
		for (c in node.children) walk(out, file, source, c, catchKind, catchAll);
	}

	/**
	 * Append a `Warning` when `catchNode`'s declared exception type is a catch-all name, or when
	 * the clause has no declared type at all (arm (c) — a bare `catch (e)`). The `(var:Type)`
	 * parameter region is decoded by `catchParamRegion`, so a non-nominal type (a function type /
	 * generics) is skipped; the bare case is decoded separately by `catchBareRegion` since it has
	 * no `:` to anchor on. The violation span covers only the parameter region, not the handler body.
	 */
	private static function flagCatch(
		out: Array<Violation>, file: String, source: String, catchNode: QueryNode, catchAll: Array<String>
	): Void {
		final bare = catchBareRegion(catchNode, source);
		if (bare != null) {
			out.push({
				file: file,
				span: new Span(bare.from, bare.to),
				rule: 'catch-dynamic',
				severity: Severity.Warning,
				message: UNTYPED_MESSAGE
			});
			return;
		}
		final p = catchParamRegion(catchNode, source);
		if (p == null || !catchAll.contains(p.typeName)) return;
		out.push({
			file: file,
			span: new Span(p.from, p.to),
			rule: 'catch-dynamic',
			severity: Severity.Warning,
			message: 'catch type \'${p.typeName}\' is a raw catch-all — prefer catch (exception:Exception)'
		});
	}

	/**
	 * The `(var:Type)` parameter region of a catch clause, decoded from the header
	 * source `[span.from, body.from)`: its `from:to` span, the bound variable name, the
	 * simple nominal type name, and the body node. Null when the clause is untyped (no
	 * `:`) or its type is non-nominal (a function type / generics reduce the name to null).
	 * Shared by `run`'s `flagCatch` and `fix`'s `swapEdit` so both decode identically.
	 */
	private static function catchParamRegion(catchNode: QueryNode, source: String): Null<{
		from: Int,
		to: Int,
		varName: String,
		typeName: String,
		body: QueryNode
	}> {
		final cs: Null<Span> = catchNode.span;
		final kids: Array<QueryNode> = catchNode.children;
		if (cs == null || kids.length == 0) return null;
		final bodyNode: QueryNode = kids[kids.length - 1];
		final body: Null<Span> = bodyNode.span;
		if (body == null) return null;
		final start: Int = cs.from;
		final header: String = source.substring(start, body.from);
		final open: Int = header.indexOf('(');
		final colon: Int = header.indexOf(':');
		final close: Int = header.lastIndexOf(')');
		if (open == -1 || colon == -1 || close == -1 || close <= colon) return null;
		final typeName: Null<String> = TypeResolver.simpleNominalName(header.substring(colon + 1, close));
		return typeName == null ? null : {
			from: start + open,
			to: start + close + 1,
			varName: header.substring(open + 1, colon).trim(),
			typeName: typeName,
			body: bodyNode
		};
	}

	/**
	 * The `(var)` parameter region of a BARE, untyped catch clause — arm (c) — decoded the same
	 * way as `catchParamRegion` but requiring the ABSENCE of a `:` in the header (a typed clause is
	 * `catchParamRegion`'s concern, not this one). Null when the header has a `:`, or the parens
	 * can't be found, or the enclosed text is empty (defensive; the grammar always supplies a name).
	 */
	private static function catchBareRegion(catchNode: QueryNode, source: String): Null<{ from: Int, to: Int, varName: String }> {
		final cs: Null<Span> = catchNode.span;
		final kids: Array<QueryNode> = catchNode.children;
		if (cs == null || kids.length == 0) return null;
		final bodyNode: QueryNode = kids[kids.length - 1];
		final body: Null<Span> = bodyNode.span;
		if (body == null) return null;
		final start: Int = cs.from;
		final header: String = source.substring(start, body.from);
		final open: Int = header.indexOf('(');
		final colon: Int = header.indexOf(':');
		final close: Int = header.lastIndexOf(')');
		if (open == -1 || close == -1 || close <= open || colon != -1) return null;
		final varName: String = header.substring(open + 1, close).trim();
		return varName.length == 0 ? null : { from: start + open, to: start + close + 1, varName: varName };
	}

	/**
	 * The `(var:Exception)` rewrite for a flagged catch clause, or null when it must stay
	 * a finding. Fires only when the clause was flagged (its region span is in `flagged`),
	 * its type is a catch-all name, and the bound variable is never mentioned in the body —
	 * an unused catch-all swaps to `Exception` with zero behaviour change (Haxe 4.1 unified
	 * exceptions), while a body that reads the raw value needs a manual `.unwrap` migration.
	 */
	private static function swapEdit(
		catchNode: QueryNode, source: String, catchAll: Array<String>, exText: String, flagged: Map<String, Bool>
	): Null<{ span: Span, text: String }> {
		final p = catchParamRegion(catchNode, source);
		if (p == null || !catchAll.contains(p.typeName)) return null;
		final unfixable: Bool = !flagged.exists('${p.from}:${p.to}') || p.varName.length == 0 || mentionsName(p.body, p.varName);
		return unfixable ? null : { span: new Span(p.from, p.to), text: '(${p.varName}:$exText)' };
	}

	/**
	 * The `(var:Exception)` rewrite for a flagged BARE catch clause — arm (c) — or null when it
	 * wasn't flagged (or isn't bare). Unlike `swapEdit` this has no usage gate: the annotation is a
	 * zero-behaviour-change clarification (Haxe 4.1 already binds a bare `catch (e)` as
	 * `haxe.Exception`), so it fires unconditionally, keeping the original variable name.
	 */
	private static function bareSwapEdit(catchNode: QueryNode, source: String, exText: String, flagged: Map<String, Bool>): Null<{
		span: Span,
		text: String
	}> {
		final b = catchBareRegion(catchNode, source);
		return b == null || !flagged.exists('${b.from}:${b.to}') ? null : { span: new Span(b.from, b.to), text: '(${b.varName}:$exText)' };
	}

	/** Whether any node in `node`'s subtree carries `name` — catches plain identifiers, field-access names, and string-interpolation idents alike (a conservative reference test). */
	private static function mentionsName(node: QueryNode, name: String): Bool {
		if (node.name == name) return true;
		for (c in node.children) if (mentionsName(c, name)) return true;
		return false;
	}

	/** The catch-clause kind, catch-all type names and canonical exception path, or null when the grammar sets none of them (the check is then a no-op). */
	private static function readKinds(plugin: GrammarPlugin): Null<{
		kind: String,
		catchAll: Array<String>,
		condKind: Null<String>,
		callKind: String,
		fieldKind: String,
		identKind: String,
		exceptionPath: String
	}> {
		final shape: RefShape = plugin.refShape();
		final catchKind: Null<String> = shape.catchClauseKind;
		final exceptionPath: Null<String> = shape.exceptionTypePath;
		if (catchKind == null || exceptionPath == null) return null;
		final catchAll: Array<String> = shape.catchAllTypeNames ?? [];
		return catchAll.length == 0 ? null : {
			kind: catchKind,
			catchAll: catchAll,
			condKind: shape.conditionalMemberKind,
			callKind: shape.callKind ?? '',
			fieldKind: shape.fieldAccessKind ?? '',
			identKind: shape.identKind,
			exceptionPath: exceptionPath
		};
	}

	/**
	 * The arm-(b) rewrite edits for a flagged catch clause whose caught value is used ONLY as a
	 * logging value — string interpolation (`$e`), `Std.string(e)`, or a `trace(e)` argument. Renames
	 * the bound variable to `exception`, rewrites every logging use accordingly, and swaps the type to
	 * `exText`. Empty when the clause is not flagged / not a catch-all, its value is unused (arm (a)'s
	 * job), the body already references `exception` (renaming would shadow it), or any use is not a
	 * pure stringify. The caller adds the import per the shared convention.
	 */
	private static function loggingSwapEdits(
		catchNode: QueryNode, source: String, catchAll: Array<String>, exText: String, flagged: Map<String, Bool>, callKind: String,
		fieldKind: String, identKind: String
	): Array<{ span: Span, text: String }> {
		final p = catchParamRegion(catchNode, source);
		if (p == null || !catchAll.contains(p.typeName) || !flagged.exists('${p.from}:${p.to}') || p.varName.length == 0) return [];
		if (!mentionsName(p.body, p.varName)) return [];
		if (p.varName != 'exception' && mentionsName(p.body, 'exception')) return [];
		final mentions: Null<Array<QueryNode>> = loggingMentions(p.body, p.varName, callKind, fieldKind, identKind);
		if (mentions == null) return [];
		final out: Array<{ span: Span, text: String }> = [{ span: new Span(p.from, p.to), text: '(exception:$exText)' }];
		if (p.varName != 'exception') for (m in mentions) {
			final ms: Null<Span> = m.span;
			if (ms != null) out.push({ span: ms, text: m.kind == 'Ident' ? '$$exception' : 'exception' });
		}
		return out;
	}

	/**
	 * Every mention of `name` in `body` when ALL of them are pure logging (stringifying) uses and at
	 * least one exists; null otherwise. A logging use is a string-interpolation ident (`$name`), the
	 * expression of a `${name}` interpolation block, or a direct argument of a `trace(…)` /
	 * `Std.string(…)` call. A field-access receiver (`name.foo`), a `throw` / `return`, or an argument
	 * to any other call is NOT a logging use — one such mention makes the whole clause report-only.
	 */
	private static function loggingMentions(
		body: QueryNode, name: String, callKind: String, fieldKind: String, identKind: String
	): Null<Array<QueryNode>> {
		// Haxe string-interpolation kinds have no RefShape seam: `$ident` -> `Ident`, `${expr}` -> `Block`.
		final mentions: Array<QueryNode> = [];
		var nonLogging: Bool = false;
		function visit(node: QueryNode, loggingPos: Bool): Void {
			if (node.name == name && (node.kind == identKind || node.kind == 'Ident')) {
				mentions.push(node);
				if (node.kind != 'Ident' && !loggingPos) nonLogging = true;
				return;
			}
			final callLogging: Bool = node.kind == callKind && node.children.length > 0
				&& isLoggingCallee(node.children[0], fieldKind, identKind);
			for (i => c in node.children) visit(c, (callLogging && i > 0) || node.kind == 'Block');
		}
		visit(body, false);
		return nonLogging || mentions.length == 0 ? null : mentions;
	}

	/** Whether `callee` is a `trace(…)` or `Std.string(…)` callee — the recognised pure-stringify calls. */
	private static function isLoggingCallee(callee: QueryNode, fieldKind: String, identKind: String): Bool {
		if (callee.kind == identKind) return callee.name == 'trace';
		if (callee.kind != fieldKind || callee.name != 'string') return false;
		final recv: Null<QueryNode> = callee.children.length > 0 ? callee.children[0] : null;
		return recv != null && recv.kind == identKind && recv.name == 'Std';
	}

	/**
	 * The rewrite edits for ONE flagged catch clause: arm (c) (annotate a bare, untyped catch —
	 * unconditional, keeping the variable name) when the clause has no declared type at all; else
	 * arm (a) (swap an unused catch-all, keeping the variable name) when the value is unused; else
	 * arm (b) (rename a logging-only value to `exception`) when `fixLogging` is on; else empty —
	 * the clause stays a report-only finding. The three arms are mutually exclusive: a clause is
	 * either bare (arm (c)'s concern) or typed (arms (a)/(b)'s), never both.
	 */
	private static function catchRewriteEdits(
		node: QueryNode, source: String, catchAll: Array<String>, exText: String, flagged: Map<String, Bool>, fixLogging: Bool,
		callKind: String, fieldKind: String, identKind: String
	): Array<{ span: Span, text: String }> {
		final bareEdit: Null<{ span: Span, text: String }> = bareSwapEdit(node, source, exText, flagged);
		if (bareEdit != null) return [bareEdit];
		final unusedEdit: Null<{ span: Span, text: String }> = swapEdit(node, source, catchAll, exText, flagged);
		return if (unusedEdit != null)
			[unusedEdit] else if (fixLogging)
			loggingSwapEdits(node, source, catchAll, exText, flagged, callKind, fieldKind, identKind)
		else
			[];
	}

}
