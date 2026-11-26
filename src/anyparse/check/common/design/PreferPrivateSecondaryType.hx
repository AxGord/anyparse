package anyparse.check.common.design;

import anyparse.check.Check.DefaultOff;
import anyparse.check.common.naming.NamingCrossRename;
import anyparse.check.common.unused.BuildNamedTypes;
import anyparse.check.scan.PublicReach;
import anyparse.query.SafeDeleteType;
import anyparse.query.SymbolIndex;

/**
 * The one answer to "which secondary type of a module is referenced by nothing outside that module, so it may be
 * `private`": a type that is not its module's main type and is not private yet, whose name occurs only inside its own
 * file anywhere in report UNION resolution scope. `Info`, DEFAULT OFF; run it whole-project, as a reference in an
 * unlinted file reads as absent.
 *
 * ## The proof
 *
 * A global identifier-token count (`PublicReach.tokenCounts`) must equal the count inside the module file, which clears
 * almost every type cheaply; only the survivors pay `SafeDeleteType.moduleExternalReasons`, the deletion's whole-scope
 * reading with the module counted as inside (an import or a qualified path of another file, an opaque `#if` region, a
 * string or class value that may reach the type at run time, a bare enum constructor, a `using` extension, a same-named
 * type elsewhere).
 *
 * ## Gates: any of these and the type is never reported
 *
 * - `@:keep`, `@:rtti`, `@:build` or `extern`, any metadata the grammar does not list as name-inert (`@:expose`,
 *   `@:native` included), a hierarchy carrying RTTI, an ancestor carrying `@:autoBuild`, a supertype that does not
 *   resolve, a declaration inside `#if`, a type the build names.
 *
 * ## Which kinds are rewritten
 *
 * A typedef, an abstract and an enum abstract have no runtime name: the fix inserts `private`. A plain enum, class and
 * interface take the path `pkg._Module.Name` once private, which `Type.resolveEnum` / `Type.resolveClass`,
 * `Type.getEnumName` / `Type.getClassName` and data `haxe.Serializer` saved earlier read: an enum is rewritten only
 * while no identifier of those APIs occurs in scope, a class or an interface is reported and left alone. A private type
 * in a public signature of the module's main type compiles, so that is no gate.
 */
@:nullSafety(Strict)
final class PreferPrivateSecondaryType extends RuleBase implements DefaultOff {

	private static inline final RULE_ID: String = 'prefer-private-secondary-type';

	/** The identifiers of the run-time type-name APIs: a private enum's path (`pkg._Module.Name`) is what they answer. */
	private static final RUNTIME_NAME_APIS: Array<String> = ['resolveEnum', 'getEnumName', 'getEnum', 'Serializer', 'Unserializer'];

	private static final RUNTIME_NAME_DECLINE: String = 'the project uses `Type.resolveEnum` / `getEnumName` / `Serializer`, which see '
		+ 'the run-time path `pkg._Module.Name` a private enum takes';
	private static final CLASS_DECLINE: String = 'a private class or interface takes the run-time path `pkg._Module.Name`, which'
		+ ' `Type.resolveClass`, `getClassName` and saved `haxe.Serializer` data read';
	private static final PRIVATE_KEYWORD: String = 'private ';

	public function new() {
		super(RULE_ID, 'a secondary type nothing outside its module refers to — it may be private', RuleCategory.Design);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final reach: ReachScope = PublicReach.scopeOf(files, plugin);
		final build: BuildNamedTypes = BuildNamedTypes.read(files);
		final runtimeNames: Bool = usesRuntimeNames(files, reach.wide);
		final shape: RefShape = plugin.refShape();
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			final module: Array<ReachRegion> = [{
				file: entry.file,
				source: entry.source,
				span: new Span(0, entry.source.length)
			}];
			PublicReach.eachType(reach, entry.file, (scope, host, declared) -> {
				if (declared.isMain || declared.isPrivate || declared.guarded) return;
				if (PublicReach.typeOutOfReach(declared) || build.names(declared.name, host.pkg)) return;
				if (NamingCrossRename.unsafeTypeMeta(tree, entry.source, declared, plugin)) return;
				if (!PublicReach.occursOnlyWithin(declared.name, reach.tokens, module, reach.index)) return;
				if (PublicReach.chainOutOfReach(scope, host, declared, true)) return;
				if (SafeDeleteType.moduleExternalReasons(entry.file, declared.name, files, plugin).length > 0) return;
				final decline: Null<String> = declineOf(declared, shape, runtimeNames);
				out.push({
					file: entry.file,
					span: declared.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: decline == null
						? 'type ${declared.name} is used only inside its module — make it private'
						: 'type ${declared.name} is used only inside its module and could be private, not rewritten: $decline',
					declineReason: decline
				});
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final at: Null<Span> = v.span;
			if (at != null && v.declineReason == null) edits.push({ span: new Span(at.from, at.from), text: PRIVATE_KEYWORD });
		}
		return edits;
	}

	/** Why `declared` is reported but not rewritten, or null when `private` is inserted. */
	private static function declineOf(declared: TypeDeclInfo, shape: RefShape, runtimeNames: Bool): Null<String> {
		if ((shape.compileTimeTypeDeclKinds ?? []).contains(declared.kind)) return null;
		if (!(shape.runtimeTaggedTypeKinds ?? []).contains(declared.kind)) return CLASS_DECLINE;
		return runtimeNames ? RUNTIME_NAME_DECLINE : null;
	}

	/** Whether a project file of `files` or the resolution scope (a library or the std excluded) names a run-time type-name API. */
	private static function usesRuntimeNames(files: Array<{ file: String, source: String }>, wide: SymbolIndex): Bool {
		final counts: Map<String, Int> = [];
		for (entry in files) PublicReach.countTokens(entry.source, 0, entry.source.length, counts);
		for (fi in wide.allFiles()) {
			final source: Null<String> = wide.isThirdParty(fi.file) ? null : wide.sourceOf(fi.file);
			if (source != null) PublicReach.countTokens(source, 0, source.length, counts);
		}
		return RUNTIME_NAME_APIS.exists(name -> counts[name] != null);
	}

}
