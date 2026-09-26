package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.check.NullFlowScan.IdentOperand;
import anyparse.query.GrammarPlugin;
import anyparse.query.ModuleScan;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.io.Path;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * Flags a null-safe access (`a?.b`) whose receiver is already non-null **by flow**
 * on every path reaching it — the `?.` can never short-circuit, so a plain `.` is
 * equivalent. The flow-only counterpart of `unnecessary-safe-nav`.
 *
 * ## Flow-only — complements `unnecessary-safe-nav`, never duplicates it
 *
 * Non-null-ness comes purely from `NullFlow`: an earlier `!= null` guard narrowing
 * this path (then-arm), an `== null` guard's else-arm, or a syntactically non-null
 * assignment. It skips any receiver the declared prover
 * `TypeResolver.isProvablyNonNull` already proves non-null — those belong to
 * `unnecessary-safe-nav`. So a redundant `?.` is reported exactly once.
 *
 * Conservative throughout (see `NullFlow`): every uncertainty collapses to
 * `Unknown`, so only a genuinely redundant `?.` is reported. `Severity.Info`;
 * `fix` rewrites `?.`→`.`, the same rewrite `unnecessary-safe-nav` applies. Under null-safety (`@:nullSafety` in scope, or
 * a `--macro nullSafety` in an oracle hxml) the compiler must see the proof too, so a receiver proven only through a Bool
 * local, an alias or a `?.` comparison keeps its finding with a `declineReason` and no edit (`NullFacts.nonNullVisible`).
 */
@:nullSafety(Strict)
final class DeadSafeNav implements Check implements ConfigAware {

	/** The `declineReason` of a finding whose non-null proof the compiler's null-safety does not share. */
	private static inline final UNSEEN_REASON: String =
		'null-safety is on here and cannot follow this proof (a Bool local, an alias or a `?.` comparison), so a plain `.` would not compile';

	/** How deep an oracle hxml's own `.hxml` includes are followed — a bound that ends an include cycle. */
	private static inline final MAX_INCLUDE_DEPTH: Int = 8;

	/** A `--macro nullSafety(<path>, <mode>, <recursive>)` call; group 1 is its argument list. */
	private static final NULL_SAFETY_MACRO: EReg = ~/nullSafety\(([^)]*)\)/;

	/** The quotes around a macro's string argument. */
	private static final QUOTES: EReg = ~/^['"]|['"]$/g;

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'dead-safe-nav';
	}

	public function description(): String {
		return 'a null-safe access (?.) whose receiver is already non-null on every path reaching it';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final safeNavKind: Null<String> = shape.nullSafeAccessKind;
		final identKind: Null<String> = shape.identKind;
		if (safeNavKind == null || identKind == null) return [];
		final navKind: String = safeNavKind;
		final ident: String = identKind;
		final hxmlText: Map<String, Null<String>> = [];
		return RunScan.collectWith(files, plugin, RunScan.typeInfoOf(plugin), (entry, root, typed, violations) -> {
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			final underMacro: Bool = underNullSafetyMacro(entry.file, ModuleScan.moduleOf(root, entry.file).path, hxmlText);
			NullFlow.analyze(root, shape, entry.source, (node, facts) -> {
				if (node.kind != navKind || node.children.length != 1) return;
				final receiver: Null<IdentOperand> = NullFlowScan.identOperand(node, node.children[0], ident);
				if (receiver == null) return;
				// Owned by `unnecessary-safe-nav` when the declared type proves it.
				if (TypeResolver.isProvablyNonNull(receiver.operand, root, shape, declaredTypes)) return;
				if (!facts.nonNull(receiver.name)) return;
				final violation: Violation = {
					file: entry.file,
					span: receiver.span,
					rule: 'dead-safe-nav',
					severity: Severity.Info,
					message: 'null-safe access is redundant — receiver is already non-null on this path'
				};
				final metaName: Null<String> = shape.nullSafetyMetaName;
				final nullSafe: Bool = underMacro || metaName != null
				&& TypeResolver.nullSafetyActiveAt(root, receiver.span, metaName, shape.nullSafetyDisableArg);
				if (nullSafe && !facts.nonNullVisible(receiver.name)) violation.declineReason = UNSEEN_REASON;
				violations.push(violation);
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final marker: String = '?.';
		return RunScan.spanEdits(violations, (violation, span) -> {
			final rel: Int = source.substring(span.from, span.to).indexOf(marker);
			if (violation.declineReason != null || rel < 0) return null;
			final at: Int = span.from + rel;
			return { span: new Span(at, at + marker.length), text: '.' };
		});
	}

	/**
	 * Whether a `--macro nullSafety(…)` in one of `file`'s compiler-oracle hxmls, or in an hxml one of them includes, turns
	 * null-safety on for `module`. An hxml that cannot be read — not generated yet — cannot rule the macro out, so it counts
	 * as on; a project with no oracle has no build to read, and counts as off. `texts` memoises each hxml for the run.
	 */
	private function underNullSafetyMacro(file: String, module: String, texts: Map<String, Null<String>>): Bool {
		function covers(hxml: String, base: String, depth: Int): Bool {
			if (!texts.exists(hxml)) texts[hxml] = try File.getContent(hxml) catch (exception: Exception) null;
			final text: Null<String> = texts[hxml];
			if (text == null) return true;
			for (raw in text.split('\n')) {
				final line: String = raw.trim();
				if (
					line.endsWith('.hxml') && depth < MAX_INCLUDE_DEPTH
					&& covers(LintConfig.resolveAgainstConfigDir(base, line), base, depth + 1)
				)
					return true;
				if (NULL_SAFETY_MACRO.match(line) && macroCovers(module, [for (arg in NULL_SAFETY_MACRO.matched(1).split(',')) arg.trim()]))
					return true;
			}
			return false;
		}
		return LintConfig.resolveWith(_resolveConfig, file)
			.compilerOracles()
			.exists(oracle -> covers(oracle.hxml, oracle.dir ?? Path.directory(oracle.hxml), 0));
	}

	/**
	 * Whether a `nullSafety(path, mode, recursive)` call with these `args` covers `module`: `''` names every module, a
	 * module path names itself, and a package names its modules and — unless `recursive` is `false` — its sub-packages'.
	 * Mode `Off` covers nothing.
	 */
	private static function macroCovers(module: String, args: Array<String>): Bool {
		if (args.length > 1 && args[1].endsWith('Off')) return false;
		final path: String = QUOTES.replace(args[0], '');
		final recursive: Bool = args.length <= 2 || args[2] != 'false';
		if (module == path) return true;
		final dot: Int = module.lastIndexOf('.');
		final pkg: String = dot < 0 ? '' : module.substring(0, dot);
		return pkg == path || recursive && (path == '' || module.startsWith('$path.'));
	}

}
