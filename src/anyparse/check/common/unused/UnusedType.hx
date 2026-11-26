package anyparse.check.common.unused;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FrameworkAware;
import anyparse.check.Check.NoAutofix;
import anyparse.check.scan.PublicReach;
import anyparse.query.NamingPolicy.FrameworkContract;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.SafeDeleteType;
import anyparse.query.SymbolIndex;

/**
 * The one answer to "which type declaration does nothing in the project reference": a class, interface, enum, typedef
 * or abstract whose name occurs nowhere in report UNION resolution scope outside its own declaration, and whose removal
 * `SafeDeleteType` proves safe. The type-level sibling of `unused-public-member`. `Warning`, DEFAULT OFF, report-only:
 * the finding is deleted with `safe-delete <file> --scope <dir> --type <T>`, which removes the module when the type is
 * alone in it.
 *
 * ## RUN IT WHOLE-PROJECT
 *
 * Every proof reads the file set the lint was given: a subdirectory run is a preview, a reference in an unlinted file
 * reads as absent.
 *
 * ## The proof
 *
 * A global identifier-token count (`PublicReach.tokenCounts`) must equal the count inside the type's own declaration,
 * which clears almost every type cheaply; only the survivors pay `SafeDeleteType`'s whole-scope reading (type-namespace
 * occurrences, an opaque `#if` region, a string or class value that may reach the type at run time, `@:keep` /
 * `@:expose`, a bare enum constructor, a `using` extension, a same-named type elsewhere).
 *
 * ## Gates — any of these and the type is never reported
 *
 * - `@:keep`, `@:build` or `extern` on the type, a hierarchy carrying RTTI, an ancestor carrying `@:autoBuild`, or a
 *   supertype that does not resolve (`PublicReach.chainOutOfReach`).
 * - A type the build names with no written reference (`BuildNamedTypes`): the `-main` module, an identifier of a
 *   `--macro` argument, or a package an `include('pkg')` argument names, in any `.hxml` under the project root.
 * - A class with a `main` function: an entry point of a project that declares no hxml.
 * - A class a FRAMEWORK drives with no written reference: any member `NamingSupport.frameworkReachable` accepts (a
 *   utest test class, a type of a contract the project declares in `apq.json` `frameworks`).
 */
@:nullSafety(Strict)
final class UnusedType extends RuleBase implements DefaultOff implements ConfigAware implements FrameworkAware implements NoAutofix {

	/** This check's stable id. */
	private static inline final RULE_ID: String = 'unused-type';

	/** The function the build arguments name as the program's entry, reached with no written call. */
	private static final ENTRY_POINT: String = 'main';

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'a type declaration nothing in scope references — dead weight that still reads like live code', RuleCategory.Unused);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/** No edit: the removal is a whole-scope operation that can delete a file, which a per-file fix cannot express. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'a type may be the only one in its module, so its removal deletes a file; `safe-delete <file> --scope <dir> --type <T>`'
			+ ' does it with the whole-scope proof';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final reach: ReachScope = PublicReach.scopeOf(files, plugin);
		final naming: Null<NamingSupport> = plugin.namingSupport();
		final contracts: Array<FrameworkContract> = LintConfig.frameworksFor(_resolveConfig, files);
		final build: BuildNamedTypes = BuildNamedTypes.read(files);
		return RunScan.collect(
			files, plugin, (entry, tree, out) -> PublicReach.eachType(reach, entry.file, (scope, host, declared) -> {
				if (PublicReach.typeOutOfReach(declared)) return;
				if (build.names(declared.name, host.pkg)) return;
				if (!occursOnlyInOwnDeclaration(declared, entry.source, reach.tokens, reach.index, entry.file)) return;
				if (PublicReach.chainOutOfReach(scope, host, declared, true)) return;
				if (drivenWithoutReference(tree, declared.name, naming, contracts, scope)) return;
				final verdict: SafeDeleteTypeResult = SafeDeleteType.safeDeleteType(
					entry.file, declared.name, false, files, plugin, '.', []
				);
				if (verdict.match(Refused(_))) return;
				out.push({
					file: entry.file,
					span: declared.span,
					rule: RULE_ID,
					severity: Severity.Warning,
					message: 'unused type ${declared.name}: no reference to it anywhere in scope'
				});
			})
		);
	}

	private static function occursOnlyInOwnDeclaration(
		declared: TypeDeclInfo, source: String, tokens: Map<String, Int>, index: SymbolIndex, file: String
	): Bool {
		return PublicReach.occursOnlyWithin(declared.name, tokens, [{ file: file, source: source, span: declared.span }], index);
	}

	/** Whether the class named `typeName` holds an entry point or a member a framework reaches with no written call. */
	private static function drivenWithoutReference(
		tree: QueryNode, typeName: String, naming: Null<NamingSupport>, contracts: Array<FrameworkContract>, scope: SymbolIndex
	): Bool {
		for (cls in CheckScan.classBodies(tree)) if (cls.name == typeName) for (member in functionsOf(cls)) {
			final name: Null<String> = member.name;
			final span: Null<Span> = member.span;
			if (name == null || span == null) continue;
			if (name == ENTRY_POINT) return true;
			if (CheckScan.frameworkReachableMethod(naming, name, typeName, span, () -> scope, contracts, false)) return true;
		}
		return false;
	}

	/** The functions declared in `container`, those inside a conditional region included. */
	private static function functionsOf(container: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		for (child in container.children) {
			if (MemberKinds.FN_DECL_KINDS.contains(child.kind))
				out.push(child);
			else if (child.kind == MemberKinds.CONDITIONAL_REGION_KIND)
				for (inner in functionsOf(child)) out.push(inner);
		}
		return out;
	}

}
