package unit.format;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import unit.grammar.haxe.HxWriteFixture;
import unit.grammar.haxe.HxWriteOptionsKit;

/**
 * An `+` / `-` or `&&` / `||` chain sitting in a parenthesis that does not fit opens the parenthesis as a container: `(` ends the
 * line, the chain goes one indent deeper with its continuation lines co-indented, `)` takes its own line, whatever
 * `wrapping.expressionWrapping` says. A chain that fits stays glued. Every expected shape is also a fix-point of the writer.
 */
@:nullSafety(Strict)
final class ParenChainOpensTest extends Test {

	private static final CONDITION_CONFIG: String = '{"wrapping": {"maxLineLength": 40, "conditionWrapping": {'
		+ '"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
		+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';
	private static final OBJECT_CONFIG: String = '{"wrapping": {"maxLineLength": 40, "objectLiteral": {"defaultWrap": "noWrap", "rules": '
		+ '[]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';
	private static final OBJECT_AND_CALL_CONFIG: String = '{"wrapping": {"maxLineLength": 40, "objectLiteral": {'
		+ '"defaultWrap": "noWrap", "rules": []}, "callParameter": {"defaultWrap": "noWrap", "rules": []}}}';
	private static final ANON_SIGNATURE_CONFIG: String = '{"wrapping": {"maxLineLength": 40, "anonFunctionSignature": {'
		+ '"defaultWrap": "noWrap", "rules": []}, "conditionWrapping": {'
		+ '"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
		+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';
	private static final METADATA_CALL_CONFIG: String =
		'{"wrapping": {"maxLineLength": 40, "metadataCallParameter": {"defaultWrap": "noWrap", "rules": []}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-OPEN-OFF')
	public function testAddSubChainOpensUnderTheDefaults(): Void {
		assertLaidOut(
			'class C {\n\tfunction add() {\n\t\treturn 1 * (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc + dddddddddddd);\n\t}\n}',
			'class C {\n\tfunction add() {\n\t\treturn 1 * (\n\t\t\taaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc\n'
			+ '\t\t\t+ dddddddddddd\n\t\t);\n\t}\n}'
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-ADD-COINDENT-OFF')
	public function testAddSubContinuationCoIndentsWithItsFirstOperand(): Void {
		assertLaidOut(
			'class C {\n\tfunction add() {\n\t\tvar x = (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc + dddddddddddd);\n\t}\n}',
			'class C {\n\tfunction add() {\n\t\tvar x = (\n\t\t\taaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc\n'
			+ '\t\t\t+ dddddddddddd\n\t\t);\n\t}\n}'
		);
	}

	public function testBoolChainOpens(): Void {
		assertLaidOut(
			'class C {\n\tfunction bool() {\n\t\treturn (aaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccc);\n\t}\n}',
			'class C {\n\tfunction bool() {\n\t\treturn (\n\t\t\taaaaaaaaaaaaaaaaa\n\t\t\t&& bbbbbbbbbbbbbbbbbbbb\n'
			+ '\t\t\t&& cccccccccccccccccccc\n\t\t);\n\t}\n}'
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-LIST-BOUNDARY-OFF')
	public function testChainInANoWrapArrayElementOpens(): Void {
		assertLaidOut(
			'class C {\n\tfunction add() {\n\t\tvar x = [(aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), 1];\n\t}\n}',
			'class C {\n\tfunction add() {\n\t\tvar x = [(\n\t\t\taaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc\n\t\t), 1];\n'
			+ '\t}\n}'
		);
		assertLaidOut(
			'class C {\n\tfunction bool() {\n\t\tvar x = [(aaaaaaaaaaaa && bbbbbbbbbbbb && cccccccccccc), true];\n\t}\n}',
			'class C {\n\tfunction bool() {\n\t\tvar x = [(\n\t\t\taaaaaaaaaaaa\n\t\t\t&& bbbbbbbbbbbb\n\t\t\t&& cccccccccccc\n'
			+ '\t\t), true];\n\t}\n}'
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-LIST-BOUNDARY-OFF')
	public function testChainInANoWrapMapValueOpens(): Void {
		assertLaidOut(
			'class C {\n\tfunction add() {\n\t\tvar x = [1 => (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), 2 => 3];\n\t}\n}',
			'class C {\n\tfunction add() {\n\t\tvar x = [1 => (\n\t\t\taaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc\n'
			+ '\t\t), 2 => 3];\n\t}\n}'
		);
		assertLaidOut(
			'class C {\n\tfunction bool() {\n\t\tvar x = [1 => (aaaaaaaaaaaa && bbbbbbbbbbbb && cccccccccccc), 2 => true];\n\t}\n}',
			'class C {\n\tfunction bool() {\n\t\tvar x = [1 => (\n\t\t\taaaaaaaaaaaa\n\t\t\t&& bbbbbbbbbbbb\n\t\t\t&& cccccccccccc\n'
			+ '\t\t), 2 => true];\n\t}\n}'
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-CONDITION-BOUNDARY-ON')
	public function testAConditionOpensBeforeItsParen(): Void {
		assertLaidOut(
			'class C {\n\tfunction cond() {\n\t\tif (!(aaaaaaaaaaaaa || bbbbbbbb || cc)) y();\n\t}\n}',
			'class C {\n\tfunction cond() {\n\t\tif (\n\t\t\t!(\n\t\t\t\taaaaaaaaaaaaa\n\t\t\t\t|| bbbbbbbb\n\t\t\t\t|| cc\n\t\t\t)\n'
			+ '\t\t)\n\t\t\ty();\n\t}\n}',
			CONDITION_CONFIG
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-CONDITION-ELEMENT-OFF')
	public function testChainInAWrappingConditionElementOpens(): Void {
		assertLaidOut(
			'class C {\n\tfunction cond() {\n\t\tif (f([(aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), 1])) g();\n\t}\n}',
			'class C {\n\tfunction cond() {\n\t\tif (f([(\n\t\t\taaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc\n\t\t), 1]))\n'
			+ '\t\t\tg();\n\t}\n}',
			CONDITION_CONFIG
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-NATURAL-HEADER-OFF')
	public function testMapValueInAWrappingConditionKeepsItsHeaderGlued(): Void {
		assertLaidOut(
			'class C {\n\tfunction cond() {\n\t\tif (f([1 => (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), 2 => 3])) g();\n\t}\n}',
			'class C {\n\tfunction cond() {\n\t\tif (f([1 => (\n\t\t\taaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc\n'
			+ '\t\t), 2 => 3]))\n\t\t\tg();\n\t}\n}',
			CONDITION_CONFIG
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-OWN-WIDTH-OFF')
	public function testChainThatStaysOnOneLineKeepsItsParenGlued(): Void {
		for (stmt in [
			'var a = [(aa + bb), "a long string that overflows the line"];',
			'var a = [1 => (aa + bb), 2 => "a long string that overflows"];',
			'var a = [(aa && bb), "a long string that overflows the line"];'
		]) {
			final src: String = 'class C {\n\tfunction f() {\n\t\t$stmt\n\t}\n}';
			assertLaidOut(src, src);
		}
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-OWN-WIDTH-TRAIL-OFF')
	public function testChainEndingAtTheLimitStaysGlued(): Void {
		final atLimit: String = 'class C {\n\tfunction f() {\n\t\tvar a = [(aaaaaaaaaa + bbbbbbbbb), 1];\n\t}\n}';
		assertLaidOut(atLimit, atLimit);
		assertLaidOut(
			'class C {\n\tfunction f() {\n\t\tvar a = [(aaaaaaaaaa + bbbbbbbbbb), 1];\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar a = [(\n\t\t\taaaaaaaaaa + bbbbbbbbbb\n\t\t), 1];\n\t}\n}'
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-PENDING-SPACE-OFF')
	public function testMapValueCountsTheSpaceBeforeItsParen(): Void {
		final atLimit: String = 'class C {\n\tfunction f() {\n\t\tvar a = [1 => (aaaaaaa + bbbbbbb), 2 => 3];\n\t}\n}';
		assertLaidOut(atLimit, atLimit);
		assertLaidOut(
			'class C {\n\tfunction f() {\n\t\tvar a = [1 => (aaaaaaa + bbbbbbbb), 2 => 3];\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar a = [1 => (\n\t\t\taaaaaaa + bbbbbbbb\n\t\t), 2 => 3];\n\t}\n}'
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-NOWRAP-OVERRIDE-OFF')
	public function testChainParenUnderANoWrapOverrideStaysAsItWas(): Void {
		final chain: String = '(aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc)';
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar i = \'x$${[$chain, 1]}y\';\n\t\tvar j = \'x$${$chain}y\';\n\t\tswitch (['
			+ '$chain, 1]) {\n\t\t\tcase _:\n\t\t}\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar i =\n\t\t\t\'x$${[$chain, 1]}y\';\n\t\tvar j =\n\t\t\t\'x$${$chain'
			+ '}y\';\n\t\tswitch ([$chain, 1]) {\n\t\t\tcase _:\n\t\t}\n\t}\n}';
		assertLaidOut(src, expected);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-ELEMENT-CONDITION-CLEAR-OFF')
	public function testConditionUnderAnElementKeepsItsOwnOpen(): Void {
		assertLaidOut(
			'class C {\n\tfunction f() {\n'
			+ '\t\tvar a = [function() { if (function(x = (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc)) {}) y(); }, 1];\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\tfunction() {\n\t\t\t\tif (\n\t\t\t\t\tfunction(x = (aaaaaaaaaaaa\n'
			+ '\t\t\t\t\t+ bbbbbbbbbbbb\n\t\t\t\t\t+ cccccccccccc)) {}\n\t\t\t\t) y();\n\t\t\t},\n\t\t\t1\n\t\t];\n\t}\n}',
			ANON_SIGNATURE_CONFIG
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-ELEMENT-CONDITION-EARLY-OFF')
	public function testConditionWithTheSameModeUnderAnElementKeepsItsOwnOpen(): Void {
		assertLaidOut(
			'class C {\n\tfunction f() {\n'
			+ '\t\tif (f([function() { if (function(x = (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc)) {}) y(); }])) h();\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tif (f([\n\t\t\tfunction() {\n\t\t\t\tif (\n\t\t\t\t\tfunction(x = (aaaaaaaaaaaa\n'
			+ '\t\t\t\t\t+ bbbbbbbbbbbb\n\t\t\t\t\t+ cccccccccccc)) {}\n\t\t\t\t) y();\n\t\t\t}\n\t\t]))\n\t\t\th();\n\t}\n}',
			ANON_SIGNATURE_CONFIG
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-ELEMENT-ONLY-OFF')
	public function testChainInANoWrapObjectFieldStaysAsItWas(): Void {
		assertLaidOut(
			'class C {\n\tfunction f() {\n\t\tvar o = {a: (aaaaaaaaaaaa && bbbbbbbbbbbb && cccccccccccc), b: 1};\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar o = {a: (aaaaaaaaaaaa\n\t\t\t&& bbbbbbbbbbbb\n\t\t\t&& cccccccccccc), b: 1};\n\t}\n}',
			OBJECT_CONFIG
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-MARK-OBJECT-CLEAR-OFF')
	public function testNoWrapObjectInAnElementStaysGlued(): Void {
		assertLaidOut(
			'class C {\n\tfunction f() {\n\t\tvar o = [{a: (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), b: 1}, 2];\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar o = [{a: (aaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc), b: 1}, 2];\n\t}\n}',
			OBJECT_AND_CALL_CONFIG
		);
		assertLaidOut(
			'class C {\n\tfunction f() {\n\t\tvar o = [1 => {a: (aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), b: 1}, 2 => 3];\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar o = [1 => {a: (aaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n'
			+ '\t\t\t+ cccccccccccc), b: 1}, 2 => 3];\n\t}\n}',
			OBJECT_AND_CALL_CONFIG
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-MARK-CALL-CLEAR-OFF')
	public function testNoWrapCallArgumentInAnElementStaysGlued(): Void {
		assertLaidOut(
			'class C {\n\tfunction f() {\n\t\tvar c = [g((aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), 1), 2];\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar c = [g((aaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc), 1), 2];\n\t}\n}',
			OBJECT_AND_CALL_CONFIG
		);
		assertLaidOut(
			'class C {\n\tfunction f() {\n\t\tvar c = [function() { var y = g((aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), 1); }, 2];\n'
			+ '\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar c = [\n\t\t\tfunction() {\n\t\t\t\tvar y = g((aaaaaaaaaaaa\n\t\t\t\t\t+ bbbbbbbbbbbb\n'
			+ '\t\t\t\t\t+ cccccccccccc), 1);\n\t\t\t},\n\t\t\t2\n\t\t];\n\t}\n}',
			OBJECT_AND_CALL_CONFIG
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-MARK-NEW-CLEAR-OFF')
	public function testNoWrapNewArgumentInAnElementStaysGlued(): Void {
		assertLaidOut(
			'class C {\n\tfunction f() {\n\t\tvar n = [new G((aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), 1), 2];\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar n = [new G((aaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc), 1), 2];\n\t}\n}',
			OBJECT_AND_CALL_CONFIG
		);
	}

	@:pin('control')
	@:killer('M-PAREN-CHAIN-MARK-OTHER-CLEAR-OFF')
	public function testNoWrapMetadataArgumentInAnElementStaysGlued(): Void {
		assertLaidOut(
			'class C {\n\tfunction f() {\n\t\tvar c = [@:m((aaaaaaaaaaaa + bbbbbbbbbbbb + cccccccccccc), 1) x, 2];\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar c = [@:m((aaaaaaaaaaaa\n\t\t\t+ bbbbbbbbbbbb\n\t\t\t+ cccccccccccc), 1) x, 2];\n\t}\n}',
			METADATA_CALL_CONFIG
		);
	}

	public function testFittingChainStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction fits() {\n\t\tvar x = 1 * (a + b);\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, narrow()));
	}

	/** The width the chains are laid out at, typed over the baseline a config document starts from. */
	private function narrow(): HxModuleWriteOptions {
		return HxWriteOptionsKit.forkWith(opts -> opts.lineWidth = 40);
	}

	private function assertLaidOut(flat: String, expected: String, ?config: String): Void {
		final opts: HxModuleWriteOptions = config == null ? narrow() : HxWriteOptionsKit.strictJson(config);
		Assert.equals(expected, HxWriteFixture.triviaWrite(flat, opts));
		Assert.equals(expected, HxWriteFixture.triviaWrite(expected, opts));
	}

}
