package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.LintConfig.ConfigNote;
import anyparse.check.scan.CheckScan;
import anyparse.query.LintBaseline;
import anyparse.query.LintDiff;
import anyparse.query.NodeShape;
import anyparse.query.StringFold.ConcatSegment;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TokenSpans.TokenKind;
import anyparse.query.TokenSpans.TokenSpan;
import haxe.Exception;
import haxe.io.Path;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

using anyparse.util.Arrays;
using StringTools;

/** The option lists the rule reads. */
private typedef SyntaxOptions = {
	final roots: Array<String>;
	final sinks: Array<String>;
	final spanField: String;
	final textField: String;
	final baseline: Null<String>;
}

/** The grammar seams the scan reads, resolved once per run. */
private typedef SyntaxSeams = {
	final shape: RefShape;
	final callKind: String;
	final fieldAccessKind: String;
	final objectLiteralKind: String;
	final objectFieldKind: String;
	final returnKind: String;
	final functionKinds: Array<String>;
	final nestedBodyKinds: Array<String>;
	final typeDeclKinds: Array<String>;
	final containerKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final additiveKinds: Array<String>;
	final ternaryKind: Null<String>;
	final parenKind: Null<String>;
	final fold: StringFoldSupport;
}

/** One file's scan: the seams, the options, the text and the helpers that return syntax. */
private typedef SyntaxScan = {
	final seams: SyntaxSeams;
	final options: SyntaxOptions;
	final plugin: GrammarPlugin;
	final source: String;
	final file: String;
	final helpers: Map<String, QueryNode>;
	final reported: Map<String, Bool>;
}

/** What an expression reaching an edit holds: the syntax a literal spells, or the helper that returns it. */
private typedef SyntaxHit = { final helper: Null<String>; final spelled: String; }

/**
 * Flags the text of an EDIT that spells syntax of the grammar it edits, in a project that wants a fix to describe what
 * it needs and a grammar component to spell it. Report-only and off by default: what a project builds edits out of is
 * its own policy, so it names where the rule looks.
 *
 *     "fix-text-syntax": { "roots": ["src/anyparse/check"], "sinks": ["AddMember.memberEdit"], "baseline": "known.json" }
 *
 * An edit is an object literal that sets the `span` and the `text` field (`spanField`, `textField`). Its text SPELLS
 * SYNTAX when a literal part of it — a string literal or an interpolated one, written there directly, joined by `+`
 * or a ternary, or held by a local the text names — carries a token of the grammar's own vocabulary
 * (`GrammarPlugin.tokenSpans`: a keyword, a delimiter, an operator). Whitespace, a name and a hole spell none, so a
 * deletion, a copied source span, a rename and a line break are silent. No list of words is kept here: the grammar that
 * parsed the file says what its tokens are.
 *
 * ## One hop through a helper
 *
 * A function of the same file whose `return` holds such a literal is a syntax HELPER. It is reported when its call
 * is the text of an edit or an argument of a `sinks` call (the dotted callee spelling, `AddMember.memberEdit`),
 * directly or through a local that holds the result — the shape a fix takes when it builds a member in one function and
 * hands it to the insert in another. A builder that spans two calls, or a helper in another file, is not followed.
 *
 * A helper is found only through a BARE identifier call (`this.h()` and `T.h()` are silent: a name
 * before a dot needs type resolution), and a local's initializer is the FIRST declaration
 * of that name in the enclosing function, with no scope resolution, so a shadowed
 * or later re-declared local can be misread.
 *
 * ## The baseline
 *
 * Each finding carries its identity as data (the type and function it sits in, the literal part it spells), so a
 * snapshot of `apq lint --format json` identifies a site however lines move. The `baseline` option names such a snapshot,
 * resolved beside each `apq.json` of the file's chain, and the rule then reports only the sites it does not hold: a
 * project adopts the rule with its standing sites recorded and sees new ones only.
 *
 * ## No autofix
 *
 * The rewrite is a call into a grammar component that builds the construct — there is no text to substitute for the
 * literal, so the fix seam yields nothing.
 */
