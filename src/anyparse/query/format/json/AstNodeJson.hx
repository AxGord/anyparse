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
 * `span` is `@:optional` for the same reason — the span-mode parser
 * carries source coordinates on enum-ctor nodes (top-level decls,
 * statements, expressions); transparent inner struct nodes and the
 * synthetic `module` root have none. The writer omits the key when
 * absent, consistent with `name`. This is the finalized v1 shape:
 * `span` present when the node is source-addressable, omitted
 * otherwise.
 *
 * Lives in its own top-level module so the macro pipeline's
 * `optionsComplexType` path resolution does not hit the sub-module
 * gotcha (see `feedback_writerlowering_mirror_lowering_byname.md`).
 *
 * `doc` / `source` are the `--doc` / `--source` opt-ins, populated by
 * `Json.renderMatches` on the per-match ROOT node only (never on
 * recursed children). Both are `@:optional` — the writer omits the
 * key when null, so default `apq ast --json` output stays
 * byte-identical and the recursive child shape is unchanged.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef AstNodeJson = {
	var kind: String;
	@:optional var name: String;
	var children: Array<AstNodeJson>;
	@:optional var span: AstSearchSpan;
	@:optional var doc: String;
	@:optional var source: String;
};
