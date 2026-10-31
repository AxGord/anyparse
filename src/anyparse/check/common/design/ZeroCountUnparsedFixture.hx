package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.query.NodeShape;
import anyparse.query.ParseGate;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;
import anyparse.query.TypeResolver;

/**
 * Flags the fixture of a ZERO-COUNT assertion (`Assert.equals(0, violations(src).length)`) that the file's own grammar
 * does not parse: a lint run skips a file it cannot parse, so the zero may say only that, and the assertion passes
 * whatever the rule does. Inert until the project names the assertion and the fixture's destination in `apqlint.json`:
 *
 *     "zero-count-unparsed-fixture": { "zeroAsserts": ["Assert.equals"], "countFields": ["length"], "sourceFields": ["source"] }
 *
 * A zero-count assertion is a call of a `zeroAsserts` name (dotted callee spelling) whose first argument is the numeric
 * literal `0` and whose second reads a `countFields` field. A fixture is a plain string literal in that second
 * argument — written there, or held by a local it names — that REACHES a `sourceFields` object field unchanged: written
 * as the field's value, or passed as an argument to a function of the same file whose parameter reaches one. A value
 * concatenated or interpolated on the way is wrapped, and its parse is not this rule's question.
 * The optional `skipParseTests` names the functions whose unparseable fixture is the point (a
 * test that a skipped file yields nothing); none of their assertions is read. `Info`, default-off,
 * report-only: whether the fixture or the assertion is wrong is the author's call. Grammar-agnostic over `RefShape` and
 * `StringFoldSupport`.
 */
@:nullSafety(Strict)
final class ZeroCountUnparsedFixture extends RuleBase implements ConfigAware implements FileGated implements DefaultOff implements NoAutofix {

	/** The rule id, also the `apqlint.json` option key. */
	private static inline final RULE_ID: String = 'zero-count-unparsed-fixture';

	private static inline final ASSERTS_KEY: String = 'zeroAsserts';
	private static inline final COUNT_FIELDS_KEY: String = 'countFields';
	private static inline final SOURCE_FIELDS_KEY: String = 'sourceFields';
	private static inline final SKIP_PARSE_TESTS_KEY: String = 'skipParseTests';

	/** How many same-file helper calls a fixture is followed through before the trace gives up. */
	private static inline final MAX_HOPS: Int = 3;

	/** A zero-count assertion carries a callee and at least two arguments. */
	private static inline final MIN_ASSERT_CHILDREN: Int = 3;

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID, 'a zero-count assertion whose fixture text the grammar does not parse — a skipped file also counts zero',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/** `needs-config` while the file's config does not name the assertion, the count field and the source field. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return declared(config) == null ? 'needs-config' : null;
	}

	public function noAutofixReason(): String {
		return 'whether the fixture or the assertion is wrong is the author\'s call';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, seamsOf(plugin), (entry, tree, seams, out) -> {
			final options: Null<FixtureOptions> = declared(LintConfig.resolveWith(_resolveConfig, entry.file));
			if (options == null) return;
			final declaredOptions: FixtureOptions = options;
			final scan: FixtureScan = {
				seams: seams,
				options: declaredOptions,
				plugin: plugin,
				root: tree,
				source: entry.source
			};
			final reported: Array<Int> = [];
			for (fixture in fixtures(scan, tree, null)) {
				final span: Null<Span> = fixture.span;
				if (span == null || reported.contains(span.from)) continue;
				reported.push(span.from);
				out.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'this fixture of a zero-count assertion does not parse — the file is skipped, so the zero proves nothing'
				});
			}
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	/** `node`'s literal when it is a plain string literal (no interpolation), else null. */
	private static inline function plainLiteral(scan: FixtureScan, node: QueryNode): Null<StringLiteral> {
		return scan.seams.fold.literalOf(node, scan.source);
	}

