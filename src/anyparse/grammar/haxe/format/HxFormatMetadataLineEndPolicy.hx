package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `lineEnds.metadataFunction`
 * (and sister `metadataType` / `metadataVar` / `metadataOther`) field
 * accepts. Mapped by `HaxeFormatConfigLoader` to the runtime
 * `anyparse.format.MetadataLineEndPolicy` enum:
 *
 * - `"none"` → `MetadataLineEndPolicy.None` (every metadata on the declaration's line)
 * - `"after"` → `MetadataLineEndPolicy.After` (the writer's default)
 * - `"afterLast"` → `MetadataLineEndPolicy.AfterLast`
 * - `"forceAfterLast"` → `MetadataLineEndPolicy.ForceAfterLast`
 * - `"fit"` → `MetadataLineEndPolicy.Fit` (by width and metadata simplicity)
 */
enum abstract HxFormatMetadataLineEndPolicy(String) to String {
	final None = 'none';
	final After = 'after';
	final AfterLast = 'afterLast';
	final ForceAfterLast = 'forceAfterLast';
	final Fit = 'fit';
}
