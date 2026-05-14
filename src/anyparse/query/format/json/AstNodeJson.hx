package anyparse.query.format.json;

/**
 * Production schema for one node of the `apq ast --json` output.
 *
 * Recursive typedef: every child is the same shape. The macro pipeline
 * routes this through `WriterLowering.shouldWriteByName` because the
 * resolved format (`JsonFormat`) is `fieldLookup = ByName` +
 * `keySyntax = Quoted` and no field carries positional metadata.
 *
 * `name` is `@:optional` — declarations carry a human-facing identifier
 * (`ClassDecl.name`, `FnDecl.name`, …); other nodes have none. The
 * writer omits the key entirely when the runtime value is null,
 * matching the schema sketch in `docs/cli-query-tool.md`.
 *
 * Lives in its own top-level module so the macro pipeline's
 * `optionsComplexType` path resolution does not hit the sub-module
 * gotcha (see `feedback_writerlowering_mirror_lowering_byname.md`).
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstNodeJson = {
	var kind:String;
	@:optional var name:String;
	var children:Array<AstNodeJson>;
};
