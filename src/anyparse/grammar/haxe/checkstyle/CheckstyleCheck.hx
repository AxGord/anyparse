package anyparse.grammar.haxe.checkstyle;

/**
 * One entry of the `checks[]` array in a `checkstyle.json`:
 *
 * ```json
 * {"type": "MagicNumber", "props": {"ignoreNumbers": [-1, 0, 1, 2]}}
 * ```
 *
 * `type` is the checkstyle check name — `CheckstyleConfigLoader` switches on
 * it to decide which neutral policy or override the entry feeds. An entry
 * whose `type` is absent, or names a check we do not model, is ignored.
 *
 * `props` is the check's configuration; absent when the config enables a
 * check with its defaults. Everything else checkstyle writes here
 * (`severity`, …) is dropped by the parser's inherited `UnknownPolicy.Skip`.
 */
@:peg typedef CheckstyleCheck = {

	@:optional var type: String;

	@:optional var props: CheckstyleCheckProps;
};
