package anyparse.format;

/**
 * Indentation policy applied to preprocessor conditional-compilation
 * (`#if` / `#elseif` / `#else` / `#end`) blocks, mirroring
 * haxe-formatter's `indentation.conditionalPolicy`
 * (`ConditionalIndentationPolicy`). The policy decides how the body of
 * a conditional region is indented relative to the `#if`/`#else`/`#end`
 * markers and the surrounding statement indent `S`:
 *
 *  - `Aligned` (default) — markers AND body both at `S`. Byte-identical
 *    to the pre-policy writer; the writer never injects extra nesting.
 *  - `AlignedIncrease` — markers at `S`, body at `S + 1`; nesting
 *    accumulates per conditional depth (a nested `#if` marker sits at
 *    its parent body level). Matches the fork's
 *    `count += calcConsecutiveConditionalLevel` branch.
 *  - `AlignedDecrease` — markers at `max(0, S - 1)`, body at `S`.
 *  - `FixedZero` — markers at absolute column `0`, body at `S`.
 *  - `AlignedNestedIncrease` / `FixedZeroIncrease` /
 *    `FixedZeroIncreaseBlocks` — fork variants not yet driven by the
 *    anyparse writer; declared for value-name parity so a future slice
 *    can wire them without re-numbering the enum.
 *
 * Underlying `Int` so the generated writer compares `opt.conditionalPolicy`
 * against a literal in a hot path with no boxing; `@:from` resolves the
 * `hxformat.json` string value (`"alignedIncrease"`, …). Unknown strings
 * fall back to `null` so the loader keeps the existing default.
 */
enum abstract ConditionalIndentationPolicy(Int) {

	final FixedZero = 0;
	final FixedZeroIncrease = 1;
	final FixedZeroIncreaseBlocks = 2;
	final Aligned = 3;
	final AlignedNestedIncrease = 4;
	final AlignedIncrease = 5;
	final AlignedDecrease = 6;

	@:from private static function resolve(name:String):Null<ConditionalIndentationPolicy> {
		return switch name {
			case 'fixedZero': FixedZero;
			case 'fixedZeroIncrease': FixedZeroIncrease;
			case 'fixedZeroIncreaseBlocks': FixedZeroIncreaseBlocks;
			case 'aligned': Aligned;
			case 'alignedNestedIncrease': AlignedNestedIncrease;
			case 'alignedIncrease': AlignedIncrease;
			case 'alignedDecrease': AlignedDecrease;
			case _: null;
		};
	}
}
