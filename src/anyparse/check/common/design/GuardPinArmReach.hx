package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.common.design.RuleDeclaration.ArmTarget;
import anyparse.query.MemberKinds;
import anyparse.query.Meta;
import anyparse.query.SourceText;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;
import haxe.Exception;
import haxe.io.Path;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * Flags a test pinned as a GUARD (`@:pin('guard')`) whose class names a mutation arm (`@:killer('<ARM>')` on a sibling — one the test
 * does not name itself) that cuts a member this test calls: a cut that reaches the test can kill it, so the guard pin may be hiding
 * a control. Inert until the project names the pin, the killer and the arm registry in `apqlint.json`:
 *
 *     "guard-pin-arm-reach": { "pinMeta": "@:pin", "guardArgument": "guard", "killerMeta": "@:killer",
 *         "armRegistry": "testkit/mutation-arms.json" }
 *
 * The registry is a JSON document whose `arms` array holds `{name, type, method}` records; a relative path is resolved
 * against the directory of each `apqlint.json` of the file's chain, nearest first, and read once
 * per run. A test reaches an arm when its body names both the arm's `method` and the last segment
 * of its `type` (an identifier, a field or a constructed type) — a spelling match, which is why
 * the rule is `Info`, default-off and report-only. Grammar-agnostic over `MetaShape` and `RefShape`.
 */
@:nullSafety(Strict)
final class GuardPinArmReach extends RuleBase implements ConfigAware implements FileGated implements DefaultOff implements NoAutofix {

	/** The rule id, also the `apqlint.json` option key. */
	private static inline final RULE_ID: String = 'guard-pin-arm-reach';

	private static inline final PIN_KEY: String = 'pinMeta';
	private static inline final GUARD_KEY: String = 'guardArgument';
	private static inline final KILLER_KEY: String = 'killerMeta';
	private static inline final REGISTRY_KEY: String = 'armRegistry';

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID, 'a test pinned as a guard that calls a member a mutation arm of its own class cuts — the arm may kill it',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/** `needs-config` while the file's config does not name the pin, the guard argument, the killer and the registry. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return declared(config) == null ? 'needs-config' : null;
	}

	public function noAutofixReason(): String {
		return 'whether the test is a guard or a control is the author\'s call';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final fold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		final shape: RefShape = plugin.refShape();
		final registries: Map<String, Map<String, ArmTarget>> = [];
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			final options: Null<PinOptions> = declared(LintConfig.resolveWith(_resolveConfig, entry.file));
			final arms: Null<Map<String, ArmTarget>> = options == null ? null : registryFor(entry.file, options.registry, registries);
			if (options == null || arms == null || fold == null) return;
			final declaredOptions: PinOptions = options;
			final declaredArms: Map<String, ArmTarget> = arms;
			final declaredFold: StringFoldSupport = fold;
			final scan: PinScan = {
				options: declaredOptions,
				arms: declaredArms,
				fold: declaredFold,
				shape: shape,
				metaShape: plugin.metaShape(),
				root: tree,
				file: entry.file,
				source: entry.source
			};
			eachClass(scan, tree, out);
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	/** The four options of `config`, or null while any is absent or empty. */
	private static function declared(config: LintConfig): Null<PinOptions> {
		final pin: String = config.stringOption(RULE_ID, PIN_KEY) ?? '';
		final guard: String = config.stringOption(RULE_ID, GUARD_KEY) ?? '';
		final killer: String = config.stringOption(RULE_ID, KILLER_KEY) ?? '';
		final registry: String = config.stringOption(RULE_ID, REGISTRY_KEY) ?? '';
		return pin == '' || guard == '' || killer == '' || registry == '' ? null : {
			pin: pin,
			guard: guard,
			killer: killer,
			registry: registry
		};
	}

	/** Visit every class-like declaration under `node` and report its guard pins an arm of the class reaches. */
	private static function eachClass(scan: PinScan, node: QueryNode, out: Array<Violation>): Void {
		if (MemberKinds.classLikeContainerKinds(scan.shape).contains(node.kind)) checkClass(scan, node, out);
		for (child in node.children) eachClass(scan, child, out);
	}

