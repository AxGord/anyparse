package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `lineEnds.metadataFunction`
 * (and sister `metadataType` / `metadataVar` / `metadataOther`) field
 * accepts. Mapped by `HaxeFormatConfigLoader` to the runtime
 * `anyparse.format.MetadataLineEndPolicy` enum:
 *
 * - `"none"` → `MetadataLineEndPolicy.None` (default — preserve source)
 * - `"after"` → `MetadataLineEndPolicy.After`
 * - `"afterLast"` → `MetadataLineEndPolicy.AfterLast`
 * - `"forceAfterLast"` → `MetadataLineEndPolicy.ForceAfterLast`
 */
enum abstract HxFormatMetadataLineEndPolicy(String) to String {

	final None = 'none';

	final After = 'after';

	final AfterLast = 'afterLast';

	final ForceAfterLast = 'forceAfterLast';

}