	/** The three option lists of `config`, or null while any is absent or empty. */
	private static function declared(config: LintConfig): Null<FixtureOptions> {
		final asserts: Array<String> = config.stringListOption(RULE_ID, ASSERTS_KEY) ?? [];
		final counts: Array<String> = config.stringListOption(RULE_ID, COUNT_FIELDS_KEY) ?? [];
		final sources: Array<String> = config.stringListOption(RULE_ID, SOURCE_FIELDS_KEY) ?? [];
		return asserts.length == 0 || counts.length == 0 || sources.length == 0 ? null : {
			asserts: asserts,
			countFields: counts,
			sourceFields: sources,
			skipParseTests: config.stringListOption(RULE_ID, SKIP_PARSE_TESTS_KEY) ?? []
		};
	}

	/** The kinds the scan reads, or null when the grammar leaves one unset or has no string-literal seam. */
	private static function seamsOf(plugin: GrammarPlugin): Null<FixtureSeams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final fieldKind: Null<String> = shape.objectFieldKind;
		final fold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		final numeric: Array<String> = shape.numericLiteralKinds ?? [];
		return callKind == null || fieldAccessKind == null || fieldKind == null || fold == null || numeric.length == 0 ? null : {
			shape: shape,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			objectFieldKind: fieldKind,
			numericKinds: numeric,
			paramKinds: shape.paramKinds ?? [],
			memberDeclKinds: shape.memberDeclKinds ?? [],
			localDeclKinds: shape.localDeclKinds ?? [],
			fold: fold
		};
	}

	/**
	 * Every fixture literal of every zero-count assertion under `node` that the grammar does not parse, outside the
	 * `skipParseTests` functions; `member` is the member function `node` sits in.
	 */
	private static function fixtures(scan: FixtureScan, node: QueryNode, member: Null<String>): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		final inside: Null<String> = scan.seams.memberDeclKinds.contains(node.kind) ? node.name : member;
		if (inside != null && scan.options.skipParseTests.contains(inside)) return out;
		final counted: Null<QueryNode> = countedOperand(scan, node);
		if (counted != null) for (value in valuesUnder(scan, counted)) {
			final literal: Null<QueryNode> = literalOf(scan, value);
			if (literal != null && reachesSource(scan, scan.root, value, 0) && !parses(scan, literal)) out.push(literal);
		}
		for (child in node.children) for (found in fixtures(scan, child, inside)) out.push(found);
		return out;
	}

	/** The receiver of the counted field when `node` is a zero-count assertion, else null. */
	private static function countedOperand(scan: FixtureScan, node: QueryNode): Null<QueryNode> {
		final seams: FixtureSeams = scan.seams;
		if (node.kind != seams.callKind || node.children.length < MIN_ASSERT_CHILDREN) return null;
		final callee: String = NodeShape.calleePath(node.children[0], seams.fieldAccessKind, seams.shape.identKind).join('.');
		if (!scan.options.asserts.contains(callee)) return null;
		final zero: QueryNode = node.children[1];
		final count: QueryNode = node.children[2];
		final field: Null<String> = count.name;
		return seams.numericKinds.contains(zero.kind)
			&& zero.name == '0'
			&& count.kind == seams.fieldAccessKind
			&& field != null
			&& scan.options.countFields.contains(field)
			&& count.children.length == 1
			? count.children[0]
			: null;
	}

	/** Every node under `node` that may carry a fixture: a string literal, or an identifier naming a local. */
	private static function valuesUnder(scan: FixtureScan, node: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		if (node.kind == scan.seams.shape.identKind || plainLiteral(scan, node) != null) out.push(node);
		for (child in node.children) for (found in valuesUnder(scan, child)) out.push(found);
		return out;
	}

	/** The string literal `value` is, or the one initializing the local it names; null for anything else. */
	private static function literalOf(scan: FixtureScan, value: QueryNode): Null<QueryNode> {
		if (plainLiteral(scan, value) != null) return value;
		final name: Null<String> = value.name;
		final span: Null<Span> = value.span;
		if (name == null || span == null) return null;
		final binding: Null<QueryNode> = TypeResolver.resolveBindingHit(name, span, scan.root, scan.seams.shape)?.bindingNode;
		if (binding == null || !scan.seams.localDeclKinds.contains(binding.kind) || binding.children.length == 0) return null;
		final init: QueryNode = binding.children[binding.children.length - 1];
		return plainLiteral(scan, init) != null ? init : null;
	}

	/** Whether the text `literal` denotes parses under the file's grammar; a literal whose value is unknown is let pass. */
	private static function parses(scan: FixtureScan, literal: QueryNode): Bool {
		final raw: Null<StringLiteral> = plainLiteral(scan, literal);
		final text: Null<String> = raw == null ? null : scan.seams.fold.valueOf(raw);
		return text == null || ParseGate.parseOrNull(scan.plugin, text) != null;
	}

	/**
	 * Whether `value`, read inside `root`, lands unchanged on a `sourceFields` field: as the field's own value, or as an
	 * argument of a same-file function whose matching parameter does, followed at most `MAX_HOPS` calls deep.
	 */
	private static function reachesSource(scan: FixtureScan, root: QueryNode, value: QueryNode, hops: Int): Bool {
		final path: Null<Array<QueryNode>> = TreePath.pathAround(root, value);
		if (path == null || path.length < 2) return false;
		final parent: QueryNode = path[path.length - 2];
		final seams: FixtureSeams = scan.seams;
		final field: Null<String> = parent.name;
		if (parent.kind == seams.objectFieldKind) return field != null && scan.options.sourceFields.contains(field);
		if (parent.kind != seams.callKind || hops >= MAX_HOPS) return false;
		final at: Int = parent.children.indexOf(value) - 1;
		final callee: QueryNode = parent.children[0];
		final name: Null<String> = callee.name;
		if (at < 0 || callee.kind != seams.shape.identKind || name == null) return false;
		for (helper in functionsNamed(scan, scan.root, name)) {
			final params: Array<QueryNode> = helper.children.filter(c -> seams.paramKinds.contains(c.kind));
			final param: Null<String> = at < params.length ? params[at].name : null;
			if (param != null && readsOf(scan, helper, param).exists(read -> reachesSource(scan, helper, read, hops + 1))) return true;
		}
		return false;
	}

	/** Every member function of `node`'s subtree named `name`. */
	private static function functionsNamed(scan: FixtureScan, node: QueryNode, name: String): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		if (node.name == name && scan.seams.memberDeclKinds.contains(node.kind)) out.push(node);
		for (child in node.children) for (found in functionsNamed(scan, child, name)) out.push(found);
		return out;
	}

	/** Every identifier reading `name` under `node`. */
	private static function readsOf(scan: FixtureScan, node: QueryNode, name: String): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		if (node.kind == scan.seams.shape.identKind && node.name == name) out.push(node);
		for (child in node.children) for (found in readsOf(scan, child, name)) out.push(found);
		return out;
	}

}

/** The option lists the rule reads. */
typedef FixtureOptions = {
	final asserts: Array<String>;
	final countFields: Array<String>;
	final sourceFields: Array<String>;

	/** The functions whose unparseable fixture IS the point — a test that a skipped file yields nothing. */
	final skipParseTests: Array<String>;
}

/** The grammar seams the scan reads, resolved once per run. */
typedef FixtureSeams = {
	final shape: RefShape;
	final callKind: String;
	final fieldAccessKind: String;
	final objectFieldKind: String;
	final numericKinds: Array<String>;
	final paramKinds: Array<String>;
	final memberDeclKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final fold: StringFoldSupport;
}

/** One file's scan: the seams, the options, and the tree and text the fixtures are read from. */
typedef FixtureScan = {
	final seams: FixtureSeams;
	final options: FixtureOptions;
	final plugin: GrammarPlugin;
	final root: QueryNode;
	final source: String;
}
