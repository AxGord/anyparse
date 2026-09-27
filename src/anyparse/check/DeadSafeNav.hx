package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.check.NullFlowScan.IdentOperand;
import anyparse.query.DeclaredNullity;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
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
 * `fix` rewrites `?.`→`.`, the same rewrite `unnecessary-safe-nav` applies. Under null-safety (`@:nullSafety`
 * in scope, or an oracle build that may enable it) the compiler must see the proof too, so a receiver whose
 * proof it does not follow keeps its finding with a `declineReason` and no edit (`NullFacts.nonNullVisible`).
 */
@:nullSafety(Strict)
final class DeadSafeNav implements Check implements ConfigAware {

	/** The `declineReason` of a finding whose non-null proof the compiler's null-safety does not share. */
	private static inline final UNSEEN_REASON: String =
		'null-safety may be on here and does not follow this proof, so a plain `.` would not compile';

	/** How deep an oracle hxml's own `.hxml` includes are followed — a bound that ends an include cycle. */
	private static inline final MAX_INCLUDE_DEPTH: Int = 8;

	/**
	 * The hxml flags that cannot turn null-safety on: class paths, defines, the main class, a target and its output, and
	 * the switches that only tune a compile. A `--macro` or a `-lib` is absent on purpose — either can add `@:nullSafety`.
	 */
	private static final PLAIN_HXML_FLAGS: Array<String> = [
		'-cp',
		'-p',
		'--class-path',
		'-D',
		'--define',
		'-main',
		'-m',
		'--main',
		'-js',
		'--js',
		'-cpp',
		'--cpp',
		'-neko',
		'--neko',
		'-hl',
		'--hl',
		'--jvm',
		'-java',
		'--java',
		'-cs',
		'--cs',
		'-python',
		'--python',
		'-lua',
		'--lua',
		'-php',
		'--php',
		'-swf',
		'--swf',
		'--interp',
		'--no-output',
		'-debug',
		'--debug',
		'-dce',
		'--dce',
		'-v',
		'--verbose',
		'--times',
		'--no-traces',
		'--no-inline',
		'--no-opt',
		'-r',
		'--resource',
		'--each',
		'--next'
	];

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
		final buildMay: Map<String, Bool> = [];
		final index: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, RunScan.typeInfoOf(plugin), (entry, root, typed, violations) -> {
			final types: DeclaredNullity = DeclaredNullity.of(entry.file, root, entry.source, shape, typed, plugin.typeSyntax, index);
			final configDir: String = Path.directory(entry.file);
			if (!buildMay.exists(configDir)) buildMay[configDir] = buildMayEnableNullSafety(entry.file, hxmlText);
			final buildNullSafe: Bool = buildMay[configDir] == true;
			NullFlow.analyze(root, shape, entry.source, (node, facts) -> {
				if (node.kind != navKind || node.children.length != 1) return;
				final receiver: Null<IdentOperand> = NullFlowScan.identOperand(node, node.children[0], ident);
				if (receiver == null) return;
				// Owned by `unnecessary-safe-nav` when the declared type proves it.
				if (TypeResolver.isProvablyNonNull(receiver.operand, root, shape, types)) return;
				if (!facts.nonNull(receiver.name)) return;
				final violation: Violation = {
					file: entry.file,
					span: receiver.span,
					rule: 'dead-safe-nav',
					severity: Severity.Info,
					message: 'null-safe access is redundant — receiver is already non-null on this path'
				};
				final metaName: Null<String> = shape.nullSafetyMetaName;
				final nullSafe: Bool = buildNullSafe || metaName != null
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
	 * Whether one of `file`'s compiler-oracle builds may turn null-safety on beyond what the sources say. Read positively: a
	 * build is plain only when every line of its hxml, and of each hxml it includes, is blank, a comment, a module name or a
	 * `PLAIN_HXML_FLAGS` flag not mentioning `nullSafety`. A `--macro`, a `-lib` whose extraParams are not read, any other flag
	 * or an unreadable hxml counts as on. A project with no oracle has no build to read and counts as off.
	 */
	private function buildMayEnableNullSafety(file: String, texts: Map<String, Null<String>>): Bool {
		function mayEnable(hxml: String, base: String, depth: Int): Bool {
			if (!texts.exists(hxml)) texts[hxml] = try File.getContent(hxml) catch (exception: Exception) null;
			final text: Null<String> = texts[hxml];
			if (text == null) return true;
			for (raw in text.split('\n')) {
				final line: String = raw.trim();
				if (line == '' || line.startsWith('#')) continue;
				if (line.contains('nullSafety')) return true;
				if (line.endsWith('.hxml')) {
					if (depth >= MAX_INCLUDE_DEPTH || mayEnable(LintConfig.resolveAgainstConfigDir(base, line), base, depth + 1))
						return true;
				} else if (line.startsWith('-') && !PLAIN_HXML_FLAGS.contains(line.split(' ')[0]))
					return true;
			}
			return false;
		}
		return LintConfig.resolveWith(_resolveConfig, file)
			.compilerOracles()
			.exists(oracle -> mayEnable(oracle.hxml, oracle.dir ?? Path.directory(oracle.hxml), 0));
	}

}