	/**
	 * Report each guard-pinned member of `container` whose body names a member an arm the container names cuts — an arm the
	 * guard names itself is a declared kill, not a hidden one, and is left out.
	 */
	private static function checkClass(scan: PinScan, container: QueryNode, out: Array<Violation>): Void {
		final hits: Array<MetaHit> = Meta.find(container, scan.metaShape, scan.source);
		final killers: Array<{ decl: Int, arm: ArmTarget }> = [];
		for (hit in hits) if (hit.annotation == scan.options.killer) {
			final arm: Null<ArmTarget> = scan.arms[argumentOf(scan, hit) ?? ''];
			if (arm != null) killers.push({ decl: hit.declSpan?.from ?? -1, arm: arm });
		}
		if (killers.length == 0) return;
		for (hit in hits) {
			final declSpan: Null<Span> = hit.declSpan;
			final metaSpan: Null<Span> = hit.metaSpan;
			if (hit.annotation != scan.options.pin || argumentOf(scan, hit) != scan.options.guard || declSpan == null || metaSpan == null)
				continue;
			final decl: Null<QueryNode> = TreePath.withSpan(container, declSpan);
			if (decl == null) continue;
			final guarded: QueryNode = decl;
			final own: Array<String> = [for (k in killers) if (k.decl == declSpan.from) k.arm.name];
			final reached: Null<{ decl: Int, arm: ArmTarget }> = killers.find(
				k ->
					!own.contains(k.arm.name)
					&& names(scan, guarded, k.arm.method)
					&& names(scan, guarded, SourceText.lastSegment(k.arm.type))
			);
			if (reached != null) out.push({
				file: scan.file,
				span: metaSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'guard pin on \'${hit.declName}\', but arm ${reached.arm.name} of this class cuts ${reached.arm.type}.'
				+ '${reached.arm.method}, which it calls — an arm that can kill it makes it a control'
			});
		}
	}

	/** The decoded string value of `hit`'s sole argument, or null when it has no single plain string literal argument. */
	private static function argumentOf(scan: PinScan, hit: MetaHit): Null<String> {
		final span: Null<Span> = hit.metaSpan;
		final meta: Null<QueryNode> = span == null ? null : TreePath.withSpan(scan.root, span);
		if (meta == null || meta.children.length != 1) return null;
		final literal: Null<StringLiteral> = scan.fold.literalOf(meta.children[0], scan.source);
		return literal == null ? null : scan.fold.valueOf(literal);
	}

	/** Whether `node`'s subtree names `member` as an identifier, a field read or a constructed type. */
	private static function names(scan: PinScan, node: QueryNode, member: String): Bool {
		return node.name == member
			&& (node.kind == scan.shape.identKind || node.kind == scan.shape.fieldAccessKind || node.kind == scan.shape.newExprKind)
			|| node.children.exists(child -> names(scan, child, member));
	}

	/**
	 * The arms of the registry `registry` names for `file` — the first existing path it resolves to against the
	 * directories of `file`'s config chain — read once per run into `cache`; null when none exists or it does not read.
	 */
	private static function registryFor(
		file: String, registry: String, cache: Map<String, Map<String, ArmTarget>>
	): Null<Map<String, ArmTarget>> {
		#if (sys || nodejs)
		final candidates: Array<String> = Path.isAbsolute(registry) ? [registry] : [
			for (document in LintConfig.discoverChain(file).chain) Path.join([Path.directory(document), registry])
		];
		for (path in candidates) {
			final known: Null<Map<String, ArmTarget>> = cache[path];
			if (known != null) return known;
			if (!FileSystem.exists(path)) continue;
			final read: Null<Map<String, ArmTarget>> = readArms(path);
			if (read != null) cache[path] = read;
			return read;
		}
		#end
		return null;
	}

	#if (sys || nodejs)
	/** The `arms` records of the registry at `path` by name; null when it cannot be read or holds no `arms` array. */
	private static function readArms(path: String): Null<Map<String, ArmTarget>> {
		final content: Null<String> = try File.getContent(path) catch (_: Exception) null;
		return content == null ? null : RuleDeclaration.armRegistry(content);
	}
	#end

}

/** The options the rule reads. */
typedef PinOptions = {
	final pin: String;
	final guard: String;
	final killer: String;
	final registry: String;
}

/** One file's scan: the options, the registry it resolved, and the seams, tree and text it reads. */
typedef PinScan = {
	final options: PinOptions;
	final arms: Map<String, ArmTarget>;
	final fold: StringFoldSupport;
	final shape: RefShape;
	final metaShape: MetaShape;
	final root: QueryNode;
	final file: String;
	final source: String;
}
