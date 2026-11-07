package unit.lowering;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;

/**
 * The generated trivia parser CALLS the runtime's byte scan of a Star loop instead of copying it per loop.
 *
 * A size contract the parsed tree cannot show: an inlined scan parses the same trees from a larger parser.
 * So the row reads the js source of the typedef rule method, one rule whose Star loops carry the scan.
 */
@:nullSafety(Strict)
final class GeneratedParserSharingTest extends Test {

	/** The generated rule method whose source the row reads. */
	private static inline final TYPEDEF_RULE: String = 'parseHxTypedefDeclT';

	/** A rolled-back Star element hands its stash back through the runtime's brace check, not an inline back-scan. */
	@:pin('control')
	@:killer('M-PRATT-RESTORE-INLINE')
	public function testTheRollbackRestoreIsACall(): Void {
		Assert.isTrue(
			typedefRuleSource().indexOf('.restorePendingAfterBrace(') >= 0,
			'$TYPEDEF_RULE no longer calls `restorePendingAfterBrace` - the stash restore is inlined again'
		);
	}

	private static function typedefRuleSource(): String {
		final rule: Null<haxe.Constraints.Function> = Reflect.field(HaxeModuleTriviaParser, TYPEDEF_RULE);
		Assert.isTrue(Reflect.isFunction(rule), 'HaxeModuleTriviaParser has no generated rule method $TYPEDEF_RULE');
		return js.Syntax.code('String({0})', rule);
	}

}
