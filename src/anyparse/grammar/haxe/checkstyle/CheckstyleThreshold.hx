package anyparse.grammar.haxe.checkstyle;

/**
 * One entry of a `CyclomaticComplexity.props.thresholds[]` array in a
 * `checkstyle.json`:
 *
 * ```json
 * {"severity": "WARNING", "complexity": 20}
 * ```
 *
 * `severity` is the checkstyle severity the threshold raises; a threshold
 * whose severity is `IGNORE` never flags and is skipped when
 * `CheckstyleConfigLoader.loadComplexityMax` looks for the lowest onset. A
 * missing `severity` counts as flagging, matching the previous untyped
 * reader.
 *
 * `complexity` is the onset the function's complexity is compared against.
 * Typed `Float` rather than `Int` because checkstyle configs are free to
 * write either; the consumer narrows with `Std.int`.
 */
@:peg typedef CheckstyleThreshold = {

	@:optional var severity: String;

	@:optional var complexity: Float;
};