@:nullSafety(Strict)
final class FixTextSyntax extends RuleBase implements ConfigAware implements DefaultOff implements FileGated implements NoAutofix
		implements OptionKeyed {

	/** This check's `id()`, and the `rule` every finding carries. */
	private static inline final RULE_ID: String = 'fix-text-syntax';

	private static inline final MAX_LOCAL_HOPS: Int = 2;
	private static inline final EXCERPT_LEN: Int = 40;
	private static final FAMILY_LITERAL: String = 'literal';
	private static final FAMILY_HELPER: String = 'helper';
	private static final ROOTS_KEY: String = 'roots';
	private static final SINKS_KEY: String = 'sinks';
	private static final SPAN_FIELD_KEY: String = 'spanField';
	private static final TEXT_FIELD_KEY: String = 'textField';
	private static final BASELINE_KEY: String = 'baseline';
	private static final DEFAULT_SPAN_FIELD: String = 'span';
	private static final DEFAULT_TEXT_FIELD: String = 'text';

	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID,
			'edit text that spells syntax of the grammar it edits — a fix describes what it needs and a grammar component spells it',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/** `needs-config` while no `roots` are named, `outside-roots` for a file none of them holds. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		final options: Null<SyntaxOptions> = declared(config);
		if (options == null) return 'needs-config';
		return within(file, options.roots) ? null : 'outside-roots';
	}

	public function noAutofixReason(): String {
		return 'the replacement is a call into a grammar component that builds the construct, not a text that can stand in for the literal';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final snapshots: Map<String, LintDiffTally> = [];
		return RunScan.collectWith(files, plugin, seamsOf(plugin), (entry, tree, seams, out) -> {
			final options: Null<SyntaxOptions> = declared(LintConfig.resolveWith(_resolveConfig, entry.file));
			if (options == null || !within(entry.file, options.roots)) return;
			final declaredOptions: SyntaxOptions = options;
			final scan: SyntaxScan = {
				seams: seams,
				options: declaredOptions,
				plugin: plugin,
				source: entry.source,
				file: entry.file,
				helpers: [],
				reported: []
			};
			collectHelpers(scan, tree);
			final found: Array<Violation> = [];
			visit(scan, tree, null, null, found);
			for (violation in unrecorded(found, entry.file, declaredOptions.baseline, snapshots, _configNotes)) out.push(violation);
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function acceptedOptions(): Array<String> {
		return [ROOTS_KEY, SINKS_KEY, SPAN_FIELD_KEY, TEXT_FIELD_KEY, BASELINE_KEY];
	}

	private static function declared(config: LintConfig): Null<SyntaxOptions> {
		final roots: Array<String> = config.stringListOption(RULE_ID, ROOTS_KEY) ?? [];
		return roots.length == 0 ? null : {
			roots: roots,
			sinks: config.stringListOption(RULE_ID, SINKS_KEY) ?? [],
			spanField: config.stringOption(RULE_ID, SPAN_FIELD_KEY) ?? DEFAULT_SPAN_FIELD,
			textField: config.stringOption(RULE_ID, TEXT_FIELD_KEY) ?? DEFAULT_TEXT_FIELD,
			baseline: config.stringOption(RULE_ID, BASELINE_KEY)
		};
	}

	private static function seamsOf(plugin: GrammarPlugin): Null<SyntaxSeams> {
		final shape: RefShape = plugin.refShape();
		final literalKind: Null<String> = shape.objectLiteralKind;
		final fieldKind: Null<String> = shape.objectFieldKind;
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final returnKind: Null<String> = shape.returnStatementKind;
		final fold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		final functions: Array<String> = shape.functionKinds ?? [];
		return callKind == null || fieldAccessKind == null || literalKind == null || fieldKind == null || returnKind == null || fold == null
			|| functions.length == 0
			? null
			: {
				shape: shape,
				callKind: callKind,
				fieldAccessKind: fieldAccessKind,
				objectLiteralKind: literalKind,
				objectFieldKind: fieldKind,
				returnKind: returnKind,
				functionKinds: functions,
				nestedBodyKinds: functions.concat(shape.lambdaKinds ?? []),
				typeDeclKinds: shape.typeDeclKinds ?? [],
				containerKinds: shape.visibilityContainerKinds ?? [],
				localDeclKinds: shape.localDeclKinds ?? [],
				additiveKinds: shape.additiveKinds ?? [],
				ternaryKind: shape.ternaryKind,
				parenKind: shape.parenKind,
				fold: fold
			};
	}

	/** Whether `file` sits under one of the `roots` directories, whatever the directory the run started in. */
	private static function within(file: String, roots: Array<String>): Bool {
		final path: String = '/${Path.normalize(file)}';
		return roots.exists(root -> path.contains('/${Path.removeTrailingSlashes(root)}/'));
	}

	private static function collectHelpers(scan: SyntaxScan, node: QueryNode): Void {
		final name: Null<String> = node.name;
		if (
			name != null && scan.seams.functionKinds.contains(node.kind) && !scan.helpers.exists(name)
		) for (value in returnedValues(scan, node)) if (classify(scan, value, node, 0, false) != null) {
			scan.helpers[name] = node;
			break;
		}
		for (child in node.children) collectHelpers(scan, child);
	}

	/** The values `return` hands back from `fn`'s own body, a nested function's or lambda's excluded. */
	private static function returnedValues(scan: SyntaxScan, fn: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		for (child in fn.children) gatherReturns(scan, child, out);
		return out;
	}

	private static function gatherReturns(scan: SyntaxScan, node: QueryNode, out: Array<QueryNode>): Void {
		if (scan.seams.nestedBodyKinds.contains(node.kind)) return;
		final value: Null<QueryNode> = NodeShape.returnValueOf(node, scan.seams.returnKind);
		if (value != null) out.push(value);
		for (child in node.children) gatherReturns(scan, child, out);
	}

	private static function visit(
		scan: SyntaxScan, node: QueryNode, owner: Null<String>, host: Null<QueryNode>, out: Array<Violation>
	): Void {
		final seams: SyntaxSeams = scan.seams;
		final here: Null<String> = seams.typeDeclKinds.contains(node.kind) ? CheckScan.typeDeclName(node, seams.containerKinds) : owner;
		final enclosing: Null<QueryNode> = host ?? (seams.functionKinds.contains(node.kind) && node.name != null ? node : null);
		if (node.kind == seams.objectLiteralKind)
			editText(scan, node, here, enclosing, out);
		else if (node.kind == seams.callKind)
			sinkArguments(scan, node, here, enclosing, out);
		for (child in node.children) visit(scan, child, here, enclosing, out);
	}

	private static function editText(
		scan: SyntaxScan, literal: QueryNode, owner: Null<String>, host: Null<QueryNode>, out: Array<Violation>
	): Void {
		final text: Null<QueryNode> = fieldValue(scan, literal, scan.options.textField);
		if (text == null || fieldValue(scan, literal, scan.options.spanField) == null) return;
		final hit: Null<SyntaxHit> = classify(scan, text, host, 0, true);
		if (hit != null) report(scan, text, hit, 'edit text', owner, host, out);
	}

	private static function sinkArguments(
		scan: SyntaxScan, call: QueryNode, owner: Null<String>, host: Null<QueryNode>, out: Array<Violation>
	): Void {
		if (scan.options.sinks.length == 0) return;
		final seams: SyntaxSeams = scan.seams;
		final callee: String = NodeShape.calleePath(call.children[0], seams.fieldAccessKind, seams.shape.identKind).join('.');
		if (!scan.options.sinks.contains(callee)) return;
		for (at in 1...call.children.length) {
			final argument: QueryNode = call.children[at];
			final hit: Null<SyntaxHit> = classify(scan, argument, host, 0, true);
			if (hit != null) report(scan, argument, hit, callee, owner, host, out);
		}
	}

	private static function fieldValue(scan: SyntaxScan, literal: QueryNode, field: String): Null<QueryNode> {
		final entry: Null<QueryNode> = literal.children.find(child -> child.kind == scan.seams.objectFieldKind && child.name == field);
		return entry == null || entry.children.length == 0 ? null : entry.children[0];
	}

	/**
	 * What `expr` holds when it spells syntax: the first literal part carrying a grammar token, found through
	 * a concatenation, a ternary's branches, parentheses and (up to `MAX_LOCAL_HOPS`) a local's initializer; or, when `calls`
	 * is set, a call of a helper of this file that returns syntax.
	 */
	private static function classify(scan: SyntaxScan, expr: QueryNode, host: Null<QueryNode>, hops: Int, calls: Bool): Null<SyntaxHit> {
		final seams: SyntaxSeams = scan.seams;
		final segments: Null<Array<ConcatSegment>> = seams.fold.segmentsOf(expr, scan.source);
		if (segments != null) return spelledIn(scan, segments);
		if (expr.kind == seams.callKind) {
			final callee: QueryNode = expr.children[0];
			final name: Null<String> = callee.name;
			return calls && callee.kind == seams.shape.identKind && name != null && scan.helpers.exists(name)
				? { helper: name, spelled: name }
				: null;
		}
		if (expr.kind == seams.shape.identKind) {
			final name: Null<String> = expr.name;
			final init: Null<QueryNode> = host == null || name == null || hops >= MAX_LOCAL_HOPS ? null : localInit(scan, host, name);
			return init == null ? null : classify(scan, init, host, hops + 1, calls);
		}
		for (branch in operandsOf(seams, expr)) {
			final hit: Null<SyntaxHit> = classify(scan, branch, host, hops, calls);
			if (hit != null) return hit;
		}
		return null;
	}

	/** The operands a string can flow through: a ternary's branches, a concatenation's sides, a parenthesised value. */
	private static function operandsOf(seams: SyntaxSeams, expr: QueryNode): Array<QueryNode> {
		return if (expr.kind == seams.ternaryKind)
			expr.children.slice(1)
		else if (seams.additiveKinds.contains(expr.kind) || expr.kind == seams.parenKind)
			expr.children
		else
			[];
	}

	private static function localInit(scan: SyntaxScan, host: QueryNode, name: String): Null<QueryNode> {
		return scan.seams.localDeclKinds.contains(host.kind) && host.name == name
			? NodeShape.initOf(host)
			: host.children.findMap(child -> localInit(scan, child, name));
	}

	private static function spelledIn(scan: SyntaxScan, segments: Array<ConcatSegment>): Null<SyntaxHit> {
		for (segment in segments) switch segment {
			case SegText(_, raw):
				final fragment: String = raw.trim();
				if (fragment != '' && holdsToken(scan, fragment)) return { helper: null, spelled: excerpt(fragment) };
			case SegIdent(_), SegExpr(_, _):
		}
		return null;
	}

	/** Whether the grammar reads a token of its own vocabulary — a declared literal — inside `fragment`. */
	private static function holdsToken(scan: SyntaxScan, fragment: String): Bool {
		final tokens: Array<TokenSpan> = scan.plugin.tokenSpans(fragment, 0, fragment.length);
		return tokens.exists(token -> token.kind == TokenKind.Literal);
	}

	private static function excerpt(fragment: String): String {
		final line: String = fragment.split('\n').join(' ');
		return line.length > EXCERPT_LEN ? '${line.substr(0, EXCERPT_LEN)}…' : line;
	}

	private static function report(
		scan: SyntaxScan, at: QueryNode, hit: SyntaxHit, sink: String, owner: Null<String>, host: Null<QueryNode>, out: Array<Violation>
	): Void {
		final helper: Null<String> = hit.helper;
		final site: Null<QueryNode> = helper == null ? at : scan.helpers[helper];
		final span: Null<Span> = site?.span;
		if (span == null) return;
		final subject: String = helper == null ? hit.spelled : '$helper -> $sink';
		final member: String = (owner ?? '') + '.' + (helper ?? host?.name ?? '');
		final key: String = '$member#$subject#${span.from}';
		if (scan.reported.exists(key)) return;
		scan.reported[key] = true;
		out.push({
			file: scan.file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Info,
			message: helper == null
				? 'the text of this edit spells syntax of the grammar it edits (`${hit.spelled}'
					+ '`) — a fix names what it needs and a grammar component spells it'
				: 'helper `$helper` returns text that spells syntax of the grammar it edits, and its result reaches $sink'
					+ ' — a fix names what it needs and a grammar component spells it',
			data: {
				family: helper == null ? FAMILY_LITERAL : FAMILY_HELPER,
				member: member,
				subject: subject,
				chain: []
			}
		});
	}

	/**
	 * `found` without the sites the snapshot at `baseline` already records, the path resolved beside each `apq.json` of the
	 * file's chain. A missing or unreadable snapshot records nothing, so every site is reported.
	 */
	private static function unrecorded(
		found: Array<Violation>, file: String, baseline: Null<String>, cache: Map<String, LintDiffTally>, notes: Null<Array<ConfigNote>>
	): Array<Violation> {
		#if (sys || nodejs)
		if (baseline == null || found.length == 0) return found;
		final snapshot: String = baseline;
		final documents: Array<String> = Path.isAbsolute(snapshot)
			? ['']
			: ConfigNotes.into(notes, n -> LintConfig.discoverChain(file, n)).chain;
		for (document in documents) {
			final directory: String = Path.directory(document);
			final path: String = Path.isAbsolute(snapshot) ? snapshot : Path.join([directory, snapshot]);
			if (!FileSystem.exists(path)) continue;
			final recorded: Null<LintDiffTally> = cache[path] ?? tallyOf(path, cache);
			return recorded == null ? found : LintBaseline.added(found, recorded, directory, []);
		}
		#end
		return found;
	}

	#if (sys || nodejs)
	private static function tallyOf(path: String, cache: Map<String, LintDiffTally>): Null<LintDiffTally> {
		final tally: Null<LintDiffTally> = try {
			LintDiff.tally(LintDiff.parseReport(File.getContent(path)), '', []);
		} catch (exception: Exception) {
			null;
		};
		if (tally != null) cache[path] = tally;
		return tally;
	}
	#end

}
